# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

gem 'minitest', '~> 5.0'
gem 'rake', '~> 13.0'
gem 'rubocop', '~> 1.64', require: false
gem 'rubocop-minitest', '~> 0.35', require: false

# darkcore effect substrate — berylx workflow の唯一の実行基盤。
# 未公開 gem のため sibling repo (../darkcore-ruby) への path 依存。
# berylx の必須依存なので無条件に束ねる (遅延・条件付きではない)。
gem 'darkcore', path: File.expand_path('../darkcore-ruby', __dir__)

# spinel — 意味論的部分型の判定コア。ore-stack 条件 B の辺 type_to_description を
# 測るためだけに要る開発依存で、berylx の runtime 依存ではない
# (gemspec には足さない。berylx.spec が縛るのは darkcore の必須性だけ)。
group :test do
  gem 'spinel', path: File.expand_path('../spinel', __dir__)
end
