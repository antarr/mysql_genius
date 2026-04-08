module MysqlGenius
  class Engine < ::Rails::Engine
    isolate_namespace MysqlGenius

    config.after_initialize do
      if MysqlGenius.configuration.redis_url.present?
        require "mysql_genius/slow_query_monitor"
        MysqlGenius::SlowQueryMonitor.subscribe!
      end
    end
  end
end
