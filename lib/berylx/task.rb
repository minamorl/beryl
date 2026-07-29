# frozen_string_literal: true

module Berylx
  class Task
    def self.[](name, &block)
      new(name, &block)
    end

    def self.build(name, &block)
      self[name, &block]
    end

    attr_reader :name

    def initialize(name, &block)
      raise ArgumentError, 'Task requires a block' unless block

      @name = name.to_sym
      @block = block
    end

    def call(focus, performer = nil)
      root = Result.coerce_focus(focus)
      result = Result.normalize(invoke(root, performer))
      result.is_a?(Err) ? with_task_context(result) : result
    rescue StandardError => e
      Result.err(root || focus, e.class.name.to_sym, e.message, cause: e, failed_node: @name, trace: [@name])
    end

    # ブロックが 2 引数を取る Task は本体から作用を発行できる (第二引数に
    # Berylx::Perform が渡る)。1 引数の Task は従来と全く同じ経路を通る。
    def effectful?
      @block.arity.abs >= 2
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

    def invoke(root, performer)
      return @block.call(root) unless effectful?
      unless performer
        raise ArgumentError,
              "task #{@name} performs effects; run it through a handler map (EffectTree.run / Flow#call)"
      end

      @block.call(root, performer)
    end

    def with_task_context(result)
      error = result.error.failed_node ? result.error : result.error.prepend_trace(@name)
      Err.new(result.focus, error)
    end
  end
end
