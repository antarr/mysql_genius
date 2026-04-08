module MysqlGenius
  class Engine < ::Rails::Engine
    isolate_namespace MysqlGenius

    initializer "mysql_genius.slow_query_monitor" do
      ActiveSupport.on_load(:active_record) do
        if MysqlGenius.configuration.redis_url.present?
          require "mysql_genius/slow_query_monitor"
          MysqlGenius::SlowQueryMonitor.subscribe!
        end
      end
    end
  end
end
