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
        registry = MysqlGenius.database_registry
        unless registry.empty?
          histories = MysqlGenius::StatsHistories.new
          collectors = {}

          registry.each do |db|
            history = MysqlGenius::Core::Analysis::StatsHistory.new
            histories[db.key] = history
            # Closure captures `db` per iteration so each collector polls
            # its own database — Ruby block-local binding keeps these
            # isolated even though we're in a shared loop.
            connection_provider = -> { db.connection }
            collectors[db.key] = MysqlGenius::Core::Analysis::StatsCollector.new(
              connection_provider: connection_provider,
              history: history,
            )
          end

          MysqlGenius.stats_history = histories
          MysqlGenius.stats_collector = collectors
          collectors.each_value(&:start)
          at_exit { collectors.each_value(&:stop) }
        end
      end
    end
  end
end
