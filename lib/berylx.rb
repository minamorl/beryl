# frozen_string_literal: true

# darkcore は berylx の必須依存。berylx workflow の唯一の実行基盤である
# EffectTree (darkcore Effect 木) が全合成子の実行を担うため、遅延ではなく
# ここで無条件に読み込む。
require 'darkcore'

require_relative 'berylx/version'
require_relative 'berylx/error'
require_relative 'berylx/result'
require_relative 'berylx/focus'
require_relative 'berylx/root'
require_relative 'berylx/flow'
require_relative 'berylx/state'
require_relative 'berylx/merge'

require_relative 'berylx/perform'
require_relative 'berylx/task'
require_relative 'berylx/sequence'
require_relative 'berylx/parallel'
require_relative 'berylx/branch'
require_relative 'berylx/rescue'
require_relative 'berylx/workflow'
require_relative 'berylx/graph'

# EffectTree は berylx の唯一の実行基盤。全合成子 (Sequence / Parallel / Branch /
# Rescue) の #call はここへ委譲するので、core の一部として無条件に読み込む。
require_relative 'berylx/effect_tree'

require_relative 'berylx/prelude'

module Berylx
  Lay = Focus

  def self.run(workflow, focus)
    Flow[focus].call(workflow)
  end
end
