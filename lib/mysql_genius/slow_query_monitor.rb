require "json"

module MysqlGenius
  class SlowQueryMonitor
    def self.redis_key
      "mysql_genius:slow_queries"
    end

    def self.subscribe!
      ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, start, finish, _id, payload|
        duration_ms = ((finish - start) * 1000).round(1)
        sql = payload[:sql].to_s
        threshold = MysqlGenius.configuration.slow_query_threshold_ms

        next unless duration_ms >= threshold
        next unless sql.match?(/\ASELECT\b/i)
        next if sql.include?("SCHEMA")
        next if sql.include?("EXPLAIN")
        next if payload[:name] == "SCHEMA"

        begin
          redis = Redis.new(url: MysqlGenius.configuration.redis_url)
          entry = {
            sql: sql.truncate(10_000),
            duration_ms: duration_ms,
            timestamp: Time.current.iso8601,
            name: payload[:name]
          }.to_json

          redis.lpush(redis_key, entry)
          redis.ltrim(redis_key, 0, 199)
        rescue => e
          Rails.logger.debug("[mysql_genius] Slow query logger error: #{e.message}") if defined?(Rails)
        end
      end
    end
  end
end
