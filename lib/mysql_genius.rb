# frozen_string_literal: true

require "mysql_genius/version"
require "mysql_genius/configuration"
require "mysql_genius/database_config"
require "mysql_genius/database_registry"
require "mysql_genius/sql_validator"
require "mysql_genius/connection_pool"

module MysqlGenius
  class Error < StandardError; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
      @registry_built = false
    end

    def databases
      ensure_registry_built!
      configuration.databases
    end

    private

    def ensure_registry_built!
      return if @registry_built

      DatabaseRegistry.build!(configuration)
      @registry_built = true
    end
  end
end

require "mysql_genius/engine" if defined?(Rails)
