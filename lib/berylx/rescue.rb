# frozen_string_literal: true

module Berylx
  class RescueBlock
    attr_reader :name

    def initialize(name, block)
      @name = name.to_sym
      @block = block
    end

    # 3 引数のブロックは第三引数に Berylx::Perform を受け取り、回復の中から
    # 作用を発行できる (Task の 2 引数形と同じ規則)。performer は RECOVER の
    # real interpreter が「いま解釈に使っている handler マップ」から作る。
    def call(focus, error_result, performer = nil)
      result = Result.normalize(invoke(error_result, focus, performer))
      result.is_a?(Err) ? with_rescue_context(result) : result
    rescue StandardError => e
      Result.err(focus, e.class.name.to_sym, e.message, cause: e, failed_node: @name, trace: [@name])
    end

    def effectful?
      @block.arity.abs >= 3
    end

    def nodes
      [self]
    end

    private

    def invoke(error_result, focus, performer)
      error = error_result.cause || error_result.error
      return @block.call(error, focus) unless effectful?

      @block.call(error, focus, performer)
    end

    def with_rescue_context(result)
      error = result.error.failed_node ? result.error : result.error.prepend_trace(@name)
      Err.new(result.focus, error)
    end
  end

  class Catch
    attr_reader :name, :handler

    def self.[](name = :catch, handler = nil, **options, &block)
      new(name, handler, **options, &block)
    end

    def initialize(name = :catch, handler = nil, **options, &block)
      @name = name.to_sym
      @handler = block ? RescueBlock.new(@name, block) : handler
      @catches_terminal = options.fetch(:fatal, false)

      raise ArgumentError, 'Catch requires a task or block' unless @handler
    end

    def catches?(error_result)
      !terminal?(error_result.error) || @catches_terminal
    end

    # Catch は Sequence 内の短絡境界。実行 (成功時の素通り・Err の回復) は
    # EffectTree.compile_sequence が担うので、単独 call も EffectTree に委譲する。
    def call(focus)
      EffectTree.run(self, focus)
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def &(other)
      Parallel.new([self, other])
    end

    def rescue_with(handler = nil, name = nil, &)
      Sequence.build_rescue(self, handler, name, &)
    end

    def nodes
      @handler.respond_to?(:nodes) ? @handler.nodes : [self]
    end

    private

    def terminal?(error)
      error.fatal?
    end
  end

  class Rescue
    attr_reader :body, :handler

    def initialize(body, handler)
      @body = body
      @handler = handler
    end

    # 実行は EffectTree に一本化。body の Err を回復 handler で差し替える
    # algebra は EffectTree.run_rescue に集約している。
    def call(focus)
      EffectTree.run(self, focus)
    end

    def >>(other)
      Sequence.new([self, other])
    end

    def &(other)
      Parallel.new([self, other])
    end

    def rescue_with(handler = nil, name = nil, &)
      Sequence.build_rescue(self, handler, name, &)
    end

    def nodes
      @body.nodes + @handler.nodes
    end
  end
end
