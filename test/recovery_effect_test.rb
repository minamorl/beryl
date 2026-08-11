# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# ==================================================================
# 回復 (rescue_with / Catch) と Effect 木の境界を pin する。
#
# 現在の挙動 (このコミット時点): 回復 handler は EffectTree.recover が
# 木の外で直接適用する。だから
#   - around aspect は rescue の body までしか見えず、回復は見えない
#   - effectful な回復 Task は handler マップ無しで呼ばれて失敗する
#   - 回復ブロックは performer を受け取れない
# この「外側」挙動をここで固定してから、実装を Effect 木の中へ移す。
# 反転コミットでこの pin も同時に書き換える — 挙動の変化を diff で読める
# ようにするため。
# ==================================================================
class RecoveryEffectTest < Minitest::Test
  def reject_task(name = :boom, code = :kaboom)
    Berylx::Task[name] { |lay| lay.reject(code, code.to_s) }
  end

  def set_task(key, value, name: key)
    Berylx::Task[name] { |lay| lay[key].set(value) }
  end

  # 観測された (tag, task 名) の列を返す aspect。
  def observe(workflow, focus = Berylx::Lay[], effects: {})
    seen = Thread::Queue.new
    handlers = Berylx::EffectTree.around(effects) do |tag, payload, inner|
      seen << [tag, payload[0].respond_to?(:name) ? payload[0].name : payload[0].class.name]
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

  # --- pin: aspect は回復を見ない (木の外で適用されるため) -----------
  def test_aspect_does_not_observe_a_rescue_recovery_task
    workflow = reject_task.rescue_with(set_task(:recovered, true, name: :recover))
    result, events = observe(workflow)

    assert_instance_of Berylx::Ok, result
    assert_equal %i[boom], observed_task_names(events)
  end

  def test_aspect_does_not_observe_catch_recovery
    workflow = reject_task >>
               Berylx::Catch[:mend] { |_error, lay| lay[:mended].set(true) } >>
               set_task(:after, true, name: :after)
    result, events = observe(workflow)

    assert_instance_of Berylx::Ok, result
    assert_equal %i[boom after], observed_task_names(events)
  end

  # --- pin: effectful な回復 Task は動かない (handler マップ外で呼ばれる) --
  def test_effectful_recovery_task_cannot_perform_effects
    recover = Berylx::Task[:recover] { |lay, io| lay[:v].set(io.perform(:probe, nil)) }
    workflow = reject_task.rescue_with(recover)
    result = Berylx::EffectTree.run(
      workflow, Berylx::Lay[],
      handlers: Berylx::EffectTree.real_handlers(probe: ->(_) { 42 })
    )

    assert_instance_of Berylx::Err, result
    assert_equal :ArgumentError, result.code
  end

  # --- pin: 回復ブロックは performer を受け取れない ------------------
  def test_recovery_block_has_no_performer
    workflow = reject_task.rescue_with do |_error, lay, io|
      lay[:v].set(io.perform(:probe, nil))
    end
    result = Berylx::EffectTree.run(
      workflow, Berylx::Lay[],
      handlers: Berylx::EffectTree.real_handlers(probe: ->(_) { 42 })
    )

    assert_instance_of Berylx::Err, result
    assert_equal :NoMethodError, result.code
  end

  # --- pin: 回復ブロックの Err に rescued_error metadata は付かない ----
  # (node handler の回復失敗だけが元エラーを畳む。docs はブロックにも付くと
  #  言っており、docs と code が食い違っている — 反転コミットで code を
  #  docs の契約へ揃える。)
  def test_recovery_block_err_carries_no_rescued_error_metadata
    workflow = reject_task(:boom, :orig).rescue_with do |_error, lay|
      lay.reject(:handler_failed, 'handler failed')
    end
    result = workflow.call(Berylx::Lay[])

    assert_instance_of Berylx::Err, result
    assert_equal :handler_failed, result.code
    assert_empty result.error.metadata
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
  # fatal も回復する (現行挙動 — 反転後も変えない)。
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
end
