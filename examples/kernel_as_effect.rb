# frozen_string_literal: true

# 一つの言語に見えるか — 実行水準の選択を「圏の選択」に合流させる
# ===========================================================================
#
# darkcore の掟は spec でこう書かれている:
#
#     category.selection = handler_map
#     io.representation  = tagged_effect      (IO は不透明サンクではなくデータ)
#     core.algebra.site in [handler, on_return]
#
# moissanite の掟は言葉が違うだけで同じ形をしている:
#
#     カーネルは式木 (不透明サンクではなくデータ)
#     意味は oracle / cc / tcc のどれで解釈するかで決まる
#     算術の algebra が現れるのは interpreter と emitter だけ
#
# **同じ法が二つの高度で二回**書かれている。だからこの二つは「たまたま
# 一緒に使える二つの gem」ではなく、一つの世界観の上下になる。
#
# 0.9 までは継ぎ目が一箇所ずれていた。水準の選び方が違ったのである:
#
#     darkcore/berylx : handler マップを差し替える  (プログラム内の選択)
#     moissanite      : MOISSANITE_BACKEND を見る   (プロセス外の選択)
#
# しかも実害があった。Task の block の中でカーネルを呼ぶと **その呼び出しは
# effect 木から見えない**。berylx 自身の掟 substrate.no_opaque_thunk を、
# 継ぎ目の所で破っていた。
#
# berylx@1.0 で Task の body が Effect を返せるようになったので、カーネル
# 呼び出しを tagged effect にすれば継ぎ目が閉じる:
#
#     substrate.task_body_return   berylx.task.body.return in [focus, effect]
#     substrate.task_body_category berylx.task.body.effect.category = same_handler_map
#     substrate.aspect_reach       berylx.aspect.reach に task_body_effect を含む
#
# 結果として、**workflow を一行も書き換えずに handler マップだけで
# 「この flow は native / この flow は oracle」を選べる**ようになる。
# 同一プロセスで両方走らせて突き合わせられるので、継ぎ目をまたいだ差分検証が
# 圏の選択だけで書ける。
#
# 走らせ方:  ruby examples/kernel_as_effect.rb
# ===========================================================================

require 'berylx'
require 'moissanite'

# ---------------------------------------------------------------------------
# 1. 語彙 — カーネル呼び出しを tagged effect にする。payload は
#    [カーネル, 引数] という検査可能なデータで、**カーネル自身が式木**なので
#    payload の中身まで覗ける。ここでは何も起きない。
# ---------------------------------------------------------------------------
KERNEL = :moissanite_kernel

def run_kernel(kernel, *args) = Darkcore.op(KERNEL, [kernel, args])

# ---------------------------------------------------------------------------
# 2. workflow — Task の body が Effect を返す。カーネルは実行時のレシピから
#    組むので、係数は定数として機械語へ畳まれる (AOT に真似できない所)。
# ---------------------------------------------------------------------------
RECIPE = { gain: 1.8, offset: -0.35, clip: 2.5 }.freeze

def conditioner(recipe)
  Moissanite::Pipeline.f64
                      .map { |v| (v * recipe.fetch(:gain)) + recipe.fetch(:offset) }
                      .map { |v| v.abs.sqrt }
                      .map { |v| v.min(recipe.fetch(:clip)).max(-recipe.fetch(:clip)) }
end

PIPELINE = conditioner(RECIPE)
CONDITION = PIPELINE.fuse(:condition)
ENERGY = PIPELINE.map { |v| v * v }.sum(:energy)

Validate = Berylx::Task[:validate] do |lay|
  samples = lay[:samples].get
  if !samples.is_a?(Moissanite::Buffer) || samples.size.zero?
    lay.reject(:empty_signal, 'expected a non-empty Moissanite::Buffer')
  else
    lay[:count].set(samples.size)
  end
end

# body が Effect を返す。カーネルはここでは走らない — 走らせ方は圏が決める。
#
# pure: true は「この body は副作用を起こさず、作用は Effect を組んで返すだけ」
# という **作者の宣言**。berylx はこれを推論しない (呼んでみるまで判らず、
# 呼んだ時点で宣言の無い Task の副作用が発火してしまうので、「呼んで確かめる」
# 形の推論は原理的に採れない)。宣言があると dry_run が body まで踏み込んで
# 作用を列挙できる。
#
# dry_run は状態を進めないので、宣言する body は前段が置いた値に頼らない方が
# よい (ここでは samples から数え直している)。
Condition = Berylx::Task[:condition, pure: true] do |lay|
  samples = lay[:samples].get
  conditioned = Moissanite::Buffer.f64(samples.size)
  run_kernel(CONDITION, conditioned, samples, samples.size)
    .bind { Darkcore.pure(lay[:conditioned].set(conditioned)) }
