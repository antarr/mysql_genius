# frozen_string_literal: true

source "https://rubygems.org"

gemspec

if ENV["RAILS_VERSION"]
  rails_version = ENV["RAILS_VERSION"]
  gem "actionpack", "~> #{rails_version}.0"
  gem "activerecord", "~> #{rails_version}.0"
  gem "railties", "~> #{rails_version}.0"
end

group :development, :test do
  gem "rake"
  gem "rspec", "~> 3.0"
  gem "rubocop"
  gem "rubocop-shopify"
  gem "rubocop-rspec"
end
