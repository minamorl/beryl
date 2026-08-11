# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# ==================================================================
# 回復 (rescue_with / Catch) は Effect 木の中で起きる。
#
# 以前の挙動 (直前のコミットが pin): 回復 handler は EffectTree.recover が
# 木の外で直接適用していた — aspect からは不可視、effectful な回復は不能、
# 回復ブロックに performer 無し、ブロックの Err に rescued_error 無し。
#
# 現在の契約 (このコミットで反転):
#   - body の Err は Effect(:berylx_recover, [node, error_result]) として
#     現在の handler マップへ発行される — around aspect が回復を観測する
#   - 回復 handler が node (Task 等) なら副木として同じマップで走る —
#     effectful な回復 Task の io.perform も同じ圏で解釈される
#   - 3 引数の回復ブロックは第三引数に performer を受け取る
#   - 回復の Err は block / node どちらでも rescued_error を metadata に畳む
#   - fatal の意味論は不変: Catch は既定で fatal を跳ね、rescue_with は回復する
# ==================================================================
class RecoveryEffectTest < Minitest::Test
  def reject_task(name = :boom, code = :kaboom)
    Berylx::Task[name] { |lay| lay.reject(code, code.to_s) }
  end

  def set_task(key, value, name: key)
    Berylx::Task[name] { |lay| lay[key].set(value) }
  end

  # 観測された (tag, task 名/ノード名) の列を返す aspect。
  def observe(workflow, focus = Berylx::Lay[], effects: {})
    seen = Thread::Queue.new
    handlers = Berylx::EffectTree.around(effects) do |tag, payload, inner|
      name = payload.is_a?(Array) && payload[0].respond_to?(:name) ? payload[0].name : nil
      seen << [tag, name]
      inner.call(payload)
    end
    result = Berylx::EffectTree.run(workflow, focus, handlers: handlers)
    events = []
    events << seen.pop until seen.empty?
    [result, events]
  end

  def observed_task_names(events)
    events.select { |tag, _| tag == Berylx::EffectTree::TASK }.map { |_, name| name }
  end

  # --- 反転済み pin: aspect は回復を観測する ------------------------
  def test_aspect_observes_a_rescue_recovery_task
    workflow = reject_task.rescue_with(set_task(:recovered, true, name: :recover))
    result, events = observe(workflow)

    assert_instance_of Berylx::Ok, result
    assert_equal %i[boom recover], observed_task_names(events)
    assert_includes events.map(&:first), Berylx::EffectTree::RECOVER
  end

  def test_aspect_observes_catch_recovery
    workflow = reject_task >>
               Berylx::Catch[:mend] { |_error, lay| lay[:mended].set(true) } >>
               set_task(:after, true, name: :after)
    result, events = observe(workflow)

    assert_instance_of Berylx::Ok, result
    assert_equal %i[boom after], observed_task_names(events)
    assert_includes events, [Berylx::EffectTree::RECOVER, :mend]
  end

  # timing aspect — around が回復を時間的にも観測することの証明。回復 Task の
  # 実行は RECOVER のディスパッチの内側で起きるので、RECOVER の計測時間は
  # 回復の所要時間を含む。
  def test_timing_aspect_measures_recovery
    slow_recover = Berylx::Task[:slow_recover] do |lay|
      sleep 0.02
      lay[:recovered].set(true)
    end
    timings = Thread::Queue.new
    handlers = Berylx::EffectTree.around do |tag, payload, inner|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = inner.call(payload)
      timings << [tag, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
      result
    end

    result = Berylx::EffectTree.run(workflow_with(slow_recover), Berylx::Lay[], handlers: handlers)
    entries = []
    entries << timings.pop until timings.empty?
    recover_timing = entries.find { |tag, _| tag == Berylx::EffectTree::RECOVER }

    assert_instance_of Berylx::Ok, result
    refute_nil recover_timing, 'around must observe the RECOVER dispatch'
    assert_operator recover_timing[1], :>=, 0.02
  end

  def workflow_with(recovery)
    reject_task.rescue_with(recovery)
  end

  # --- 反転済み pin: effectful な回復 Task は現在のマップで作用する -----
  def test_effectful_recovery_task_performs_through_the_current_handler_map
    recover = Berylx::Task[:recover] { |lay, io| lay[:v].set(io.perform(:probe, nil)) }
    workflow = reject_task.rescue_with(recover)
    result, events = observe(workflow, effects: { probe: ->(_) { 42 } })

    assert_instance_of Berylx::Ok, result
    assert_equal({ v: 42 }, result.focus.to_h)
    assert_includes events.map(&:first), :probe # 回復内の作用も aspect から見える
  end

  # --- 反転済み pin: 3 引数の回復ブロックは performer を受け取る --------
  def test_recovery_block_receives_a_performer_when_it_asks
    workflow = reject_task.rescue_with do |_error, lay, io|
      lay[:v].set(io.perform(:probe, nil))
    end
    result = Berylx::EffectTree.run(
      workflow, Berylx::Lay[],
      handlers: Berylx::EffectTree.real_handlers(probe: ->(_) { 42 })
    )

    assert_instance_of Berylx::Ok, result
    assert_equal({ v: 42 }, result.focus.to_h)
  end

  # 2 引数のブロックは従来どおり (error, lay) のまま。
  def test_two_argument_recovery_block_is_unchanged
    workflow = reject_task(:boom, :orig).rescue_with { |error, lay| lay[:msg].set(error.message) }
    result = workflow.call(Berylx::Lay[])

    assert_instance_of Berylx::Ok, result
    assert_equal({ msg: 'orig' }, result.focus.to_h)
  end

  # --- 反転済み pin: 回復ブロックの Err も rescued_error を畳む ---------
  # (node handler と同じ規則になった。docs/error-handling.md の契約どおり。)
  def test_recovery_block_err_folds_rescued_error_metadata
    workflow = reject_task(:boom, :orig).rescue_with do |_error, lay|
      lay.reject(:handler_failed, 'handler failed')
    end
    result = workflow.call(Berylx::Lay[])

    assert_instance_of Berylx::Err, result
    assert_equal :handler_failed, result.code
    assert_equal :orig, result.error.metadata.dig(:rescued_error, :code)
  end

  # --- 挙動維持: node handler の回復失敗は rescued_error を畳む --------
  def test_recovery_task_err_folds_rescued_error_metadata
    workflow = reject_task(:boom, :orig).rescue_with(reject_task(:mend, :handler_failed))
    result = workflow.call(Berylx::Lay[])

    assert_instance_of Berylx::Err, result
    assert_equal :handler_failed, result.code
    assert_equal :orig, result.error.metadata.dig(:rescued_error, :code)
  end

  # --- 挙動維持: fatal の意味論 --------------------------------------
  # Catch は fatal を既定で跳ね、fatal: true で opt-in。rescue_with は
  # fatal も回復する (反転前と同一)。
  def test_catch_skips_fatal_errors_by_default
    fatal = Berylx::Task[:fatal] { |lay| Berylx::Result.err(lay, :stop, 'stop', fatal: true) }
    workflow = fatal >> Berylx::Catch[:mend] { |_error, lay| lay[:mended].set(true) }
    result = workflow.call(Berylx::Lay[])

    assert_instance_of Berylx::Err, result
    assert_equal :stop, result.code
  end

  def test_rescue_with_recovers_fatal_errors
    fatal = Berylx::Task[:fatal] { |lay| Berylx::Result.err(lay, :stop, 'stop', fatal: true) }
    workflow = fatal.rescue_with(set_task(:mended, true, name: :mend))
    result = workflow.call(Berylx::Lay[])

    assert_instance_of Berylx::Ok, result
    assert_equal({ mended: true }, result.focus.to_h)
  end

  # --- 挙動維持: dry-run は回復を発火させない (body のみ列挙) ----------
  def test_dry_run_still_enumerates_body_only
    workflow = reject_task.rescue_with(set_task(:recovered, true, name: :recover))
    dry = Berylx::EffectTree.dry_run(workflow, {})

    assert_equal %i[boom], dry.steps
    assert_instance_of Berylx::Ok, dry.result
  end
end
