# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# ==================================================================
# Parallel の決定性 — reducer の畳み込みは branch の「定義順」であり、
# 完了順ではない。sleep で完了タイミングを撹乱しても結果は毎回同一。
#
# 実装の根拠: run_parallel は Thread 配列を生成順に join し
# (combinators.rb join_all)、branch_results をその順で reduce する。
# この不変が壊れると Merge.deep の右バイアスが「たまたま速かった枝」の
# バイアスになり、並列が非決定になる。ここで固定する。
# ==================================================================
class ParallelDeterminismTest < Minitest::Test
  RUNS = 6

  def branch_task(index, delay)
    Berylx::Task[:"branch#{index}"] do |lay|
      sleep delay
      lay[:winner].set(index)
    end
  end

  # 同じキーへの書き込み: deep merge は右バイアスなので「定義順で最後の
  # 枝」が勝つ。完了順なら sleep の並びで勝者が変わるはずだが、変わらない。
  def test_fold_order_is_definition_order_not_completion_order
    results = Array.new(RUNS) do |seed|
      delays = [0.03, 0.02, 0.01, 0.0].shuffle(random: Random.new(seed))
      branches = (1..4).map { |index| branch_task(index, delays[index - 1]) }
      workflow = branches.reduce(:&)

      Berylx::EffectTree.run(workflow, Berylx::Lay[]).focus.to_h
    end

    assert(results.all? { |run| run == { winner: 4 } },
           "definition order must win regardless of completion timing, got #{results.inspect}")
  end

  # reducer が受け取る枝の順を直接記録する版。逆順 sleep (先頭の枝が最も
  # 遅い) でも reducer には定義順で渡る。
  def test_reducer_receives_branches_in_definition_order
    branches = (1..4).map do |index|
      Berylx::Task[:"id#{index}"] do |lay|
        sleep((5 - index) * 0.01) # 完了順は定義順の真逆
        lay[:id].set(index)
      end
    end
    order_collector = lambda do |left, right|
      Berylx::Lay[order: left.to_h.fetch(:order, []) + [right.to_h[:id]]]
    end
    workflow = branches.reduce(:&).reduce(order_collector)

    result = Berylx::EffectTree.run(workflow, Berylx::Lay[])

    assert_equal [1, 2, 3, 4], result.focus.to_h[:order]
  end

  # ================================================================
  # Merge の性格 — deep は右バイアスで非可換、strict は共通の親スナップ
  # ショットとの差分で衝突を判定する (キーの有無ではない)。
  # ================================================================

  def set_task(key, value, name:)
    Berylx::Task[name] { |lay| lay[key].set(value) }
  end

  def test_merge_deep_is_right_biased_and_not_commutative
    left = set_task(:x, :from_left, name: :left)
    right = set_task(:x, :from_right, name: :right)

    assert_equal :from_right, (left & right).call(Berylx::Lay[]).focus.to_h[:x]
    assert_equal :from_left, (right & left).call(Berylx::Lay[]).focus.to_h[:x]
  end

  # nil で初期化されたキー: 両枝が別の値へ動かしたら衝突。キーは最初から
  # 「在る」ので、これはキーの有無ではなく base との差分で判定されている。
  def test_merge_strict_conflicts_on_a_nil_initialized_key
    left = set_task(:k, 1, name: :left)
    right = set_task(:k, 2, name: :right)
    workflow = (left & right).reduce(Berylx::Merge.strict)

    result = workflow.call(Berylx::Lay[k: nil])

    assert_instance_of Berylx::Err, result
    assert_equal :merge_conflict, result.code
    assert_equal %i[k], result.error.metadata[:path]
  end

  # 片方の枝だけが base から動かしたなら衝突ではない — 動いた側が採られる。
  def test_merge_strict_takes_the_changed_side_against_the_base_snapshot
    mover = set_task(:k, 1, name: :mover)
    bystander = set_task(:other, true, name: :bystander)
    workflow = (mover & bystander).reduce(Berylx::Merge.strict)

    result = workflow.call(Berylx::Lay[k: nil])

    assert_instance_of Berylx::Ok, result
    assert_equal({ k: 1, other: true }, result.focus.to_h)
  end

  # 両枝が同じ値へ動かしたなら衝突ではない (差分が一致する)。
  def test_merge_strict_accepts_identical_changes
    left = set_task(:k, 1, name: :left)
    right = set_task(:k, 1, name: :right)
    workflow = (left & right).reduce(Berylx::Merge.strict)

    result = workflow.call(Berylx::Lay[k: nil])

    assert_instance_of Berylx::Ok, result
    assert_equal({ k: 1 }, result.focus.to_h)
  end
end
