# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'

# ==================================================================
# Lay (Focus) のレンズ法則 — set は純置換であり、格納された状態は深く
# 凍結された不変値である、という契約を性質テストで縛る。
#
# 重要な前提: set / update / put は「root に再フォーカスした新しい Lay」を
# 返す (focus.rb — path は [] に戻る)。だから素朴な `lay.set(v).get == v` は
# root フォーカスでしか成り立たず、法則は同じ path への再フォーカスを
# 挟んで述べる:
#
#   PutGet : at(at(lay, p).set(v), p).get == v
#   GetPut : at(lay, p).set(at(lay, p).get).to_h == lay.to_h   (key が在る状態で)
#   PutPut : at(at(lay, p).set(v1), p).set(v2).to_h == at(lay, p).set(v2).to_h
#
# key の在/不在は値と別の軸で保存される: `{}` と `{ k: nil }` は present? と
# 厳格な get が区別し、set/get の往復で混同されない。`maybe` 経由の往復は
# 欠損キーを作り出すので恒等ではない — それも明示的に pin する。
# ==================================================================
class LayLensLawsTest < Minitest::Test
  ITERATIONS = 60

  # --- 生成器: 欠損キー・nil 値・配列・凍結入力を含む入れ子 Hash ----
  def gen_value(rng, depth)
    case rng.rand(depth.zero? ? 4 : 6)
    when 0 then rng.rand(1000)
    when 1 then "s#{rng.rand(100)}"
    when 2 then nil
    when 3 then Array.new(rng.rand(3)) { rng.rand(10) }
    else        gen_hash(rng, depth - 1)
    end
  end

  def gen_hash(rng, depth)
    keys = %i[a b c d e].sample(rng.rand(1..4), random: rng)
    hash = keys.to_h { |key| [key, gen_value(rng, depth)] }
    rng.rand(3).zero? ? hash.freeze : hash
  end

  # Hash 節点まで降りられる「在る path」を全部集める (root の [] を含む)。
  def present_paths(value, prefix = [])
    return [prefix] unless value.is_a?(Hash)

    [prefix] + value.flat_map { |key, child| present_paths(child, prefix + [key]) }
  end

  # path が Hash の鎖として在る (途中で配列やスカラを踏まない) ものだけを
  # set の対象にする。set は Hash 節点の子だけを置換できる。
  def settable_paths(value)
    present_paths(value).select do |path|
      path.empty? || path[0..-2].reduce(value) { |acc, key| acc[key] }.is_a?(Hash)
    end
  end

  def at(lay, path)
    path.reduce(lay) { |focus, key| focus[key] }
  end

  def each_case
    ITERATIONS.times do |seed|
      rng = Random.new(seed)
      hash = gen_hash(rng, 3)
      lay = Berylx::Lay[hash]
      paths = settable_paths(lay.to_h)
      yield rng, lay, paths[rng.rand(paths.size)]
    end
  end

  # ================================================================
  # PutGet — set した値は同じ path から読み返せる
  # ================================================================
  def test_put_get
    each_case do |rng, lay, path|
      value = gen_value(rng, 2)
      read_back = at(at(lay, path).set(value), path).get

      if value.nil?
        assert_nil read_back, "PutGet failed at #{path.inspect}"
      else
        assert_equal value, read_back, "PutGet failed at #{path.inspect}"
      end
    end
  end

  def test_put_get_at_root_focus_needs_no_refocus
    lay = Berylx::Lay[a: 1]

    assert_equal({ b: 2 }, lay.set(b: 2).get)
  end

  # ================================================================
  # GetPut — 今の値を set し直すのは恒等 (key が在る状態に限る)
  # ================================================================
  def test_get_put
    each_case do |_rng, lay, path|
      written = at(lay, path).set(at(lay, path).get)

      assert_equal lay.to_h, written.to_h, "GetPut failed at #{path.inspect}"
    end
  end

  # key の在/不在は set/get の往復で保存される: {} と { k: nil } は別の状態。
  def test_key_presence_is_not_conflated_with_nil
    empty = Berylx::Lay[{}]
    nil_key = Berylx::Lay[k: nil]

    refute_predicate empty[:k], :present?
    assert_predicate nil_key[:k], :present?
    assert_nil nil_key[:k].get
    assert_raises(KeyError) { empty[:k].get }

    round_tripped = nil_key[:k].set(nil_key[:k].get)

    assert_equal({ k: nil }, round_tripped.to_h)
  end

  # maybe 経由の「往復」は恒等ではない — 欠損キーに nil を植えてしまう。
  # GetPut を maybe で述べ直せない境界をここで固定する。
  def test_maybe_round_trip_creates_missing_keys
    empty = Berylx::Lay[{}]
    planted = empty[:k].set(empty[:k].maybe)

    assert_equal({ k: nil }, planted.to_h)
    refute_equal empty.to_h, planted.to_h
  end

  # ================================================================
  # PutPut — 同じ path へ二度 set すれば後の値だけが残る
  # ================================================================
  def test_put_put
    each_case do |rng, lay, path|
      first = gen_value(rng, 2)
      second = gen_value(rng, 2)
      twice = at(at(lay, path).set(first), path).set(second)
      expected = at(lay, path).set(second).to_h

      if expected.nil? # root へ nil を set した退化ケース
        assert_nil twice.to_h, "PutPut failed at #{path.inspect}"
      else
        assert_equal expected, twice.to_h, "PutPut failed at #{path.inspect}"
      end
    end
  end

  # ================================================================
  # 欠損 path の set 挙動 (現行の凍結): 1 段の欠損キーは作られ、
  # 欠損した中間節点越しの set は TypeError。
  # ================================================================
  def test_set_creates_a_single_missing_key
    lay = Berylx::Lay[a: 1]

    assert_equal({ a: 1, b: 2 }, lay[:b].set(2).to_h)
  end

  def test_set_below_a_missing_intermediate_raises
    lay = Berylx::Lay[{}]

    assert_raises(TypeError) { lay[:a][:b].set(1) }
  end

  # ================================================================
  # 不変性 — 格納された状態は深く凍結され、共有可変部分構造を持たない
  # ================================================================

  # 呼び出し側が渡した Hash を後から破壊しても Lay は動じない。
  def test_construction_takes_a_defensive_deep_copy
    input = { user: { name: 'mina' }, tags: %w[a b] }
    lay = Berylx::Lay[input]
    input[:user][:name] = 'MUTATED'
    input[:tags] << 'c'

    assert_equal({ user: { name: 'mina' }, tags: %w[a b] }, lay.to_h)
  end

  # 呼び出し側の可変データは凍結しない (防御的コピーの側を凍結する)。
  def test_construction_does_not_freeze_the_callers_data
    input = { user: { name: +'mina' } }
    Berylx::Lay[input]

    refute_predicate input, :frozen?
    refute_predicate input[:user], :frozen?
  end

  # 捕まえておいた古い Lay の to_h は、後続のどんな操作の後でも値が同一。
  def test_captured_lay_is_stable_under_later_operations
    lay = Berylx::Lay[user: { name: 'mina', roles: %w[admin] }]
    snapshot = Marshal.load(Marshal.dump(lay.to_h))

    updated = lay[:user][:name].set('other')
    updated = at(updated, %i[user]).put(:extra, count: 1)
    at(updated, %i[user roles]).update { |roles| roles + %w[ops] }

    assert_equal snapshot, lay.to_h
  end

  # to_h が返す木は深く凍結されている — 黙った共有可変ではなく FrozenError。
  def test_stored_state_is_deeply_frozen
    lay = Berylx::Lay[user: { name: 'mina', roles: %w[admin] }]

    assert_predicate lay.to_h, :frozen?
    assert_predicate lay.to_h[:user], :frozen?
    assert_predicate lay.to_h[:user][:roles], :frozen?
    assert_predicate lay.to_h[:user][:roles][0], :frozen?
    assert_raises(FrozenError) { lay.to_h[:user][:name] = 'x' }
  end

  # update ブロックが受け取る値も凍結済み — その場で破壊できない。
  def test_update_block_receives_a_frozen_value
    lay = Berylx::Lay[roles: %w[admin]]

    assert_raises(FrozenError) { lay[:roles].update { |roles| roles << 'ops' } }
  end

  # update ブロックの返り値が可変でも、格納時に凍結される。
  def test_update_return_value_is_frozen_on_write
    shared = +'mutable'
    lay = Berylx::Lay[name: 'a'][:name].update { shared }

    assert_predicate lay.to_h[:name], :frozen?
    assert_equal 'mutable', lay.to_h[:name]
    shared << '!!'

    assert_equal 'mutable', lay.to_h[:name]
  end

  # 凍結済みの入力はそのまま使える (生成器由来の frozen ケースの明示版)。
  def test_frozen_inputs_are_accepted
    frozen = { a: { b: 1 }.freeze }.freeze
    lay = Berylx::Lay[frozen]

    assert_equal 2, lay[:a][:b].set(2)[:a][:b].get
    assert_equal({ a: { b: 1 } }, lay.to_h)
  end
end
