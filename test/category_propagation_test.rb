# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# 選んだ圏 (handler マップ) は木の隅々まで届かねばならない。
#
# 摩擦(実測): 合成子は副木を **明示的に** 走らせるので、そこで real 圏を
# 決め打ちにしていると、自作の圏が Parallel / Rescue / Catch を越えた瞬間に
# real へ戻っていた。Sequence だけ通っていたのは、外側の fold が同じマップで
# 畳むから。この状態では substrate.task_body_category / aspect_reach は
# Task 単体と Sequence でしか成り立たない。
#
# 縛る pin: substrate.category_propagation
#           berylx.category.propagation = through_combinators
class CategoryPropagationTest < Minitest::Test
  MEASURE = :measure

  # body が作用を起こす Task。作用の解釈は圏が決めるので、この Task 自身は
  # 「何倍するか」を知らない。
  def measuring(name, key)
    Berylx::Task[name] do |lay|
      Darkcore.op(MEASURE, lay[:x].get).bind { |measured| Darkcore.pure(lay[key].set(measured)) }
    end
  end

  def failing(name = :boom)
    Berylx::Task[name] { |lay| lay.reject(:nope, 'fails on purpose') }
  end

  def tenfold
    Berylx::EffectTree.category(MEASURE => ->(x) { x * 10 })
  end

  def run_in(node, handlers, focus = { x: 5 })
    Berylx::EffectTree.run(node, focus, handlers: handlers)
  end

  def assert_reached(node, expected, message)
    result = run_in(node, tenfold)

    assert_instance_of Berylx::Ok, result, "#{message}: #{result.error.message if result.is_a?(Berylx::Err)}"
    assert_equal expected, result.focus.to_h.except(:x), message
  end

  def test_category_reaches_a_bare_task
    assert_reached measuring(:plain, :a), { a: 50 }, 'Task 単体'
  end

  def test_category_reaches_across_a_sequence
    assert_reached measuring(:s1, :a) >> measuring(:s2, :b), { a: 50, b: 50 }, 'Sequence'
  end

  # 合成子は副木を明示的に走らせる。ここが real 決め打ちだと圏が失われる。
  def test_category_reaches_into_parallel_branches
    assert_reached measuring(:p1, :a) & measuring(:p2, :b), { a: 50, b: 50 }, 'Parallel'
  end

  def test_category_reaches_a_rescue_handler
    assert_reached failing.rescue_with(measuring(:h1, :a)), { a: 50 }, 'Rescue の handler'
  end

  # Sequence 内の Catch 境界は木を組む側に handler マップが無い。だから回復
  # そのものを effect ノード (RECOVER) にして、圏に解釈させている。
  def test_category_reaches_a_catch_handler
    assert_reached failing >> Berylx::Catch[:catcher, measuring(:h2, :a)], { a: 50 }, 'Catch の handler'
  end

  def test_category_reaches_through_nesting
    nested = failing.rescue_with(measuring(:n1, :a)) & measuring(:n2, :b)

    assert_reached nested, { a: 50, b: 50 }, 'parallel の中の rescue'
  end

  # 圏が本当に効いていること (real にフォールバックして「たまたま通った」の
  # ではないこと) を、二つの圏で違う答えが出ることで確かめる。
  def test_two_categories_give_different_answers_everywhere
    node = failing.rescue_with(measuring(:r, :a)) & measuring(:p, :b)
    ten = run_in(node, Berylx::EffectTree.category(MEASURE => ->(x) { x * 10 }))
    hundred = run_in(node, Berylx::EffectTree.category(MEASURE => ->(x) { x * 100 }))

    assert_equal({ a: 50, b: 50 }, ten.focus.to_h.except(:x))
    assert_equal({ a: 500, b: 500 }, hundred.focus.to_h.except(:x))
  end

  # 既定の圏はただ一つの凍結マップであり続ける (native gate の同一性判定が
  # これに依存している)。category が毎回新しいマップを返すことも要る。
  def test_the_real_category_stays_a_single_frozen_map
    assert_same Berylx::EffectTree::REAL_HANDLERS, Berylx::EffectTree.real_handlers
    assert_predicate Berylx::EffectTree::REAL_HANDLERS, :frozen?
    refute_same Berylx::EffectTree::REAL_HANDLERS, Berylx::EffectTree.category
  end

  # aspect は差分だけ書けばよい: category に載せた自作 handler 以外は
  # 既定の解釈が降りてくる。
  def test_a_category_only_has_to_write_its_difference
    handlers = Berylx::EffectTree.category(MEASURE => ->(x) { x + 1 })

    assert_equal Berylx::EffectTree::REAL_HANDLERS.keys.sort, (handlers.keys - [MEASURE]).sort
  end

  # dry_run も category の上に差分を載せる形にしたので、計画列挙は変わらない。
  def test_dry_run_is_unaffected
    plan = Berylx::EffectTree.dry_run(failing >> Berylx::Catch[:catcher, measuring(:h2, :a)], x: 1)

    assert_equal [:boom], plan.steps
  end
end
