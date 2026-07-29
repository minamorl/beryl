# frozen_string_literal: true

require 'darkcore'

module Berylx
  # ==================================================================
  # Berylx::EffectTree — berylx workflow を darkcore の単一 Effect 型
  # (Freer monad, tagged effect の木) へ載せ替える adapter。
  #
  # 第一段: Sequence(>>) の写像。
  # 第二段: parallel(&) / branch / rescue も同じ Effect 木へ載せる。
  #   合成子はそれぞれ 1 つの tagged effect ノードで表し、モード
  #   (short_circuit / accumulate など) は handler の分岐ではなく
  #   payload に載せた berylx ノード (検査可能データ) から読む。
  #
  # 掟 (spec-system pins) との対応:
  #   - substrate.effect_tree      : workflow を darkcore Effect 木へ写す。
  #   - substrate.task_as_effect   : Task を tagged effect ノード
  #       Effect(:berylx_task, [task, focus], k) として表す。
  #   - substrate.parallel.mapped  : parallel を Effect(:berylx_parallel, [node, focus])
  #       へ写す。short_circuit / accumulate は handler ではなく payload の
  #       node.on_err (タグ) で運ぶ。
  #   - substrate.branch.mapped    : branch を Effect(:berylx_branch, [node, focus])
  #       へ写す。arm の選択は handler の分岐でなく effect 木の tag で表す。
  #   - substrate.rescue.mapped    : rescue を Effect(:berylx_rescue, [node, focus])
  #       へ写す。body の Err は handler 差し替え (回復 handler) で回復させる。
  #   - result.parallel_default    : short_circuit が既定、accumulate はタグ上書き。
  #   - substrate.no_opaque_thunk  : payload は検査可能なデータ (berylx ノード + Focus)。
  #       Task の block や branch/reducer は handler が呼ぶまで実行しない。
  #   - substrate.aspect_via_handler: retry/dry_run/audit は workflow 本体
  #       (compile 結果の Effect 木) を書き換えず handler マップ差し替えで後付け。
  #   - result.envelope            : 成功 Berylx::Ok(lay) / 失敗 Berylx::Err(partial_lay, error)。
  #   - result.sequence_short_circuit: 最初の Err で短絡 (darkcore bind の上に載せる)。
  #   - namespace.separate         : darkcore の bind は必ず bind と呼ぶ。
  #       berylx の >> は berylx の合成子として残す (ここでは演算子を作らない)。
  #
  # darkcore 側の掟: bind は構造の接ぎ木のみ (演算ゼロ)。圏の algebra が
  # 現れるのは handler と on_return だけ。ここでの短絡判定 (Err かどうか) は
  # berylx の Result 圏の algebra なので、darkcore の bind に埋めず、berylx 側の
  # 継続 (bind に渡す関数) の中で行う。
  # ==================================================================
  module EffectTree
    # berylx 合成子を darkcore Effect 木にディスパッチするためのタグ。
    TASK     = :berylx_task
    PARALLEL = :berylx_parallel
    BRANCH   = :berylx_branch
    RESCUE   = :berylx_rescue

    # 合成子タグ → 副木を走らせる interpreter。3 つとも
    # (node, focus, handlers) の同じ形なので表で持つ。
    COMBINATOR_RUNNERS = { PARALLEL => :run_parallel, BRANCH => :run_branch, RESCUE => :run_rescue }.freeze

    # berylx 自身が使うタグ。アプリの作用語彙がここを踏むのは事故なので弾く。
    RESERVED_TAGS = [TASK, *COMBINATOR_RUNNERS.keys].freeze

    # dry_run の戻り値: 最終結果 (実行しないので常に Ok) と、列挙された計画。
    DryRun = Data.define(:result, :steps)

    module_function

    # ----------------------------------------------------------------
    # compile — berylx ノードを「Focus を受け取り darkcore Effect を返す」
    # Kleisli 矢に落とす。
    #   Sequence は bind で接ぎ木し (compile_sequence)、
    #   Task / Parallel / Branch / Rescue はそれぞれ 1 つの tagged effect
    #   ノードに落とす。payload は [node, focus] の検査可能データ
    #   (不透明サンクにしない = substrate.no_opaque_thunk)。
    #   合成子の内部 (branches / arms / body / reducer / on_err) は
    #   handler が副木として実行するまで発火しない。
    # ----------------------------------------------------------------
    def compile(node)
      case node
      when Sequence then compile_sequence(node)
      when Task     then ->(focus) { Darkcore.op(TASK, [node, focus]) }
      when Parallel then ->(focus) { Darkcore.op(PARALLEL, [node, focus]) }
      when Branch   then ->(focus) { Darkcore.op(BRANCH, [node, focus]) }
      when Rescue   then ->(focus) { Darkcore.op(RESCUE, [node, focus]) }
      when Catch    then ->(focus) { Darkcore.pure(Result.ok(focus)) }
      else
        raise ArgumentError,
              "EffectTree supports Task / Sequence / Parallel / Branch / Rescue / Catch, got #{node.class}"
      end
    end

    # Sequence を darkcore bind で接ぎ木する。bind は構造の接ぎ木のみで、
    # 短絡 (Err) 判定・Catch 境界での回復は継続内 = berylx 圏の algebra site で
    # 行う (darkcore の bind には埋めない)。
    def compile_sequence(node)
      lambda do |focus|
        node.steps.reduce(Darkcore.pure(Result.ok(focus))) do |effect, step|
          effect.bind { |prev| compile_step(step, prev) }
        end
      end
    end

    # Sequence の 1 ステップを次の Effect に接ぐ。Catch は Sequence の短絡境界:
    # 成功時は素通りし、直前が Err のときだけ (かつ catches? が真のとき) 回復させる。
    # 非 Catch は Err なら短絡 (prev を前送り)、Ok なら実行する。
    def compile_step(step, prev)
      return compile_catch(step, prev) if step.is_a?(Catch)
      return Darkcore.pure(prev) if prev.is_a?(Err)

      compile(step).call(prev.focus)
    end

    def compile_catch(step, prev)
      return Darkcore.pure(prev) unless prev.is_a?(Err) && step.catches?(prev)

      Darkcore.pure(recover(step.handler, prev))
    end

    # berylx ノードと初期 focus から darkcore Effect 木を組み立てる。
    # 実行はしない (handler を渡すまで作用は起きない)。
    def build(node, focus)
      compile(node).call(Result.coerce_focus(focus))
    end

    # workflow 本体 (Effect 木) を darkcore トランポリンで走らせる。
    # handlers を差し替えるだけで圏 (real / dry_run / audit ...) を選ぶ。
    # 戻り値は berylx の結果封筒 Berylx::Ok(lay) / Berylx::Err(partial_lay, error)。
    def run(node, focus, handlers: real_handlers)
      Darkcore.fold(build(node, focus), on_return: ->(x) { x }, handlers: handlers)
    end

    # 実実行の handler マップ: Task の block を実際に呼び、合成子ノードは
    # それぞれ副木として実行しつつ berylx 圏の algebra で結果封筒を合成する。
    # Task#call / 各合成子の call と同一のセマンティクスになるよう写している。
    #
    # 合成子 handler が副木の実行に使うマップは subtree で与える。既定 (nil)
    # は「いま組み立てているこのマップ自身」なので、単体で呼べば従来どおり
    # 同じ圏 (real) のまま再帰する。around が aspect を巻いたマップを subtree
    # に渡すことで、aspect は合成子の内側にも伝播する (dry_handlers が steps を
    # 伝播させるのと同じ構造)。
    # effects はアプリの作用語彙 ({ tag => ->(payload) {...} })。同じマップに
    # 畳み込むので、Task 本体からの perform も合成子の副木も同じ圏で解釈される。
    # subtree も位置引数にしてあるのは、キーワードを 1 つでも宣言すると
    # real_handlers(db_query: ...) が「未知のキーワード」になってしまうため。
    def real_handlers(effects = {}, subtree = nil)
      collisions = effects.keys & RESERVED_TAGS
      raise ArgumentError, "effect tags collide with berylx tags: #{collisions.inspect}" unless collisions.empty?

      handlers = { TASK => ->(payload) { real_task(payload, subtree || handlers) } }
      COMBINATOR_RUNNERS.each do |tag, runner|
        handlers[tag] = ->(payload) { send(runner, payload[0], payload[1], subtree || handlers) }
      end
      handlers.merge!(effects)
    end

    # Task 本体が作用を発行できるように、いま解釈に使っている handler マップを
    # Perform として渡す。作用を出さない Task には渡さない (経路は従来のまま)。
    def real_task(payload, handlers)
      task, focus = payload
      task.call(focus, task.effectful? ? Perform.new(handlers) : nil)
    end

    # ----------------------------------------------------------------
    # around — real interpreter に aspect (audit / retry / 計測) を巻いた
    # handler マップを作る。workflow 本体 (Effect 木) は書き換えない。
    # (spec: substrate.aspect_via_handler)
    #
    #   handlers = EffectTree.around { |tag, payload, inner| ...; inner.call(payload) }
    #   EffectTree.run(workflow, focus, handlers: handlers)
    #
    # 巻いたマップ自身を副木実行にも渡すので、aspect は parallel / branch /
    # rescue の内側にも届く。real_handlers を手で transform_values しても
    # 内側には届かない (副木が生のマップで走ってしまう) ので、aspect を
    # 組み立てる道はここに一本化する。
    #
    # 注意 1: parallel の branch は別スレッドで走る。wrapper が状態を持つなら
    #   スレッドセーフにすること。
    # 注意 2: Rescue / Catch の回復 handler は Effect 木のノードではなく
    #   recover が木の外で直接適用するため aspect からは見えない (body まで)。
    def around(effects = {}, &wrapper)
      raise ArgumentError, 'around requires a block' unless wrapper

      wrapped = {}
      real_handlers(effects, wrapped).each do |tag, handler|
        wrapped[tag] = ->(payload) { wrapper.call(tag, payload, handler) }
      end
      wrapped
    end

    # ----------------------------------------------------------------
    # 副木実行ヘルパ — berylx ノードを与えられた handler マップで走らせ、
    # berylx 結果封筒 (Ok/Err) を得る。合成子 handler が枝の実行に使う。
    # ----------------------------------------------------------------
    def run_subtree(node, focus, handlers)
      Darkcore.fold(build(node, focus), on_return: ->(x) { x }, handlers: handlers)
    end
  end
end

# 合成子 (parallel / branch / rescue) の real interpreter は別ファイルで
# EffectTree を再オープンして足す。core (compile / build / run / handler マップ)
# と、各合成子の berylx 圏 algebra (短絡・merge・回復) を語りの上でも分離する。
require_relative 'effect_tree/combinators'

# dry-run interpreter (aspect) も別ファイルで EffectTree を再オープンして足す。
# real interpreter と dry interpreter を語り (ファイル) の上でも分離し、
# aspect が handler マップ差し替えだけで載ることを構造で示す。
require_relative 'effect_tree/dry_run'
