# frozen_string_literal: true

require 'minitest/autorun'
require 'berylx'
require 'spinel'

# ore-stack 条件 B の辺 type_to_description (型=spinel → 記述=berylx) の結合テスト。
#
# この辺だけが 5 辺のうち唯一繋がっていなかった。spinel.spec も berylx.spec も互いに
# 一言も触れていないので、繋ぎ方に covering spec は無い。code-first で繋いで後から lift する。
#
# 繋ぐ位置: berylx の Task は「Lay を受けて Result[Lay] を返す名前つきブロック」であり、
# 何を要求して何を保証するかを自分では名乗らない。合成 (`>>`) の各辺が型として通るかは、
# 走らせてみるまで分からない。spinel は「s <= t ⟺ (s - t) が空」という原始演算ひとつを
# 持つので、その判定を各辺へ当てれば **走らせる前に** 合成の可否が決まる。
#
# berylx 側に型宣言の口を生やさない (converter 規則の overreach 禁止)。契約は素データとして
# 外に置き、spinel は判定だけを担う。よって berylx は spinel を runtime 依存にしない。
class SpinelContractTest < Minitest::Test
  # Task が Lay に対して要求するもの / 保証するもの。どちらも key => Spinel::Type。
  Contract = Struct.new(:requires, :provides, keyword_init: true)

  INT = Spinel.type(Integer)
  STR = Spinel.type(String)

  # --- 判定器: 合成の各辺で「上流が保証した型 <= 下流が要求する型」を spinel に訊く ---
  #
  # 包含は spinel の唯一の原始演算 (差集合の空判定) へ還元される。ここで構造比較や
  # クラスの一致判定を自前で書かない。書いた瞬間に「型層が判定する」という接続が嘘になる。
  def type_errors(program, contracts, env = {})
    errors = []

    steps_of(program).each do |task|
      contract = contracts.fetch(task.name)

      contract.requires.each do |key, required|
        provided = env[key]

        if provided.nil?
          errors << [task.name, key, :absent]
          next
        end

        # Spinel::Type は `<=` と `>=` は持つが `>` を持たない。`!(a <= b)` を
        # `a > b` へ畳むと NoMethodError になるので、否定は guard で外す。
        next if provided <= required

        errors << [task.name, key, :not_contained]
      end

      env = env.merge(contract.provides)
    end

    errors
  end

  def steps_of(program)
    program.is_a?(Berylx::Sequence) ? program.steps : [program]
  end

  # --- 題材: 数を読んで倍にして、文字にして返す 3 段 -----------------------------
  def read_n = Berylx::Task[:read_n] { |lay| lay.put(:n, 21) }
  def double_n = Berylx::Task[:double_n] { |lay| lay.put(:n, lay[:n].get * 2) }
  def render = Berylx::Task[:render] { |lay| lay.put(:label, "n=#{lay[:n].get}") }

  # read_n が数ではなく文字を置いてしまう版 (下流の掛け算が成り立たない)
  def read_n_as_string = Berylx::Task[:read_n] { |lay| lay.put(:n, '21') }

  def well_typed_contracts
    {
      read_n: Contract.new(requires: {}, provides: { n: INT }),
      double_n: Contract.new(requires: { n: INT }, provides: { n: INT }),
      render: Contract.new(requires: { n: INT }, provides: { label: STR })
    }
  end

  def ill_typed_contracts
    well_typed_contracts.merge(
      read_n: Contract.new(requires: {}, provides: { n: STR })
    )
  end

  # --- 1. 型層が通したものは、記述層で実際に走って緑になる -----------------------
  def test_well_typed_composition_is_accepted_and_actually_runs
    program = read_n >> double_n >> render

    assert_empty type_errors(program, well_typed_contracts),
                 'spinel が通した合成は型エラーを持たない'

    result = program.call(Berylx::Focus[{}])

    assert_instance_of Berylx::Ok, result
    assert_equal 42, result.focus[:n].get
    assert_equal 'n=42', result.focus[:label].get
  end

  # --- 2. 型層が落としたものを、記述層は緑のまま通してしまう ---------------------
  #
  # この辺が要る理由がここに出る。'21' * 2 は Ruby では '2121' なので、String を
  # Integer 要求へ流しても **例外にならない**。berylx は Ok を返し、間違った値が
  # そのまま下流へ流れて label にまで載る。記述層は最後まで気づかない。
  #
  # 実測 (2026-08-13): 走行結果は Ok で focus は {n: "2121", label: "n=2121"}。
  # 「型が壊れていれば実行時に落ちるはずだ」という予想は反証された。落ちない。
  # spinel はこれを走らせる前に名指しで落とす。それが型層の仕事である。
  def test_ill_typed_composition_is_rejected_by_types_but_runs_green_without_them
    program = read_n_as_string >> double_n >> render

    errors = type_errors(program, ill_typed_contracts)

    assert_equal [%i[double_n n not_contained]], errors,
                 'String を Integer 要求へ流す辺を spinel が名指しで落とす'

    result = program.call(Berylx::Focus[{}])

    assert_instance_of Berylx::Ok, result, '記述層だけでは失敗として現れない'
    assert_equal '2121', result.focus[:n].get, '倍にしたはずが文字列反復になっている'
    assert_equal 'n=2121', result.focus[:label].get, '壊れた値が下流まで運ばれる'
  end

  # --- 3. 判定は等価ではなく包含である -------------------------------------------
  #
  # 下流が Integer|String を要求するとき、Integer しか保証しない上流は通らねばならない。
  # クラスの一致で書いていたらここで落ちる。spinel が居る理由はこの 1 本に出る。
  def test_requirement_is_containment_not_equality
    lenient = well_typed_contracts.merge(
      double_n: Contract.new(requires: { n: INT | STR }, provides: { n: INT })
    )

    assert_empty type_errors(read_n >> double_n, lenient),
                 'Integer は Integer|String に含まれるので通る'

    refute_operator INT | STR, :<=, INT
    assert_operator INT, :<=, INT | STR
  end

  # --- 4. 上流が置いていない key は「不在」として名指しされる --------------------
  def test_absent_key_is_named
    orphan = Berylx::Task[:render] { |lay| lay.put(:label, 'x') }

    errors = type_errors(orphan, { render: well_typed_contracts.fetch(:render) })

    assert_equal [%i[render n absent]], errors
  end
end
