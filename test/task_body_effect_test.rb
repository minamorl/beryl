# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# Task の body が Effect を返せることの契約 (berylx@1.0)。
#
# 0.9 までの穴: substrate.no_opaque_thunk は Task *ノード* の表現しか
# 縛っておらず、body の中身は縛っていなかった。body 内で起こした作用は
# effect 木に現れないので、handler マップで選べる圏が Task の粒度で止まり、
# body 内部の実行水準は handler の外 (プロセス全体の env など) で決まった。
#
# 縛る pin:
#   substrate.task_body_return   berylx.task.body.return in [focus, effect]
#   substrate.task_body_category berylx.task.body.effect.category = same_handler_map
#   substrate.aspect_reach       berylx.aspect.reach に task_body_effect を含む
class TaskBodyEffectTest < Minitest::Test
  MEASURE = :measure

  def measuring_task(name = :measure_task)
    Berylx::Task[name] do |lay|
      Darkcore.op(MEASURE, lay[:x].get).bind do |measured|
        Darkcore.pure(lay[:y].set(measured))
      end
    end
  end

  # 作用の解釈だけを足した圏。合成子の解釈は既定が降りてくる
  # (aspect は差分だけ書けばよい)。圏が木の隅々まで届くことは
  # category_propagation_test が別に縛る。
  def category(measure)
    Berylx::EffectTree.category(MEASURE => measure)
  end

  def run_with(node, focus, handlers)
    Berylx::EffectTree.run(node, focus, handlers: handlers)
  end

  # ------------------------------------------------------------------
  # body が Effect を返せること。fold を渡さない経路 (Root | Task の直接
  # 実行 / C interpreter からの委譲) は定義により real 圏なので、real の
  # handler マップで畳まれる。
  # ------------------------------------------------------------------
  def test_body_may_return_an_effect
    handlers = category(->(x) { x * 10 })
    result = run_with(measuring_task, { x: 4 }, handlers)

    assert_instance_of Berylx::Ok, result
    assert_equal 40, result.focus[:y].get
  end

  def test_body_returning_a_focus_still_works
    plain = Berylx::Task[:plain] { |lay| lay[:y].set(lay[:x].get + 1) }
    result = Berylx::Root[x: 4] | plain

    assert_equal 5, result.focus[:y].get
  end

  # ------------------------------------------------------------------
  # 芯: **圏の選択が body の内側まで届く**。同じ workflow を書き換えずに、
  # handler マップを差し替えるだけで body 内の作用の解釈が変わること。
  # ------------------------------------------------------------------
  def test_the_same_workflow_reads_differently_under_a_different_category
    flow = measuring_task >> Berylx::Task[:double] { |lay| lay[:y].set(lay[:y].get * 2) }

    fast = run_with(flow, { x: 4 }, category(->(x) { x * 10 }))
    canon = run_with(flow, { x: 4 }, category(->(x) { x * 100 }))

    assert_equal 80, fast.focus[:y].get
    assert_equal 800, canon.focus[:y].get
  end

  # 同じ木・同じ入力なら圏が違っても一致する、という差分検証がこの機構の
  # 上に一文で書けること (native 水準と正典水準の突き合わせがこの形になる)。
  def test_two_categories_agreeing_is_expressible_as_one_statement
    flow = measuring_task
    native = run_with(flow, { x: 7 }, category(->(x) { x + x }))
    oracle = run_with(flow, { x: 7 }, category(->(x) { x * 2 }))

    assert_equal oracle.focus[:y].get, native.focus[:y].get
  end

  # 作用の解釈が失敗しても結果封筒に入る (result.no_implicit_raise を
  # body 内の作用まで一貫させる)。
  def test_a_failing_handler_lands_in_the_result_envelope
    result = run_with(measuring_task, { x: 4 }, category(->(_) { raise ArgumentError, 'bad measure' }))

    assert_instance_of Berylx::Err, result
    assert_equal :measure_task, result.error.failed_node
    assert_equal 'bad measure', result.error.message
  end

  # 未知タグ (handler マップに対応が無い) も他の例外と同じ扱いになる
  # (spec: berylx.task.body.unknown_tag = result_envelope)。失敗した Task 名が
  # failed_node に残る点も同じ。
  def test_an_unhandled_tag_lands_in_the_result_envelope
    stray = Berylx::Task[:stray] { |_lay| Darkcore.op(:nobody_handles_this) }
    result = run_with(stray, { x: 1 }, Berylx::EffectTree.real_handlers)

    assert_instance_of Berylx::Err, result
    assert_equal :stray, result.error.failed_node
    assert_instance_of KeyError, result.error.cause
  end

  # 短絡は変わらない: Err のあとの Task は body ごと発火しない。
  def test_sequence_still_short_circuits_before_an_effect_body
    fired = []
    failing = Berylx::Task[:fail] { |lay| lay.reject(:nope, 'stop here') }
    watcher = Berylx::Task[:watch] do |lay|
      fired << :body
      Darkcore.pure(lay)
    end
    result = run_with(failing >> watcher, { x: 1 }, Berylx::EffectTree.real_handlers)

    assert_instance_of Berylx::Err, result
    assert_empty fired
  end

  # ------------------------------------------------------------------
  # C interpreter は Task#call へ委譲する (fold 無し = real 圏)。Effect を
  # 返す body でも pure Ruby fold と同じ封筒になること。
  # ------------------------------------------------------------------
  def test_native_and_pure_ruby_agree_on_an_effect_returning_body
    skip 'berylx_native is not compiled' unless Berylx::EffectTree::Native.available?

    body = Berylx::Task[:native_body] do |lay|
      Darkcore.pure(lay[:y].set(lay[:x].get + 1))
    end
    native = Berylx::EffectTree::Native.run_entry(body, x: 41)
    pure = run_with(body, { x: 41 }, Berylx::EffectTree.real_handlers.dup)

    assert_equal 42, native.focus[:y].get
    assert_equal pure.focus[:y].get, native.focus[:y].get
    assert_equal pure.class, native.class
  end

  # ------------------------------------------------------------------
  # 純粋性は **作者の宣言** でのみ成立する。berylx は推論しない
  # (spec: berylx.task.body.purity = declared / forbid inferred)。
  # 宣言が無ければ dry_run は body を呼ばない = 副作用ゼロを保つ。
  # ------------------------------------------------------------------
  def test_dry_run_does_not_fire_an_undeclared_body
    fired = []
    watcher = Berylx::Task[:watch] do |lay|
      fired << :body
      Darkcore.pure(lay)
    end
    plan = Berylx::EffectTree.dry_run(watcher, x: 1)

    assert_equal [:watch], plan.steps
    assert_empty fired, '宣言の無い body は dry_run で呼ばれてはならない'
  end

  # 宣言された body だけ、dry_run が踏み込んで作用を列挙する
  # (spec: berylx.dry_run.body_enumeration = declared_pure_only)。
  def test_dry_run_enumerates_effects_of_a_declared_pure_body
    declared = Berylx::Task[:declared, pure: true] do |lay|
      Darkcore.op(MEASURE, lay[:x].get).bind { |v| Darkcore.pure(lay[:y].set(v)) }
    end
    seen = []
    plan = Berylx::EffectTree.dry_run(declared, { x: 4 }, MEASURE => lambda { |arg|
      seen << arg
      0
    })

    assert_equal [:declared], plan.steps
    assert_equal [4], seen, '宣言された body の作用は計画に現れる'
  end

  # dry_run は状態を進めない。宣言された body を組んでも focus は変わらない。
  def test_dry_run_of_a_declared_body_does_not_advance_the_focus
    declared = Berylx::Task[:declared, pure: true] do |lay|
      Darkcore.op(MEASURE, lay[:x].get).bind { |v| Darkcore.pure(lay[:y].set(v)) }
    end
    plan = Berylx::EffectTree.dry_run(declared, { x: 4 }, MEASURE => ->(_) { 999 })

    assert_nil plan.result.focus[:y].maybe
  end

  # 宣言は real 圏の振る舞いを変えない (宣言はあくまで dry 側への約束)。
  def test_declaring_purity_does_not_change_the_real_run
    declared = Berylx::Task[:declared, pure: true] do |lay|
      Darkcore.op(MEASURE, lay[:x].get).bind { |v| Darkcore.pure(lay[:y].set(v)) }
    end
    plain = Berylx::Task[:plain] do |lay|
      Darkcore.op(MEASURE, lay[:x].get).bind { |v| Darkcore.pure(lay[:y].set(v)) }
    end
    handlers = category(->(v) { v * 3 })

    assert_equal run_with(plain, { x: 4 }, handlers).focus[:y].get,
                 run_with(declared, { x: 4 }, handlers).focus[:y].get
  end

  def test_purity_defaults_to_undeclared
    refute_predicate Berylx::Task[:anon] { |lay| lay }, :pure_body?
    assert_predicate Berylx::Task[:anon, pure: true] { |lay| lay }, :pure_body?
  end
end
