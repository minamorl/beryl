# frozen_string_literal: true

module Berylx
  # ==================================================================
  # Berylx::Perform — Task の本体から作用を発行するための入口。
  #
  # Task のブロックが 2 引数を取ると、第二引数にこれが渡る:
  #
  #   load_user = Berylx::Task[:load_user] do |lay, io|
  #     row = io.perform(:db_query, ['select * from users where id = ?', id])
  #     lay[:user].set(row)
  #   end
  #
  # ブロックは素の直線的な Ruby のまま。darkcore の Effect 型も bind も
  # surface には出てこない (AGENTS.md: substrate はユーザーが書く対象では
  # ない)。ユーザーが触るのは「tag と payload を渡す」ことだけで、これは
  # DSL ではなくただのデータ。
  #
  # perform はいま workflow を解釈している handler マップへ tag で
  # ディスパッチする (spec: effect.dispatch = by_tag)。だから圏の選択は
  # Task の内側にも効く — 同じ workflow が本物の DB でも、決定的な虚構の
  # 値でも、監査付きでも、一文字も書き換えずに走る。
  #
  # 未定義 tag は darkcore と同じく KeyError で明示的に落ちる。黙って nil を
  # 返すと「その作用は起きなかった」と区別できなくなるため。
  # ==================================================================
  class Perform
    def initialize(handlers)
      @handlers = handlers
    end

    def perform(tag, payload = nil)
      raise ArgumentError, ':pure is reserved (closed effect)' if tag == :pure

      handler = @handlers.fetch(tag) { raise KeyError, "no handler for effect: #{tag.inspect}" }
      handler.call(payload)
    end
  end
end
