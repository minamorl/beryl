# frozen_string_literal: true

module Berylx
  # ==================================================================
  # Berylx::EffectTree (combinator interpreters) — EffectTree を再オープンして
  # parallel / branch / rescue の real interpreter を足す。
  #
  # core (effect_tree.rb) は compile / build / run / handler マップの骨格だけを
  # 持ち、各合成子の「berylx 圏の algebra」(短絡・merge・回復・trace 付与) は
  # ここに置く。darkcore の bind は構造の接ぎ木のみで、圏の algebra は現れない。
  # Err 判定・失敗合成・回復といった意味はすべて berylx 側のこの site で行う。
  #
  # いずれも legacy 実行 (Parallel#call / Branch#call / Rescue#call) と同一
  # セマンティクスになるよう写している (両走差分検証で保証)。
  # ==================================================================
  module EffectTree
    module_function

    # ----------------------------------------------------------------
    # Parallel — Parallel#call と同一セマンティクス。各 branch を副木として
    # 実行し、失敗があれば on_err (payload のタグ) に従って合成、無ければ
    # reducer で focus を merge する。short_circuit / accumulate は handler の
    # 分岐ではなく payload の node.on_err (タグ) で運ぶ (result.parallel_tag_controlled)。
    # ----------------------------------------------------------------
    def run_parallel(node, focus, handlers)
      threads = node.branches.map { |branch| Thread.new { run_subtree(branch, focus, handlers) } }
      branch_results = join_all(threads)
      failures = branch_results.grep(Err)

      return parallel_handle_failures(node, focus, failures) unless failures.empty?

      merged = parallel_merge(node, focus, branch_results)
      return merged if merged.is_a?(Err)

      Result.ok(merged)
    end

    # 枝を必ず全部 join する。一つが StandardError でない例外 (呼び出し側の中断合図など)
    # で抜けたときに map(&:value) で即座に離脱すると、残りの枝が走り続け、走行が終わった
    # 後で副作用が起きる。全部待ってから最初の例外を上げ直す。
    def join_all(threads)
      results = threads.map do |thread|
        thread.value
      rescue Exception => e # rubocop:disable Lint/RescueException
        e
      end
      raised = results.find { |r| r.is_a?(Exception) }
      raise raised if raised

      results
    end

    # short_circuit なら最初の Err、accumulate なら全失敗を parallel_errors に集約。
    def parallel_handle_failures(node, focus, failures)
      return failures.first if node.on_err == :short_circuit

      parallel_error(focus, failures)
    end

    def parallel_merge(node, focus, branch_results)
      branch_results.map(&:focus).reduce(focus) do |acc, branch_focus|
        parallel_call_reducer(node.reducer, acc, branch_focus, focus)
      end
    rescue StandardError => e
      Result.err(focus, Error.from(e, failed_node: :parallel, trace: [:parallel]))
    end

    def parallel_call_reducer(reducer, left, right, base)
      if reducer.arity == 3
        reducer.call(left, right, base)
      else
        reducer.call(left, right)
      end
    end

    def parallel_error(focus, failures)
      primary = failures.first
      errors = failures.map(&:error)
      error =
        Error[
          :parallel_failed,
          "#{failures.size} parallel branch#{'es' unless failures.size == 1} failed",
          cause: primary.cause,
          failed_node: primary.failed_node,
          trace: primary.trace,
          parallel_errors: errors
        ]

      Err.new(primary.focus || focus, error)
    end

    # ----------------------------------------------------------------
    # Branch — Branch#call と同一セマンティクス。最初に match した arm の
    # body を副木として実行し、無ければ :no_branch_matched で Err。
    # predicate 評価は純粋計算なので handler 内で回す。
    # ----------------------------------------------------------------
    def run_branch(node, focus, handlers)
      arm = node.arms.find { |candidate| branch_matches?(candidate.predicate, focus) }
      return Result.err(focus, :no_branch_matched) unless arm

      run_subtree(arm.body, focus, handlers)
    end

    def branch_matches?(predicate, focus)
      predicate.else_branch || predicate.block.call(focus)
    end

    # ----------------------------------------------------------------
    # Rescue — body を副木として実行し、Ok ならそのまま、Err なら回復を
    # RECOVER effect として現在の handler マップへ発行する。回復の適用は
    # 木の外ではなくマップの中 (real_recover) で起きるので、around aspect は
    # 回復も観測でき、回復の中の作用も同じ圏で解釈される。
    # ----------------------------------------------------------------
    def run_rescue(node, focus, handlers)
      result = run_subtree(node.body, focus, handlers)
      return result if result.is_a?(Ok)

      dispatch_recover(node, result, handlers)
    end

    # 回復を RECOVER effect として発行する。handlers が around の巻いた
    # マップなら、この発行も wrapper を通る (= aspect が回復を観測する)。
    def dispatch_recover(node, error_result, handlers)
      Darkcore.fold(
        Darkcore.op(RECOVER, [node, error_result]),
        on_return: ->(x) { x }, handlers: handlers
      )
    end

    # RECOVER の real interpreter — Rescue と Sequence 内の Catch 境界で共有
    # する berylx 圏の algebra。RescueBlock (ブロック handler) はエラー・focus・
    # performer を受け取り、node handler (Task など) は副木として同じ handler
    # マップで実行される — 回復の中の io.perform も dry-run / audit から見える。
    # handler 自身が Err を返したら回復失敗として元エラーを metadata に畳む
    # (ブロックと node で同じ規則。docs/error-handling.md の契約)。
    def real_recover(node, error_result, handlers)
      recovery = node.handler
      handler_result =
        if recovery.is_a?(RescueBlock)
          recovery.call(error_result.focus, error_result, Perform.new(handlers))
        else
          run_subtree(recovery, error_result.focus, handlers)
        end

      handler_result.is_a?(Err) ? rescue_failed(error_result, handler_result) : handler_result
    end

    def rescue_failed(original_result, handler_result)
      error = handler_result.error.with_context(metadata: { rescued_error: original_result.error.to_h })
      Err.new(handler_result.focus, error)
    end
  end
end
