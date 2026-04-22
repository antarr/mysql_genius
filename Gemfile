# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "mysql_genius-core", path: "gems/mysql_genius-core"

if ENV["RAILS_VERSION"]
  rails_version = ENV["RAILS_VERSION"]
  gem "actionpack", "~> #{rails_version}.0"
  gem "activerecord", "~> #{rails_version}.0"
  gem "railties", "~> #{rails_version}.0"
end

group :development, :test do
  gem "rake"
  gem "rspec", "~> 3.0"
  gem "rspec-rails"
  gem "rack-test"
  gem "rubocop"
  gem "rubocop-shopify"
  gem "rubocop-rspec"
end

# Integration specs (spec/integration/, gated by REAL_MYSQL=1) talk to a real
# MySQL server via ActiveRecord. Both mysql2 and trilogy are installed so the
# integration matrix can cover both adapters without a separate bundle.
# Not loaded in default unit runs — REAL_MYSQL=1 is the trigger.
group :integration do
  gem "mysql2", "~> 0.5"
  gem "trilogy", "~> 2.9"
  gem "redis", "~> 5.0"
end
