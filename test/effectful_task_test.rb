# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# ==================================================================
# 作用を発行する Task — Task 本体から darkcore の作用へ届く道。
#
# ブロックが 2 引数を取ると第二引数に Berylx::Perform が渡り、
# io.perform(tag, payload) で「いま解釈に使っている handler マップ」へ
# tag ディスパッチする。ブロックは素の直線的な Ruby のままで、
# Effect 型も bind も surface には出てこない。
#
# 一番効くのは圏の選択が Task の内側まで届くこと: 同じ workflow が
# 本物の作用でも決定的な虚構の作用でも、一文字も変えずに走る。
# ==================================================================
class EffectfulTaskTest < Minitest::Test
  # 作用を出す Task — 本体は素の Ruby に見える。
  def load_user
    Berylx::Task[:load_user] do |lay, io|
      lay[:user].set(io.perform(:db_query, lay[:id].get))
    end
  end

  # 作用を出さない Task — 従来どおり 1 引数。
  def greet
    Berylx::Task[:greet] { |lay| lay[:greeting].set("hello #{lay[:user].get[:name]}") }
  end

  def execute(node, focus, effects: {})
    Berylx::EffectTree.run(node, focus, handlers: Berylx::EffectTree.real_handlers(effects))
  end

  # ================================================================
  # 圏の選択が Task の内側まで届く — これがこの機能の要点
  # ================================================================

  def test_the_same_workflow_runs_in_a_real_and_a_virtual_category
    workflow = load_user >> greet

    real = execute(workflow, Berylx::Lay[id: 7], effects: { db_query: ->(id) { { id: id, name: "real-#{id}" } } })
    virtual = execute(workflow, Berylx::Lay[id: 7], effects: { db_query: ->(_id) { { name: 'fixture' } } })

    assert_equal 'hello real-7', real.focus.to_h[:greeting]
    assert_equal 'hello fixture', virtual.focus.to_h[:greeting]
  end

  def test_the_performed_result_lands_in_the_lay
    result = execute(load_user, Berylx::Lay[id: 3], effects: { db_query: ->(id) { { id: id } } })

    assert_instance_of Berylx::Ok, result
    assert_equal({ id: 3, user: { id: 3 } }, result.focus.to_h)
  end

  # payload は検査可能なデータとして handler に渡る (不透明サンクではない)。
  def test_the_payload_reaches_the_handler_unchanged
    seen = []
    execute(load_user, Berylx::Lay[id: 9], effects: { db_query: lambda { |id|
      seen << id
      {}
    } })

    assert_equal [9], seen
  end

  # ================================================================
  # 合成子の内側と aspect
  # ================================================================

  def test_effects_reach_task_bodies_inside_parallel
    left = Berylx::Task[:left] { |lay, io| lay[:left].set(io.perform(:tick)) }
    right = Berylx::Task[:right] { |lay, io| lay[:right].set(io.perform(:tick)) }

    result = execute(left & right, Berylx::Lay[], effects: { tick: ->(_) { :ticked } })

    assert_equal({ left: :ticked, right: :ticked }, result.focus.to_h)
  end

  # around で巻いた aspect は Task 本体が出した作用も観測できる。
  # 監査や計測が DB 呼び出しまで届くのはこの経路。
  def test_an_aspect_observes_effects_performed_from_task_bodies
    seen = Thread::Queue.new
    handlers = Berylx::EffectTree.around(db_query: ->(_id) { { name: 'x' } }) do |tag, payload, inner|
      seen << tag
      inner.call(payload)
    end

    Berylx::EffectTree.run(load_user, Berylx::Lay[id: 1], handlers: handlers)

    tags = [].tap { |acc| acc << seen.pop until seen.empty? }

    assert_includes tags, :db_query
    assert_includes tags, Berylx::EffectTree::TASK
  end

  # ================================================================
  # 失敗は明示的に
  # ================================================================

  # 未定義 tag は黙って nil を返さない — 「作用が起きなかった」と
  # 区別できなくなるため、darkcore と同じく KeyError で落ちる。
  def test_an_unhandled_effect_tag_fails_explicitly
    result = execute(load_user, Berylx::Lay[id: 1])

    assert_instance_of Berylx::Err, result
    assert_equal :KeyError, result.code
    assert_equal :load_user, result.failed_node
  end

  def test_calling_an_effectful_task_without_a_handler_map_says_so
    result = load_user.call(Berylx::Lay[id: 1])

    assert_instance_of Berylx::Err, result
    assert_equal :ArgumentError, result.code
    assert_match(/handler map/, result.message)
  end

  def test_the_pure_tag_is_reserved
    task = Berylx::Task[:bad] { |_lay, io| io.perform(:pure, 1) }

    assert_equal :ArgumentError, execute(task, Berylx::Lay[]).code
  end

  def test_effect_tags_may_not_collide_with_berylx_tags
    error = assert_raises(ArgumentError) do
      Berylx::EffectTree.real_handlers(Berylx::EffectTree::TASK => ->(_payload) {})
    end

    assert_match(/collide/, error.message)
  end

  # ================================================================
  # 後方互換
  # ================================================================

  def test_single_argument_tasks_stay_on_the_existing_path
    refute_predicate greet, :effectful?
    assert_predicate load_user, :effectful?
  end

  def test_a_workflow_without_effects_runs_with_no_handler_map_given
    result = Berylx::Flow[Berylx::Lay[user: { name: 'mina' }]].call(greet)

    assert_equal 'hello mina', result.focus.to_h[:greeting]
  end

  # ================================================================
  # Root からの経路 (root.call(workflow, handlers:)) も通る
  # ================================================================

  def test_root_commits_an_effectful_workflow
    root = Berylx::Root[id: 3]
    handlers = Berylx::EffectTree.real_handlers(db_query: ->(id) { { id: id, name: "u#{id}" } })

    result = root.call(load_user >> greet, handlers: handlers)

    assert_instance_of Berylx::Ok, result
    assert_equal 'hello u3', root.state[:greeting]
  end

  def test_root_leaves_state_untouched_when_an_effect_fails
    root = Berylx::Root[id: 3]
    handlers = Berylx::EffectTree.real_handlers(db_query: ->(_id) { raise 'database is down' })

    result = root.call(load_user >> greet, handlers: handlers)

    assert_instance_of Berylx::Err, result
    assert_equal :load_user, result.failed_node
    assert_equal({ id: 3 }, root.state)
  end
end
