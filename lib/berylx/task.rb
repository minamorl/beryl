# frozen_string_literal: true

module Berylx
  class Task
    def self.[](name, **options, &block)
      new(name, **options, &block)
    end

    def self.build(name, **options, &block)
      self[name, **options, &block]
    end

    attr_reader :name

    # pure: true は「この body は副作用を起こさず、作用は Effect を組んで
    # 返すだけである」という **作者の宣言**。berylx はこれを推論しない
    # (spec: berylx.task.body.purity = declared / forbid inferred) — body が
    # 純粋かは呼んでみるまで判らず、呼んだ時点で宣言の無い Task の副作用が
    # 発火してしまうので、「呼んで確かめる」形の推論は原理的に採れない。
    #
    # 宣言があると dry_run が body まで踏み込んで作用を列挙できる。
    # 宣言が無ければ dry_run は従来どおり body を呼ばない。
    def initialize(name, pure: false, &block)
      raise ArgumentError, 'Task requires a block' unless block

      @name = name.to_sym
      @block = block
      @pure_body = pure
    end

    # 作者が純粋と宣言したか。dry_run はこれだけを信じる。
    def pure_body? = @pure_body

    # body を評価して Effect (または focus) を取り出す。副作用ゼロの圏
    # (dry_run) が使うので、**宣言済みの body でしか呼んではならない**。
    def build_body(focus)
      @block.call(Result.coerce_focus(focus))
    end

    # body は focus を返しても Effect を返してもよい
    # (spec: berylx.task.body.return in [focus, effect])。
    # Effect が返ったときは **呼び出した圏の handler マップ** で畳む
    # (spec: berylx.task.body.effect.category = same_handler_map)。
    # 畳み方を Task 自身が決め打ちにすると、body に入った途端に圏が変わり、
    # 「handler で選べるのは Task の粒度まで」という穴が塞がらない。
    # handlers はブロックではなく普通の引数で受ける。&block で受けると Ruby が
    # 呼び出しごとに Proc を実体化し、**body が Effect を返さない普通の Task にも**
    # その値段がかかる (実測: 1 段 5.70us -> 7.06us、割り当て +3 obj/call)。
    def call(focus, handlers = nil)
      root = Result.coerce_focus(focus)
      result = Result.normalize(fold_body(@block.call(root), handlers))
      result.is_a?(Err) ? with_task_context(result) : result
    rescue StandardError => e
      Result.err(root || focus, e.class.name.to_sym, e.message, cause: e, failed_node: @name, trace: [@name])
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def &(other)
      Parallel.new([self, other])
    end

    def |(other)
      self >> other
    end

    def rescue_with(handler = nil, name = nil, &block)
      Sequence.build_rescue(self, handler, name, &block)
    end

    def compile
      Graph.from(self)
    end

    def nodes
      [self]
    end

    private

    # handlers が渡らない呼び出し (Root | Task の直接実行、C interpreter からの
    # 委譲) は定義により real 圏なので real の handler マップで畳む。
    #
    # 畳みは意図的に上の rescue の内側に置く。Task の body が投げた例外は
    # 従来から結果封筒 Err になる (result.no_implicit_raise) ので、body が
    # 返した Effect を解釈する途中の例外 (未知タグの KeyError など) だけを
    # 別扱いにしない (spec: berylx.task.body.unknown_tag = result_envelope)。
    def fold_body(produced, handlers)
      return produced unless produced.is_a?(Darkcore::Effect)

      EffectTree.fold_body(produced, handlers || EffectTree.real_handlers)
    end

    def with_task_context(result)
      error = result.error.failed_node ? result.error : result.error.prepend_trace(@name)
      Err.new(result.focus, error)
    end
  end
end
