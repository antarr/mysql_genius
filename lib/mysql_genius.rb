# frozen_string_literal: true

require "mysql_genius/version"
require "mysql_genius/core"
require "mysql_genius/core/connection/active_record_adapter"
require "mysql_genius/configuration"

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
    end

    attr_accessor :stats_history
    attr_accessor :stats_collector
  end
end

require "mysql_genius/engine" if defined?(Rails)
