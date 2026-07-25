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
    # Sequence 内の Catch 境界での回復も 1 つの tagged effect にする。
    # 素の Ruby 呼び出しのままだと、回復 handler が Task のときにその body が
    # **いま効いている圏の外**で走ってしまう (category.propagation 違反)。
    RECOVER  = :berylx_recover

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

    # Sequence を darkcore bind で右結合に接ぎ木する。bind は構造の接ぎ木のみで、
    # 短絡 (Err) 判定・Catch 境界での回復は継続内 = berylx 圏の algebra site で
    # 行う (darkcore の bind には埋めない)。
    #
    # 旧実装は左結合 reduce で、bind のたびに既存継続を再ラップし深い列で
    # O(n^2) だった (darkcore.spec の free perf.freer_queue が予告した摩擦)。
    # 右結合は各ステップの effect に「残りを接ぐ」継続を一度だけ bind するので、
    # 同じ Effect 木・同じ handler 到達順のまま O(n) で走る。
    def compile_sequence(node)
      ->(focus) { sequence_chain(node.steps, 0, Result.ok(focus)) }
    end

    # steps[index..] を prev (結果封筒) から接ぐ。closed (pure) が返る間は
    # 木を伸ばさず反復で畳むので、短絡の前送り・Catch 素通りでスタックも
    # 継続も積まない (トランポリン契約を保つ)。
    def sequence_chain(steps, index, prev)
      while index < steps.size
        effect = compile_step(steps[index], prev)
        index += 1
        return sequence_suspend(effect, steps, index) unless effect.closed?

        prev = effect.payload
      end
      Darkcore.pure(prev)
    end

    # 開いた作用 (op ノード) に「残りのステップ」を一度だけ接ぐ。
    def sequence_suspend(effect, steps, index)
      effect.bind { |nxt| sequence_chain(steps, index, nxt) }
    end

    # Sequence の 1 ステップを次の Effect に接ぐ。Catch は Sequence の短絡境界:
    # 成功時は素通りし、直前が Err のときだけ (かつ catches? が真のとき) 回復させる。
    # 非 Catch は Err なら短絡 (prev を前送り)、Ok なら実行する。
    def compile_step(step, prev)
      return compile_catch(step, prev) if step.is_a?(Catch)
      return Darkcore.pure(prev) if prev.is_a?(Err)

      compile(step).call(prev.focus)
    end

    # 回復そのものを effect ノードにする。ここで素の recover を呼ぶと、Sequence の
    # 木を組む側には handler マップが無いので、回復 handler が Task のときその body が
    # real 圏で走ってしまう (自作の圏が Catch 境界を越えられない)。
    def compile_catch(step, prev)
      return Darkcore.pure(prev) unless prev.is_a?(Err) && step.catches?(prev)

      Darkcore.op(RECOVER, [step.handler, prev])
    end

    # berylx ノードと初期 focus から darkcore Effect 木を組み立てる。
    # 実行はしない (handler を渡すまで作用は起きない)。
    def build(node, focus)
      compile(node).call(Result.coerce_focus(focus))
    end

    # workflow 本体 (Effect 木) を darkcore トランポリンで走らせる。
    # handlers を差し替えるだけで圏 (real / dry_run / audit ...) を選ぶ。
    # 戻り値は berylx の結果封筒 Berylx::Ok(lay) / Berylx::Err(partial_lay, error)。
    #
    # real 圏 (既定 handler マップのまま) は native bridge が使えるとき
    # C 拡張の interpreter へ委譲する。handler を差し替えた圏 (dry_run /
    # audit / retry ...) は従来どおり pure Ruby の fold で走る —
    # aspect_via_handler の機構はネイティブ化の影響を受けない。
    def run(node, focus, handlers: REAL_HANDLERS)
      return Native.run_entry(node, focus) if handlers.equal?(REAL_HANDLERS) && Native.enabled?

      Darkcore.fold(build(node, focus), on_return: ->(x) { x }, handlers: handlers)
    end

    # ----------------------------------------------------------------
    # category — handler マップ (圏) を組む唯一の口。
    #
    # 合成子は副木を **明示的に** 走らせるので、どのマップで走らせるかを
    # 誰かが決めねばならない。ここを real 決め打ちにすると、選んだ圏が
    # Parallel / Rescue / Branch を越えた瞬間 real へ戻る。実際そうなっていた:
    #
    #   Task 単体          Ok
    #   Sequence (>>)      Ok        <- 外側の fold が同じマップで畳むから通る
    #   Parallel (&)       KeyError: no handler for effect: :measure
    #   Rescue の handler  KeyError: no handler for effect: :measure
    #
    # だからマップは **自分自身を副木へ渡す** ように組む。合成子も Task body も
    # このマップで走るので、圏は木の隅々まで届く
    # (spec: berylx.category.propagation = through_combinators)。
    #
    #   handlers = Berylx::EffectTree.category(my_tag => ->(payload) { ... })
    #   Berylx::EffectTree.run(workflow, focus, handlers: handlers)
    #
    # extra は最後に merge するので、合成子の解釈そのものも差し替えられる。
    # ----------------------------------------------------------------
    def category(extra = {})
      handlers = {}
      wire_defaults(handlers)
      handlers.merge!(extra)
      handlers
    end

    # 副木を **組み立て中のマップ自身** で走らせる配線。ここが要で、
    # handlers を real_handlers に書き換えた瞬間に圏は合成子を越えられなくなる。
    def wire_defaults(handlers)
      handlers[TASK] = ->(payload) { run_task(payload, handlers) }
      handlers[RECOVER] = ->(payload) { recover(payload[0], payload[1], handlers) }
      { PARALLEL => :run_parallel, BRANCH => :run_branch, RESCUE => :run_rescue }.each do |tag, runner|
        handlers[tag] = ->(payload) { send(runner, payload[0], payload[1], handlers) }
      end
    end

    # ----------------------------------------------------------------
    # Task の body が Effect を返したときの畳み込み口。
    #
    # body が返した Effect をそのマップ自身で畳むので、圏の選択が Task の
    # 粒度で止まらず body の内側まで届く (spec: berylx.task.body.effect.category
    # = same_handler_map、berylx.aspect.reach に task_body_effect を含む)。
    # ----------------------------------------------------------------
    def run_task(payload, handlers)
      task, focus = payload
      task.call(focus, handlers)
    end

    def fold_body(effect, handlers)
      Darkcore.fold(effect, on_return: ->(x) { x }, handlers: handlers)
    end

    # 実実行の圏。Task の block を実際に呼び、合成子ノードはそれぞれ副木として
    # 実行しつつ berylx 圏の algebra で結果封筒を合成する。
    #
    # 一度だけ組んで凍結し、run / 副木実行の既定値として共有する
    # (native gate の「real 圏のままか」の同一性判定にも使う)。
    REAL_HANDLERS = category.freeze

    def real_handlers
      REAL_HANDLERS
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

# native bridge (C 拡張の real-圏 interpreter)。拡張が無ければ純 Ruby に
# 自動フォールバックする任意の加速器で、観測挙動は同一 (差分検証で保証)。
require_relative 'effect_tree/native'
