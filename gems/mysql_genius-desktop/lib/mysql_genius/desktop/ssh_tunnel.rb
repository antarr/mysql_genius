# frozen_string_literal: true

require "net/ssh"
require "socket"

module MysqlGenius
  module Desktop
    # Opens an SSH tunnel forwarding a local port to a remote MySQL server.
    # Runs in a background thread so it doesn't block the main thread.
    #
    #   tunnel = SshTunnel.new(ssh_host: "bastion.example.com", ssh_user: "deploy",
    #                          remote_host: "db.internal", remote_port: 3306)
    #   local_port = tunnel.start
    #   # connect Trilogy to 127.0.0.1:local_port
    #   tunnel.stop
    class SshTunnel
      class ConnectionError < StandardError; end

      KEEPALIVE_INTERVAL = 30

      attr_reader :local_port

      def initialize(ssh_host:, ssh_user:, ssh_port: 22, ssh_key_path: nil, ssh_password: nil,
        remote_host:, remote_port: 3306, local_port: 0)
        @ssh_host    = ssh_host
        @ssh_port    = ssh_port
        @ssh_user    = ssh_user
        @ssh_key_path = ssh_key_path
        @ssh_password = ssh_password
        @remote_host = remote_host
        @remote_port = remote_port
        @local_port  = local_port
        @session     = nil
        @thread      = nil
        @running     = false
        @mutex       = Mutex.new
      end

      def start
        @mutex.synchronize do
          raise ConnectionError, "Tunnel is already running" if @running

          @local_port = allocate_ephemeral_port if @local_port.zero?
          @session = open_ssh_session
          setup_port_forwarding
          @running = true
          start_event_loop
        end
        @local_port
      rescue Net::SSH::AuthenticationFailed => e
        raise ConnectionError, "SSH authentication failed for #{@ssh_user}@#{@ssh_host}:#{@ssh_port}: #{e.message}"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH => e
        raise ConnectionError, "Cannot reach SSH host #{@ssh_host}:#{@ssh_port}: #{e.message}"
      rescue Net::SSH::Exception => e
        raise ConnectionError, "SSH connection to #{@ssh_host}:#{@ssh_port} failed: #{e.message}"
      rescue StandardError => e
        raise ConnectionError, "SSH tunnel to #{@ssh_host}:#{@ssh_port} failed: #{e.message}"
      end

      def stop
        @mutex.synchronize do
          @running = false
          @session&.close
          @thread&.join(5)
          @session = nil
          @thread = nil
        end
      rescue StandardError
        # swallow — we're tearing down
      end

      def running?
        @mutex.synchronize { @running && @session && !@session.closed? }
      end

      private

      def open_ssh_session
        Net::SSH.start(@ssh_host, @ssh_user, ssh_options)
      end

      def ssh_options
        opts = {
          port: @ssh_port,
          non_interactive: true,
          timeout: 10,
          keepalive: true,
          keepalive_interval: KEEPALIVE_INTERVAL,
        }

        if @ssh_key_path
          opts[:keys] = [File.expand_path(@ssh_key_path)]
          opts[:keys_only] = true
        elsif @ssh_password
          opts[:password] = @ssh_password
          opts[:auth_methods] = ["password"]
        end
        # If neither key nor password, Net::SSH falls back to ssh-agent

        opts
      end

      def allocate_ephemeral_port
        server = TCPServer.new("127.0.0.1", 0)
        server.addr[1]
      ensure
        server&.close
      end

      def setup_port_forwarding
        @session.forward.local(@local_port, @remote_host, @remote_port)
      end

      def start_event_loop
        @thread = Thread.new do
          @session.loop(0.5) { @running }
        rescue IOError, Net::SSH::Disconnect
          @running = false
        end
      end
    end
  end
end
