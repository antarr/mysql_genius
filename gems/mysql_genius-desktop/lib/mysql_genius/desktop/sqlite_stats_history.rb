# frozen_string_literal: true

module MysqlGenius
  module Desktop
    # SQLite-backed drop-in replacement for Core::Analysis::StatsHistory.
    # Delegates to a Database instance, translating snapshot key names
    # between the StatsCollector format (calls, total_time_ms, avg_time_ms)
    # and the Database schema (delta_calls, delta_total_time_ms, delta_avg_time_ms).
    class SqliteStatsHistory
      def initialize(database)
        @database = database
      end

      def record(digest_text, snapshot)
        db_snapshot = {
          "timestamp" => snapshot[:timestamp] || snapshot["timestamp"],
          "delta_calls" => snapshot[:calls] || snapshot["calls"] || 0,
          "delta_total_time_ms" => snapshot[:total_time_ms] || snapshot["total_time_ms"] || 0.0,
          "delta_avg_time_ms" => snapshot[:avg_time_ms] || snapshot["avg_time_ms"] || 0.0,
        }
        @database.record_snapshot(digest_text, db_snapshot)
      end

      def series_for(digest_text)
        @database.series_for(digest_text)
      end

      def digests
        @database.digests
      end

      def clear
        @database.clear
      end
    end
  end
end
