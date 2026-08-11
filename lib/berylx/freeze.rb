# frozen_string_literal: true

module Berylx
  # ==================================================================
  # Berylx::Freeze — Lay (Focus) が保持する値の深い凍結。
  #
  # 不変条件: Focus の @value は常に深く凍結された木である。これにより
  # 「捕まえた古い Lay の to_h は後続のどんな操作でも変わらない」という
  # 不変性の保証が、規約ではなく機構になる (test/lay_lens_laws_test.rb)。
  #
  # 境界の線引き:
  #   - Hash / Array / String は凍結保証の対象。未凍結のものは複製して
  #     から凍結するので、呼び出し側の可変データを勝手に凍結しない。
  #   - すでに深く凍結された部分木は同一オブジェクトのまま返す (再割当て
  #     しない) ので、set の経路コピーは構造共有を保つ。
  #   - それ以外のオブジェクト (Data、モデル等) には触れない。それらの
  #     不変性は呼び出し側の責任 (docs/root-and-lay.md に明記)。
  # ==================================================================
  module Freeze
    module_function

    def deep(value)
      case value
      when Hash   then deep_hash(value)
      when Array  then deep_array(value)
      when String then value.frozen? ? value : value.dup.freeze
      else value
      end
    end

    def deep_hash(hash)
      rebuilt = {}
      changed = !hash.frozen?
      hash.each do |key, value|
        frozen_key = deep(key)
        frozen_value = deep(value)
        changed ||= !frozen_key.equal?(key) || !frozen_value.equal?(value)
        rebuilt[frozen_key] = frozen_value
      end
      changed ? rebuilt.freeze : hash
    end

    def deep_array(array)
      rebuilt = array.map { |item| deep(item) }
      changed = !array.frozen? || rebuilt.each_with_index.any? { |item, i| !item.equal?(array[i]) }
      changed ? rebuilt.freeze : array
    end
  end
end
