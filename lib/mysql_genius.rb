require "mysql_genius/version"
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
  end
end

require "mysql_genius/engine" if defined?(Rails)
