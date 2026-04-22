# frozen_string_literal: true

require "mysql_genius/core/connection/active_record_adapter"

module MysqlGenius
  # Wraps a single discovered MySQL connection from config/database.yml.
  #
  # Holds the writer config, optional paired reader (replica) config, and a
  # display label. Lazily establishes connections via anonymous abstract
  # ActiveRecord classes so the host app's primary ActiveRecord::Base
  # connection pool is never touched.
  #
  # Role handling: when a reader is present, #connection returns the reader's
  # adapter (we only ever issue SELECTs against performance_schema / information_schema
  # / sys, so reading from a replica is always safe and preferred). Falls back
  # to the writer when no reader is configured.
  class Database
    attr_reader :key, :label, :writer_config, :reader_config

    def initialize(key:, writer_config:, reader_config: nil, label: nil)
      @key = key.to_s
      @label = (label || @key).to_s
      @writer_config = writer_config
      @reader_config = reader_config
    end

    # Returns a Core::Connection::ActiveRecordAdapter wrapping the appropriate
    # (reader-preferred) underlying AR connection. New adapter per call, matching
    # existing BaseController#rails_connection semantics.
    def connection
      MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ar_connection)
    end

    # Raw ActiveRecord connection for this database. Returned for the handful
    # of controller callsites (a few AI features, query_history) that call
    # methods like #quote and #current_database directly instead of going
    # through the Core adapter. Reader-preferred like #connection.
    def ar_connection
      (reader? ? reader_class : writer_class).connection
    end

    def reader?
      !@reader_config.nil?
    end

    def adapter_name
      @writer_config.adapter
    end

    # AR config names bound to this database — writer first, then reader if
    # paired. Used by DatabaseRegistry#find_by_config_name to map an incoming
    # ActiveSupport::Notifications payload's connection back to the database
    # it came from (so per-DB Redis keys and audit logs route correctly).
    def config_names
      names = [@writer_config.name]
      names << @reader_config.name if @reader_config
      names
    end

    def to_s
      reader? ? "#<MysqlGenius::Database #{@key} (+replica)>" : "#<MysqlGenius::Database #{@key}>"
    end

    private

    def writer_class
      @writer_class ||= build_ar_class(@writer_config)
    end

    def reader_class
      @reader_class ||= build_ar_class(@reader_config)
    end

    # Creates an anonymous abstract ActiveRecord::Base subclass bound to the
    # given config. Each call returns a fresh class with its own pool, so
    # connections for mysql_genius databases never leak into ActiveRecord::Base
    # (the host app's primary connection).
    def build_ar_class(db_config)
      klass = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      hash = db_config.respond_to?(:configuration_hash) ? db_config.configuration_hash : db_config
      klass.establish_connection(hash)
      klass
    end
  end
end
