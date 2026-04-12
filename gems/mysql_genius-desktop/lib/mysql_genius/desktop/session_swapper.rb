# frozen_string_literal: true

module MysqlGenius
  module Desktop
    class SessionSwapper
      def initialize(app_class, config)
        @app_class = app_class
        @config = config
      end

      def switch_to(profile_name)
        profile = @config.profile_by_name(profile_name)
        raise ActiveSession::ConnectError, "Profile '#{profile_name}' not found" unless profile

        switch_config = build_switch_config(profile.mysql)
        new_session = ActiveSession.new(switch_config)
        old_session = @app_class.settings.active_session

        @app_class.settings.stats_collector&.stop
        @app_class.settings.stats_history&.clear

        @app_class.set(:active_session, new_session)
        @app_class.set(:current_profile_name, profile_name)

        new_history   = MysqlGenius::Core::Analysis::StatsHistory.new
        conn_proc     = -> { @app_class.settings.active_session.checkout { |a| a } }
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
