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
    #
    # When a profile has SSH enabled, an SshTunnel is opened first and
    # Trilogy connects to 127.0.0.1:<local_port> instead of the remote
    # host directly. The tunnel is closed when the session is closed,
    # and restarted on connection retry.
    class ActiveSession
      class ConnectError < StandardError; end

      RETRYABLE_ERRORS = [Trilogy::ConnectionResetError, Trilogy::ProtocolError].freeze

      class << self
        def open_adapter_for(config, tunnel_port: nil)
          host = tunnel_port ? "127.0.0.1" : config.mysql.host
          port = tunnel_port || config.mysql.port
          client = Trilogy.new(
            host:            host,
            port:            port,
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
        @tunnel = nil
        start_tunnel_if_needed
        @adapter = self.class.open_adapter_for(config, tunnel_port: tunnel_port)
        @adapter.exec_query("SELECT VERSION()")
      rescue SshTunnel::ConnectionError => e
        raise ConnectError, "Failed to open SSH tunnel to #{config.mysql.ssh_host}: #{e.message}"
      rescue StandardError => e
        raise ConnectError, connect_error_message(e)
      end

      def tunnel_port
        @tunnel&.local_port
      end

      def checkout
        @mutex.synchronize do
          yield @adapter
        end
      rescue *RETRYABLE_ERRORS
        @mutex.synchronize do
          silently_close(@adapter)
          restart_tunnel_if_needed
          @adapter = self.class.open_adapter_for(@config, tunnel_port: tunnel_port)
          yield @adapter
        end
      end

      def close
        @mutex.synchronize do
          silently_close(@adapter)
          @adapter = nil
          stop_tunnel
        end
      end

      private

      def start_tunnel_if_needed
        return unless @config.mysql.ssh_enabled?

        @tunnel = SshTunnel.new(
          ssh_host:    @config.mysql.ssh_host,
          ssh_port:    @config.mysql.ssh_port,
          ssh_user:    @config.mysql.ssh_user,
          ssh_key_path: @config.mysql.ssh_key_path,
          ssh_password: @config.mysql.ssh_password,
          remote_host: @config.mysql.host,
          remote_port: @config.mysql.port,
        )
        @tunnel.start
      end

      def stop_tunnel
        @tunnel&.stop
        @tunnel = nil
      rescue StandardError
        # swallow — we're tearing down
      end

      def restart_tunnel_if_needed
        return unless @tunnel

        stop_tunnel
        start_tunnel_if_needed
      end

      def connect_error_message(error)
        if @tunnel
          "Failed to connect to MySQL at 127.0.0.1:#{tunnel_port} (via SSH tunnel to #{@config.mysql.ssh_host}): #{error.message}"
        else
          "Failed to connect to MySQL at #{@config.mysql.host}:#{@config.mysql.port}: #{error.message}"
        end
      end

      def silently_close(adapter)
        adapter&.close
      rescue StandardError
        # swallow — we're discarding a dead connection anyway
      end
    end
  end
end
