# frozen_string_literal: true

require "securerandom"
require "optparse"
require "fileutils"
require "mysql_genius/desktop/version"
require "mysql_genius/desktop/config"
require "mysql_genius/desktop/active_session"
require "mysql_genius/desktop/database"
require "mysql_genius/desktop/sqlite_stats_history"
require "mysql_genius/desktop/app"

module MysqlGenius
  module Desktop
    # CLI entry point for `mysql-genius-sidecar`. Parses flags, loads the
    # YAML config, opens an eager ActiveSession (+ SELECT VERSION() health
    # check), wires both onto Desktop::App via Sinatra settings, and hands
    # control to Puma. Any error before Puma starts is caught, printed to
    # stderr, and results in `exit(1)`.
    class Launcher
      class << self
        def call(argv = ARGV)
          new.call(argv)
        end
      end

      def call(argv)
        options = parse(argv)
        return print_version if options[:version]
        return print_help    if options[:help]

        config  = Config.load(path: options[:config], override_port: options[:port], override_bind: options[:bind])
        db      = open_database
        import_profiles(config, db)
        import_ai_config(config, db)

        session = ActiveSession.new(config)

        App.set(:mysql_genius_config, config)
        App.set(:active_session,      session)
        App.set(:database,            db)
        App.set(:boot_token, SecureRandom.hex(32))
        App.set(:current_profile_name, config.default_profile)
        App.set(:environment, :production)

        history   = SqliteStatsHistory.new(db)
        # The collector gets its own dedicated connection (not shared with
        # web requests) to avoid mutex contention and TRILOGY_INVALID_SEQUENCE_ID.
        tp        = session.tunnel_port
        conn_proc = -> { ActiveSession.open_adapter_for(config, tunnel_port: tp) }
        collector = MysqlGenius::Core::Analysis::StatsCollector.new(
          connection_provider: conn_proc,
          history:             history,
        )
        App.set(:stats_history, history)
        App.set(:stats_collector, collector)
        collector.start

        register_shutdown(session, collector)

        warn("mysql-genius-sidecar starting on http://#{config.server.bind}:#{config.server.port}/")
        start_server(port: config.server.port, bind: config.server.bind)
      rescue Config::InvalidConfigError, ActiveSession::ConnectError => e
        warn("mysql-genius-sidecar: #{e.message}")
        exit(1)
      end

      private

      def parse(argv)
        options = {}
        OptionParser.new do |o|
          o.banner = "Usage: mysql-genius-sidecar [options]"
          o.on("--config PATH", "Path to YAML config file")            { |v| options[:config]  = v }
          o.on("--port PORT", Integer, "HTTP port (overrides config)") { |v| options[:port]    = v }
          o.on("--bind HOST", "HTTP bind address (overrides config)")  { |v| options[:bind]    = v }
          o.on("--version", "Print version and exit")                  { options[:version] = true }
          o.on("-h", "--help", "Print help and exit")                  { options[:help]    = true }
        end.parse!(argv.dup)
        options
      end

      def print_version
        puts("mysql-genius-sidecar #{MysqlGenius::Desktop::VERSION}")
      end

      def print_help
        puts(<<~HELP)
          Usage: mysql-genius-sidecar [options]

              --config PATH        Path to YAML config file (overrides $MYSQL_GENIUS_CONFIG)
              --port PORT          HTTP port (overrides config.server.port)
              --bind HOST          HTTP bind address (overrides config.server.bind)
              --version            Print version and exit
              -h, --help           Print this help and exit

          Config file lookup order when --config is not passed:
              1. $MYSQL_GENIUS_CONFIG
              2. ./mysql_genius.yml
              3. ~/.config/mysql_genius/config.yml
              4. ~/.mysql_genius.yml

          See https://github.com/antarr/mysql_genius for documentation.
        HELP
      end

      def open_database
        dir = File.join(Dir.home, ".config", "mysql_genius")
        FileUtils.mkdir_p(dir)
        Database.new(File.join(dir, "mysql_genius.db"))
      end

      def import_profiles(config, db)
        return unless db.list_profiles.empty? && config.profiles.any?

        config.profiles.each do |profile|
          mysql = profile.mysql
          db.add_profile(
            "name" => profile.name,
            "host" => mysql.host,
            "port" => mysql.port,
            "username" => mysql.username,
            "password" => mysql.password,
            "database_name" => mysql.database,
            "tls_mode" => mysql.tls_mode,
          )
        end
      end

      def import_ai_config(config, db)
        return unless db.get_setting("ai.endpoint").nil? && config.ai.endpoint

        ai = config.ai
        db.set_ai_config(
          "endpoint" => ai.endpoint,
          "api_key" => ai.api_key,
          "model" => ai.model.to_s,
          "auth_style" => ai.auth_style.to_s,
          "system_context" => ai.system_context.to_s,
          "domain_context" => ai.domain_context.to_s,
        )
      end

      # Extracted so specs can stub it without booting a real server.
      def start_server(port:, bind:)
        App.run!(port: port, bind: bind)
      end

      # Extracted so specs can stub it without registering a real at_exit handler.
      def register_shutdown(session, collector = nil)
        at_exit do
          collector&.stop
          session.close
        end
      end
    end
  end
end
