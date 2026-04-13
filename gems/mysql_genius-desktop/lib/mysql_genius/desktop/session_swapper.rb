# frozen_string_literal: true

module MysqlGenius
  module Desktop
    class SessionSwapper
      def initialize(app_class, config, database)
        @app_class = app_class
        @config = config
        @database = database
      end

      def switch_to(profile_name)
        profile = @database.find_profile(profile_name)
        raise ActiveSession::ConnectError, "Profile '#{profile_name}' not found" unless profile

        mysql_config = Config::MysqlConfig.from_hash(mysql_hash_from_profile(profile))
        switch_to_config(profile_name, mysql_config)
      end

      def switch_to_config(profile_name, mysql_config)
        session_config = build_switch_config(mysql_config)
        new_session = ActiveSession.new(session_config)
        old_session = @app_class.settings.active_session

        @app_class.settings.stats_collector&.stop
        @app_class.settings.stats_history&.clear

        @config.instance_variable_set(:@default_profile, profile_name)

        @app_class.set(:active_session, new_session)
        @app_class.set(:current_profile_name, profile_name)

        new_history   = SqliteStatsHistory.new(@database)
        conn_proc     = -> { ActiveSession.open_adapter_for(session_config) }
        new_collector = MysqlGenius::Core::Analysis::StatsCollector.new(
          connection_provider: conn_proc,
          history:             new_history,
        )
        @app_class.set(:stats_history, new_history)
        @app_class.set(:stats_collector, new_collector)
        new_collector.start

        old_session&.close
      end

      private

      def mysql_hash_from_profile(profile)
        {
          "host" => profile["host"],
          "port" => profile["port"],
          "username" => profile["username"],
          "password" => profile["password"],
          "database" => profile["database_name"],
          "tls_mode" => profile["tls_mode"],
        }
      end

      def build_switch_config(mysql_config)
        Config.allocate.tap do |c|
          c.instance_variable_set(:@profiles, [Config::ProfileConfig.new(name: "_switch", mysql: mysql_config)])
          c.instance_variable_set(:@default_profile, "_switch")
          c.instance_variable_set(:@query, @config.query)
          c.instance_variable_set(:@security, @config.security)
          c.instance_variable_set(:@ai, @config.ai)
          c.instance_variable_set(:@server, @config.server)
          c.instance_variable_set(:@source_path, @config.source_path)
        end
      end
    end
  end
end
