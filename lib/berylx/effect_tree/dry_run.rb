# frozen_string_literal: true

module Berylx
  # ==================================================================
  # Berylx::EffectTree (dry-run aspect) — EffectTree を再オープンして
  # dry-run interpreter を足す。real interpreter (effect_tree.rb) と
  # 同じ Effect 木を共有し、handler マップだけを差し替えることで
  # 「実行せず計画 (Task 名の列) を列挙する」圏を選ぶ。
  #
  # 掟 (spec-system pins) との対応:
  #   - substrate.aspect_via_handler: workflow 本体 (Effect 木) を書き換えず
  #       handler 差し替えだけで dry-run aspect を後付けする。
  #   - substrate.no_opaque_thunk  : Task の block / branch predicate 以外の
  #       副作用は発火させない (計画列挙は副作用ゼロ)。
  # ==================================================================
  module EffectTree
    module_function

    # dry-run: Task を実行せず計画 (Task 名の列) を列挙する。常に Ok(focus)
    # を返すため短絡せず全ステップを辿る。合成子も副作用ゼロで step のみ列挙。
    #
    # extra は「自分のタグを dry でどう読むか」。pure: true を宣言した body の
    # 作用はここへ降りてくるので、列挙したいタグの解釈を呼び手が渡す。
    # 渡さなければ未知タグとして落ちる — 黙って何事も無かったことにするより、
    # 「宣言した body が :foo を起こすのに :foo の読み方が無い」と言う方がよい。
    def dry_run(node, focus, extra = {})
      steps = []
      DryRun.new(run(node, focus, handlers: dry_handlers(steps, extra)), steps)
    end

    # steps を共有した dry handler マップ。合成子 dry handler は副木の実行に
    # 同じ steps を共有する dry_handlers(steps) を使うので、再帰しても計画は
    # 1 本の steps に積み上がる (aspect は handler 差し替えだけで切り替わる)。
    # category の上に dry の差分だけを載せる。dry では起きないはずのタグ
    # (RECOVER など) も category から降りてくるので、抜け落ちて KeyError に
    # ならない — aspect は「差分だけ書く」ままでいられる。
    def dry_handlers(steps, extra = {})
      category(
        {
          TASK => ->(payload) { dry_task(payload, steps, extra) },
          PARALLEL => ->(payload) { dry_parallel(payload[0], payload[1], steps, extra) },
          BRANCH => ->(payload) { dry_branch(payload[0], payload[1], steps, extra) },
          RESCUE => ->(payload) { dry_rescue(payload[0], payload[1], steps, extra) }
        }.merge(extra)
      )
    end

    # 宣言の無い body は呼ばない (副作用ゼロ)。**作者が pure: true と宣言した
    # body だけ** 組み立てて、返ってきた Effect を dry の圏で畳む — そこで
    # 初めて body 内の作用が計画に現れる
    # (spec: berylx.dry_run.body_enumeration = declared_pure_only)。
    def dry_task(payload, steps, extra = {})
      task, focus = payload
      steps << task.name
      return Result.ok(focus) unless task.pure_body?

      produced = task.build_body(focus)
      return Result.ok(focus) unless produced.is_a?(Darkcore::Effect)

      fold_body(produced, dry_handlers(steps, extra))
      Result.ok(focus) # dry では body の戻り値を採用しない (状態を進めない)。
    end

    # dry-run 用の合成子: 副作用ゼロで step のみ列挙する。
    #   parallel — 全 branch を列挙 (順序は branch 順で決定的にするため逐次)。
    #   branch   — predicate を評価し match した arm のみ列挙。
    #   rescue   — body のみ列挙 (dry では body は必ず Ok なので handler は発火しない)。
    def dry_parallel(node, focus, steps, extra = {})
      node.branches.each { |branch| run_subtree(branch, focus, dry_handlers(steps, extra)) }
      Result.ok(focus)
    end

    def dry_branch(node, focus, steps, extra = {})
      arm = node.arms.find { |candidate| branch_matches?(candidate.predicate, focus) }
      run_subtree(arm.body, focus, dry_handlers(steps, extra)) if arm
      Result.ok(focus)
    end

    def dry_rescue(node, focus, steps, extra = {})
      run_subtree(node.body, focus, dry_handlers(steps, extra))
      Result.ok(focus)
    end
  end
end
