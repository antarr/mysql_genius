# frozen_string_literal: true

module MysqlGenius
  class Engine < ::Rails::Engine
    isolate_namespace MysqlGenius

    initializer "mysql_genius.register_core_views", before: :add_view_paths do
      paths["app/views"] << MysqlGenius::Core.views_path
    end

    config.after_initialize do
      if MysqlGenius.configuration.redis_url.present?
        require "mysql_genius/slow_query_monitor"
        MysqlGenius::SlowQueryMonitor.subscribe!
      end

      if MysqlGenius.configuration.stats_collection
        history = MysqlGenius::Core::Analysis::StatsHistory.new
        connection_provider = -> { MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection) }
        collector = MysqlGenius::Core::Analysis::StatsCollector.new(
          connection_provider: connection_provider,
          history: history,
        )
        MysqlGenius.stats_history = history
        MysqlGenius.stats_collector = collector
        collector.start
        at_exit { collector.stop }
      end
    end
  end
end
