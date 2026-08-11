# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# ==================================================================
# 圏としての berylx — 設計が乗っている法則を、主張ではなく検証にする。
#
# 𝐖 (workflow の圏)
#   対象 : Lay (focus の形)
#   射   : Lay -> Result[Lay]   (Task / Sequence / Parallel / Branch / Rescue)
#   合成 : >>                   恒等 : Ok(lay) をそのまま返す Task
#
# 𝐄 (darkcore Effect 木の Kleisli 圏)
#   合成 : Effect#bind          恒等 : Darkcore.pure
#
# EffectTree.compile は 𝐖 → 𝐄 の関手であり、handler マップの差し替えは
# 「圏の選択」である — これが README と AGENTS.md の中心的な主張。
# 主張である以上ここで縛る。この suite が緑でなければ
# 「workflow を書き換えず handler だけ差し替える」は成立していない。
#
# 合わせて、成り立たない法則 (parallel の対称性) も明示的に固定する。
# 黙って非対称なのが最悪で、境界が判っていれば最適化の可否を判断できる。
# ==================================================================
class CategoryLawsTest < Minitest::Test
  # --- 射の部品 ----------------------------------------------------
  def set(key, value, name: key)
    Berylx::Task[name] { |lay| lay[key].set(value) }
  end

  def reject(name, code)
    Berylx::Task[name] { |lay| lay.reject(code, code.to_s) }
  end

  # 恒等射 — 受け取った lay をそのまま返す。
  def id_task
    Berylx::Task[:id] { |lay| lay }
  end

  def execute(node, focus = Berylx::Lay[])
    Berylx::EffectTree.run(node, focus)
  end

  # Focus は == を持たないので to_h で突き合わせる。
  def assert_same_envelope(expected, actual, message = nil)
    assert_equal expected.class, actual.class, message
    assert_equal expected.focus.to_h, actual.focus.to_h, message
    return if expected.is_a?(Berylx::Ok)

    assert_equal expected.code, actual.code, message
    assert_equal expected.failed_node, actual.failed_node, message
  end

  # Task 名だけを拾う aspect を巻いて workflow を走らせ、記録を返す。
  # parallel の branch は別スレッドで走るので記録先はスレッドセーフにする。
  def audit_names(workflow, focus = Berylx::Lay[])
    seen = Thread::Queue.new
    handlers = Berylx::EffectTree.around do |tag, payload, handler|
      seen << payload[0].name if tag == Berylx::EffectTree::TASK
      handler.call(payload)
    end
    Berylx::EffectTree.run(workflow, focus, handlers: handlers)
    [].tap { |names| names << seen.pop until seen.empty? }
  end

  # ================================================================
  # 1. 結合律 — (f >> g) >> h == f >> (g >> h)
  # ================================================================

  # Sequence は入れ子を flat_map で潰すので、結合律は挙動だけでなく
  # 構造の上でも成り立つ (どちらも同じ steps に正規化される)。
  def test_sequence_composition_is_associative_structurally
    f = set(:a, 1)
    g = set(:b, 2)
    h = set(:c, 3)

    left = (f >> g) >> h
    right = f >> (g >> h)

    assert_equal left.steps, right.steps
  end

  def test_sequence_composition_is_associative_on_the_success_path
    f = set(:a, 1)
    g = set(:b, 2)
    h = set(:c, 3)

    result = execute((f >> g) >> h)

    assert_same_envelope result, execute(f >> (g >> h))
    assert_equal({ a: 1, b: 2, c: 3 }, result.focus.to_h)
  end

  # 短絡したときも結合律は保たれ、部分状態も一致していなければならない。
  def test_sequence_composition_is_associative_on_the_error_path
    f = set(:a, 1)
    g = reject(:g, :boom)
    h = set(:c, 3)

    result = execute((f >> g) >> h)

    assert_same_envelope result, execute(f >> (g >> h))
    assert_instance_of Berylx::Err, result
    assert_equal({ a: 1 }, result.focus.to_h)
  end

  # ================================================================
  # 2. 単位律 — id >> f == f == f >> id
  # ================================================================

  def test_identity_task_is_a_two_sided_unit
    f = set(:a, 1)
    expected = execute(f)

    assert_same_envelope expected, execute(id_task >> f)
    assert_same_envelope expected, execute(f >> id_task)
  end

  # Err 側でも恒等射は何も足さない (短絡が単位律を壊さない)。
  def test_identity_task_is_a_two_sided_unit_on_the_error_path
    f = reject(:f, :boom)
    expected = execute(f)

    assert_same_envelope expected, execute(id_task >> f)
    assert_same_envelope expected, execute(f >> id_task)
  end

  # ================================================================
  # 3. 関手則 — compile(f >> g) == compile(g) ∘ compile(f)
  #    右辺の ∘ は Result の Kleisli 合成 (Err なら g を走らせない)。
  # ================================================================

  def test_compile_preserves_composition_on_the_success_path
    f = set(:a, 1)
    g = set(:b, 2)

    assert_same_envelope kleisli(f, g), execute(f >> g)
  end

  def test_compile_preserves_composition_on_the_error_path
    f = reject(:f, :boom)
    g = set(:b, 2)

    assert_same_envelope kleisli(f, g), execute(f >> g)
  end

  # f を走らせてから、Ok のときだけ g をその focus で走らせる。
  def kleisli(first, second, focus = Berylx::Lay[])
    result = execute(first, focus)
    result.is_a?(Berylx::Ok) ? execute(second, result.focus) : result
  end

  # ================================================================
  # 4. 自然性 — handler マップの差し替えは構造を保つ
  #    (圏を選び直しても workflow の形は変わらない)
  # ================================================================

  def test_handler_swap_preserves_the_result_envelope
    workflow = (set(:a, 1) & set(:b, 2)) >> set(:c, 3)
    audited = Berylx::EffectTree.around { |_tag, payload, handler| handler.call(payload) }

    assert_same_envelope execute(workflow),
                         Berylx::EffectTree.run(workflow, Berylx::Lay[], handlers: audited)
  end

  # aspect は合成子の内側にも届かなければならない。ここが落ちるなら
  # 「retry / audit は handler 差し替えで後付けできる」(README) は
  # Sequence でしか成り立っていないことになる。
  def test_aspect_reaches_inside_parallel
    workflow = (set(:a, 1) & set(:b, 2)) >> set(:c, 3)

    assert_equal %i[a b c], audit_names(workflow).sort
  end

  def test_aspect_reaches_inside_branch
    branch = (Berylx::When[:pos] { |lay| lay[:n].get.positive? } >> set(:sign, :plus)) |
             (Berylx::Else >> set(:sign, :minus))

    assert_equal %i[sign], audit_names(branch, Berylx::Lay[n: 1])
  end

  # 回復は RECOVER effect として handler マップの中で適用されるので、
  # aspect は rescue の body だけでなく回復 handler の実行にも届く
  # (詳細な pin は test/recovery_effect_test.rb)。
  def test_aspect_reaches_recovery_inside_rescue
    workflow = reject(:boom, :kaboom).rescue_with(set(:c, 3))

    assert_equal %i[boom c], audit_names(workflow)
  end

  # ================================================================
  # 5. ⊗ (parallel) の対称性 — どこまで成り立つかの境界
  #    木の並べ替え / バッチ化を後で入れるなら、その正当性は
  #    ここで固定した境界の内側でしか主張できない。
  # ================================================================

  # 互いに素な書き込みなら順序に依らない = 対称。
  def test_parallel_is_symmetric_for_disjoint_writes
    f = set(:a, 1)
    g = set(:b, 2)

    assert_equal execute(f & g).focus.to_h, execute(g & f).focus.to_h
  end

  # 衝突する書き込みは strict merge なら順序に依らず弾かれる = 対称。
  def test_parallel_is_symmetric_under_strict_merge
    f = set(:x, 1, name: :f)
    g = set(:x, 2, name: :g)

    left = execute((f & g).reduce(Berylx::Merge.strict))
    right = execute((g & f).reduce(Berylx::Merge.strict))

    assert_instance_of Berylx::Err, left
    assert_equal :merge_conflict, left.code
    assert_same_envelope left, right
  end

  # 既定の deep merge は衝突時「後勝ち」なので順序に依存する = 非対称。
  def test_parallel_deep_merge_is_not_symmetric_on_conflicting_writes
    f = set(:x, 1, name: :f)
    g = set(:x, 2, name: :g)

    refute_equal execute(f & g).focus.to_h, execute(g & f).focus.to_h
  end

  # accumulate は「誤差の集合」としては対称。ただし封筒の primary
  # (failed_node / trace) は branch 順に依存するので完全な対称ではない。
  def test_parallel_accumulate_is_symmetric_as_an_error_set_only
    f = reject(:f, :f_failed)
    g = reject(:g, :g_failed)

    left = execute((f & g).accumulate)
    right = execute((g & f).accumulate)

    assert_equal left.parallel_errors.map(&:failed_node).sort,
                 right.parallel_errors.map(&:failed_node).sort
    refute_equal left.failed_node, right.failed_node
  end

  # short_circuit (既定) は非対称 — 両方失敗すると先頭の枝の誤差が返る。
  # つまり ⊗ の並べ替えが安全なのは accumulate + strict merge のときだけ。
  def test_parallel_short_circuit_is_not_symmetric
    f = reject(:f, :f_failed)
    g = reject(:g, :g_failed)

    assert_equal :f, execute(f & g).failed_node
    assert_equal :g, execute(g & f).failed_node
  end

  # ================================================================
  # 6. Kleisli 法則 — Task.identity と >> を生成した鎖の上で縛る。
  #    生成器は成功 (set / inc)・失敗 (reject)・履歴依存 (Catch) を混ぜる。
  #    Catch を含んでも >> の結合律が崩れないのは Sequence が入れ子を
  #    flat_map で潰すから — どの結合順も同じ steps 列に正規化される。
  # ================================================================

  CHAIN_CASES = 40

  def gen_node(rng, index)
    case rng.rand(6)
    when 0 then set(:"k#{rng.rand(3)}", rng.rand(100), name: :"set#{index}")
    when 1 then Berylx::Task[:"inc#{index}"] { |lay| lay[:count].update { |count| count + 1 } }
    when 2 then reject(:"boom#{index}", :boom)
    when 3 then Berylx::Task.identity
    when 4 then Berylx::Catch[:"catch#{index}"] { |_error, lay| lay[:rescued].set(true) }
    else        set(:count, rng.rand(10), name: :"reset#{index}")
    end
  end

  def each_generated_chain(size)
    CHAIN_CASES.times do |seed|
      rng = Random.new(seed)
      yield Array.new(size) { |index| gen_node(rng, index) }
    end
  end

  def test_task_identity_returns_ok_of_the_input_lay
    result = execute(Berylx::Task.identity, Berylx::Lay[a: 1])

    assert_instance_of Berylx::Ok, result
    assert_equal({ a: 1 }, result.focus.to_h)
  end

  def test_task_identity_is_a_left_and_right_unit_over_generated_chains
    each_generated_chain(2) do |nodes|
      chain = nodes.reduce(:>>)
      expected = execute(chain, Berylx::Lay[count: 0])

      assert_same_envelope expected, execute(Berylx::Task.identity >> chain, Berylx::Lay[count: 0])
      assert_same_envelope expected, execute(chain >> Berylx::Task.identity, Berylx::Lay[count: 0])
    end
  end

  def test_sequence_is_associative_over_generated_chains
    each_generated_chain(3) do |(first, second, third)|
      left = (first >> second) >> third
      right = first >> (second >> third)

      assert_equal left.steps, right.steps
      assert_same_envelope execute(left, Berylx::Lay[count: 0]),
                           execute(right, Berylx::Lay[count: 0])
    end
  end
end
