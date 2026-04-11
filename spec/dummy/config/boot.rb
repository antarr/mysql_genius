# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)
ENV["RAILS_ENV"] ||= "test"
require "bundler/setup"
