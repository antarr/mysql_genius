# frozen_string_literal: true

require "mysql_genius/version"
require "mysql_genius/core"
require "mysql_genius/core/connection/active_record_adapter"
require "mysql_genius/configuration"
require "mysql_genius/database_registry"

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
      reset_database_registry!
    end

    # Auto-discovered registry of MySQL connections from config/database.yml.
    # Memoized; call reset_database_registry! to force re-discovery (e.g. in specs
    # after stubbing ActiveRecord::Base.configurations).
    def database_registry
      @database_registry ||= DatabaseRegistry.discover
    end

    def reset_database_registry!
      @database_registry = nil
    end

    attr_accessor :stats_history
    attr_accessor :stats_collector
  end
end

require "mysql_genius/engine" if defined?(Rails)
