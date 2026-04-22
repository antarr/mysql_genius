# frozen_string_literal: true

require "json"
require "time"

module MysqlGenius
  # Rails-side slow query capture via ActiveSupport::Notifications. Complements
  # the performance_schema reader in Core::Analysis::SlowQueries by adding
  # Rails-level context (ActiveRecord query :name) that MySQL itself can't see.
  #
  # Slow queries are pushed into a per-database Redis list — so a Rails app with
  # multiple connections (primary, analytics, shards) can show each database's
  # slow queries on its own dashboard tab. During the transition from the 0.8.x
  # single-key layout, entries are dual-written to the legacy global key so any
  # old tooling still has something to read. Dual-write is dropped in 0.10.
  #
  # Redis keys:
  #   Per-database:  mysql_genius:<database_id>:slow_queries
  #   Legacy global: mysql_genius:slow_queries  (dual-written during 0.9.x)
  class SlowQueryMonitor
    MAX_ENTRIES_PER_KEY = 200
    SQL_TRUNCATE_BYTES = 10_000

    class << self
      # Legacy global key. Kept for backwards compat during dual-write.
      # Readers should prefer redis_key_for(database_id) first and fall back
      # here only when per-DB data hasn't accrued yet.
      def redis_key
        "mysql_genius:slow_queries"
      end

      # Per-database key for a given database id. Used by the controller to
      # scope slow-query reads to the current tab.
      def redis_key_for(database_id)
        "mysql_genius:#{database_id}:slow_queries"
      end

      def subscribe!
        ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, start, finish, _id, payload|
          duration_ms = ((finish - start) * 1000).round(1)
          sql = payload[:sql].to_s
          threshold = MysqlGenius.configuration.slow_query_threshold_ms

          next if duration_ms < threshold
          next unless sql.match?(/\ASELECT\b/i)
          next if sql.include?("SCHEMA")
          next if sql.include?("EXPLAIN")
          next if payload[:name] == "SCHEMA"

          begin
            database = resolve_database(payload[:connection])
            entry = build_entry(sql, duration_ms, payload[:name], database).to_json
            push_entry(entry, database)
          rescue => e
            Rails.logger.debug("[mysql_genius] Slow query logger error: #{e.message}") if defined?(Rails)
          end
        end
      end

      private

      # Resolve the database this notification came from by inspecting the
      # AR connection attached to the payload. Returns nil for connections
      # not registered in DatabaseRegistry — callers must fall back to the
      # legacy key so no data is lost.
      def resolve_database(ar_connection)
        return nil unless ar_connection
        return nil unless MysqlGenius.respond_to?(:database_registry)

        MysqlGenius.database_registry.find_by_connection(ar_connection)
      end

      def build_entry(sql, duration_ms, name, database)
        {
          sql: sql.length > SQL_TRUNCATE_BYTES ? sql[0, SQL_TRUNCATE_BYTES] : sql,
          duration_ms: duration_ms,
          timestamp: Time.now.iso8601,
          name: name,
          database: database&.key,
        }
      end

      # Dual-write: always push to the legacy global key so 0.8.x dashboards
      # still have data. When the source database is resolved, also push to
      # the per-DB key so the new scoped dashboards can filter accurately.
      # Trim both lists to the same cap.
      def push_entry(entry, database)
        redis = Redis.new(url: MysqlGenius.configuration.redis_url)

        redis.lpush(redis_key, entry)
        redis.ltrim(redis_key, 0, MAX_ENTRIES_PER_KEY - 1)

        return unless database

        key = redis_key_for(database.key)
        redis.lpush(key, entry)
        redis.ltrim(key, 0, MAX_ENTRIES_PER_KEY - 1)
      end
    end
  end
end
