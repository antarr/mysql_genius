# frozen_string_literal: true

require_relative "boot"

require "rails"
require "action_controller/railtie"

Bundler.require(*Rails.groups)
require "mysql_genius"

module Dummy
  class Application < Rails::Application
    config.load_defaults(Rails::VERSION::STRING.to_f)
    config.eager_load = false
    config.cache_classes = true
    config.active_support.deprecation = :stderr
    config.secret_key_base = "dummy-secret-for-tests-only-not-a-real-secret-and-not-used"
    config.hosts.clear if config.respond_to?(:hosts)
    config.logger = Logger.new(IO::NULL)
  end
end
