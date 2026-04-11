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
    end
  end
end
