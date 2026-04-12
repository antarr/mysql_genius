# frozen_string_literal: true

require "trilogy"
require "mysql_genius/core/connection/trilogy_adapter"

module MysqlGenius
  module Desktop
    # Lifecycle manager for a single Trilogy connection, serialized via
    # a mutex because Trilogy clients are not thread-safe and Puma is
    # multi-threaded by default. No pool — one client, one mutex.
    #
    # Eager-opens + runs SELECT VERSION() at boot as a health check.
    # Retries exactly once on ConnectionResetError / ProtocolError inside
    # #checkout. Does not retry on QueryError, TimeoutError, or anything
    # else.
    class ActiveSession
      class ConnectError < StandardError; end

      RETRYABLE_ERRORS = [Trilogy::ConnectionResetError, Trilogy::ProtocolError].freeze

      class << self
        def open_adapter_for(config)
          client = Trilogy.new(
            host:            config.mysql.host,
            port:            config.mysql.port,
            username:        config.mysql.username,
            password:        config.mysql.password,
            database:        config.mysql.database,
            ssl_mode:        tls_mode_constant(config.mysql.tls_mode),
            connect_timeout: 5,
            read_timeout:    config.query.timeout_seconds,
          )
          MysqlGenius::Core::Connection::TrilogyAdapter.new(client)
        end

        def tls_mode_constant(mode)
          case mode.to_s
          when "disabled" then Trilogy::SSL_DISABLED
          when "required" then Trilogy::SSL_REQUIRED_NOVERIFY
          else Trilogy::SSL_PREFERRED_NOVERIFY
          end
        end
      end

      def initialize(config)
        @config = config
        @mutex = Mutex.new
        @adapter = self.class.open_adapter_for(config)
        @adapter.exec_query("SELECT VERSION()")
      rescue StandardError => e
        raise ConnectError, "Failed to connect to MySQL at #{config.mysql.host}:#{config.mysql.port}: #{e.message}"
      end

      def checkout
        @mutex.synchronize do
          yield @adapter
        end
      rescue *RETRYABLE_ERRORS
        @mutex.synchronize do
          silently_close(@adapter)
          @adapter = self.class.open_adapter_for(@config)
          yield @adapter
        end
      end

      def close
        @mutex.synchronize do
          silently_close(@adapter)
          @adapter = nil
        end
      end

      private

      def silently_close(adapter)
        adapter&.close
      rescue StandardError
        # swallow — we're discarding a dead connection anyway
      end
    end
  end
end