end

Measure = Berylx::Task[:measure, pure: true] do |lay|
  samples = lay[:samples].get
  run_kernel(ENERGY, samples, samples.size).bind do |energy|
    Darkcore.pure(lay[:energy].set(energy)[:rms].set(Math.sqrt(energy / samples.size)))
  end
end

WORKFLOW =
  Validate >>
  Condition >>
  Measure >>
  Berylx::Catch[:record_failure] { |error, lay| lay[:failure].set(error.message) }

# ---------------------------------------------------------------------------
# 3. 圏 — workflow は一行も書き換えない。handler マップだけを差し替える。
#    EffectTree.category は「自分自身を副木へ渡す」マップを組むので、圏は
#    Task の body にも合成子 (parallel / rescue / catch) の内側にも届く。
#    書くのは差分 (カーネル呼び出しをどう解釈するか) だけでよい。
# ---------------------------------------------------------------------------
def category(kernel_handler)
  Berylx::EffectTree.category(KERNEL => kernel_handler)
end

# native 圏: コンパイル済みカーネルを呼ぶ。
NATIVE = ->((kernel, args)) { kernel.call(*args) }
# 正典圏: 純 Ruby oracle だけで走る。C コンパイラに一度も触らない。
ORACLE = ->((kernel, args)) { kernel.interpret(*args) }

# 監査圏: カーネルは走らせず、**式木を見せる**。木を見せられるのは、
# カーネルがサンクではなくデータだから。
def audit(log)
  lambda do |(kernel, args)|
    shape = args.map { |a| a.is_a?(Moissanite::Buffer) ? "buf(#{a.size})" : a.inspect }
    log << "#{kernel.name}(#{shape.join(', ')}) -> #{kernel.return_type}"
    log << "    guard: #{kernel.extent_guard ? 'elementwise (parallelizable, bounds-checkable)' : 'none claimed'}"
    log << "    tree:  #{kernel.to_sexp.inspect[0, 92]}..."
    kernel.return_type == :f64 ? 0.0 : 0
  end
end

# ---------------------------------------------------------------------------
if $PROGRAM_NAME == __FILE__
  n = 50_000
  samples = Moissanite::Buffer.f64(Array.new(n) { |i| Math.sin(i / 97.0) * 1.4 })
  start = { samples: samples }

  native = Berylx::EffectTree.run(WORKFLOW, start, handlers: category(NATIVE))
  oracle = Berylx::EffectTree.run(WORKFLOW, start, handlers: category(ORACLE))

  # 例は自分で不変条件を検査する (走らせること自体が検査になる)。
  unless native.focus[:rms].get == oracle.focus[:rms].get
    raise "native と oracle が食い違った: #{native.focus[:rms].get} / #{oracle.focus[:rms].get}"
  end

  puts '== 同じ workflow・違う圏 ================================================='
  puts "  native 圏: #{native.class}  rms=#{format('%.17g', native.focus[:rms].get)}"
  puts "  正典圏   : #{oracle.class}  rms=#{format('%.17g', oracle.focus[:rms].get)}"
  puts '  一致: true  <- 継ぎ目をまたいだ差分検証が、同一プロセスで圏の選択だけで書ける'
  puts

  log = []
  Berylx::EffectTree.run(WORKFLOW, start, handlers: category(audit(log)))
  puts '== 監査圏: ネイティブの一段まで木に出る ==================================='
  puts log.map { |line| "  #{line}" }
  puts

  # dry_run: 一切走らせずに計画を列挙する。**宣言された body の中の
  # カーネル呼び出しまで計画に出る** — 0.9 の頃は Task 名しか出なかった所。
  planned = []
  plan = Berylx::EffectTree.dry_run(WORKFLOW, start, KERNEL => lambda { |(kernel, args)|
    planned << "#{kernel.name} over #{args.grep(Moissanite::Buffer).map(&:size).max} elements"
    kernel.return_type == :f64 ? 0.0 : 0
  })
  puts '== dry_run: 何も走らせずに計画を列挙する ================================='
  puts "  tasks:   #{plan.steps.inspect}"
  puts "  kernels: #{planned.inspect}"
  puts '  (0.9 の頃は tasks の行しか出なかった。算術は不透明サンクの向こう側にあり、'
  puts '   40 万要素の走査が計画に一行も現れなかった)'
  puts

  # 失敗はそのまま結果封筒に入る (合成子の handler は real のままなので、
  # 短絡も Catch も圏を差し替えても効く)。
  empty = Berylx::EffectTree.run(WORKFLOW, { samples: nil }, handlers: category(NATIVE))
  puts '== 失敗経路は圏を差し替えても変わらない =================================='
  puts "  #{empty.class} / failure=#{empty.focus[:failure].maybe.inspect}"
end
