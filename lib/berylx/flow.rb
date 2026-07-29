# frozen_string_literal: true

module Berylx
  class Flow
    def self.[](focus)
      new(focus)
    end

    attr_reader :focus

    def initialize(focus)
      @focus = Result.coerce_focus(focus)
    end

    # 実行の唯一のエントリ。合成子でも単発 Task でも EffectTree (darkcore
    # Effect 木) を必ず通す。Task は葉として EffectTree の :berylx_task handler が
    # Task#call を呼ぶ。
    def call(node, handlers: EffectTree.real_handlers)
      EffectTree.run(node, @focus, handlers: handlers)
    end

    def >>(other)
      call(other)
    end
  end
end
