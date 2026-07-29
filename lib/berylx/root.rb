# frozen_string_literal: true

module Berylx
  class Root
    def self.[](value = {})
      new(value)
    end

    attr_reader :history

    def initialize(value = {})
      @value = Result.coerce_focus(value)
      @history = []
      @subscribers = []
    end

    def |(other)
      call(other)
    end

    def call(node, handlers: EffectTree.real_handlers)
      result = State.new(@value).call(node, handlers: handlers)
      commit_result(result)
    end

    def commit(value)
      next_focus = coerce_commit(value)
      @value = next_focus
      event = { type: :commit, value: @value.to_h }
      @history << event
      publish(event)
      self
    end

    def state
      @value.to_h
    end

    def to_h
      state
    end

    def to_lay
      @value
    end

    def to_state
      State.new(@value)
    end

    def [](key)
      @value[key]
    end

    def subscribe(&block)
      raise ArgumentError, 'Root#subscribe requires a block' unless block

      @subscribers << block
      block.call(type: :snapshot, value: state)
      -> { @subscribers.delete(block) }
    end

    protected

    def commit_result(result)
      commit(result.focus) if result.is_a?(Ok)
      result
    end

    private

    def coerce_commit(value)
      case value
      when Root
        value.to_lay
      when Ok, Err
        Result.coerce_focus(value.focus)
      when Focus
        value
      when Hash
        Merge.deep.call(@value, Focus[value])
      else
        Result.coerce_focus(value)
      end
    end

    def publish(event)
      @subscribers.each { _1.call(event) }
    end
  end

  def self.Root(value = {})
    Root[value]
  end

  def self.root(value = {})
    Root[value]
  end
end
