# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Background sampler that periodically queries performance_schema for the
      # top 50 digests by SUM_TIMER_WAIT, computes per-interval deltas, and
      # records snapshots into a StatsHistory ring buffer.
      #
      # The +connection_provider+ is a callable (lambda/proc) that returns a
      # Core::Connection on each invocation. This allows each adapter to supply
      # its own connection strategy:
      #
      #   Rails:   -> { ActiveRecordAdapter.new(ActiveRecord::Base.connection) }
      #   Desktop: -> { session.checkout { |c| c } }
      class StatsCollector
        DEFAULT_INTERVAL = 60
        STOP_JOIN_TIMEOUT = 5
        TOP_N = 50

        def initialize(connection_provider:, history:, interval: DEFAULT_INTERVAL)
          @connection_provider = connection_provider
          @history = history
          @interval = interval
          @mutex = Mutex.new
          @cv = ConditionVariable.new
          @stop_signal = false
          @running = false
          @thread = nil
          @previous = {}
        end

        def start
          return self if @running

          @stop_signal = false
          @running = true
          @thread = Thread.new { run_loop }
          self
        end

        def stop
          @mutex.synchronize do
            @stop_signal = true
            @cv.signal
          end
          @thread&.join(STOP_JOIN_TIMEOUT)
          @thread = nil
        end

        def running?
          @running
        end

        private

        def run_loop
          loop do
            tick
            break if wait_or_stop(@interval)
          end
        rescue StandardError => e
          warn("[MysqlGenius] StatsCollector stopped: #{e.message}")
        ensure
          @running = false
        end

        def tick
          connection = @connection_provider.call
          result = connection.exec_query(build_sql(connection))
          current = {}

          result.to_hashes.each do |row|
            digest_text = (row["DIGEST_TEXT"] || row["digest_text"]).to_s
            next if digest_text.empty?

            calls = (row["COUNT_STAR"] || row["count_star"]).to_i
            total_time_ms = (row["total_time_ms"] || row["TOTAL_TIME_MS"] || 0).to_f

            current[digest_text] = { calls: calls, total_time_ms: total_time_ms }

            next unless @previous.key?(digest_text)

            record_delta(digest_text, calls, total_time_ms)
          end

          @previous = current
        end

        def record_delta(digest_text, calls, total_time_ms)
          prev = @previous[digest_text]
          delta_calls = [calls - prev[:calls], 0].max
          delta_total_ms = [(total_time_ms - prev[:total_time_ms]).round(1), 0.0].max

          @history.record(digest_text, {
            timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
            calls: delta_calls,
            total_time_ms: delta_total_ms,
            avg_time_ms: delta_calls.positive? ? (delta_total_ms / delta_calls).round(1) : 0.0,
          })
        end

        def build_sql(connection)
          <<~SQL
            SELECT
              DIGEST_TEXT,
              COUNT_STAR,
              ROUND(SUM_TIMER_WAIT / 1000000000, 1) AS total_time_ms
            FROM performance_schema.events_statements_summary_by_digest
            WHERE SCHEMA_NAME = #{connection.quote(connection.current_database)}
              AND DIGEST_TEXT IS NOT NULL
              AND DIGEST_TEXT NOT LIKE 'EXPLAIN%'
              AND DIGEST_TEXT NOT LIKE '%`information_schema`%'
              AND DIGEST_TEXT NOT LIKE '%`performance_schema`%'
              AND DIGEST_TEXT NOT LIKE '%information_schema.%'
              AND DIGEST_TEXT NOT LIKE '%performance_schema.%'
              AND DIGEST_TEXT NOT LIKE 'SHOW %'
              AND DIGEST_TEXT NOT LIKE 'SET STATEMENT %'
              AND DIGEST_TEXT NOT LIKE 'SELECT VERSION ( )%'
              AND DIGEST_TEXT NOT LIKE 'SELECT @@%'
            ORDER BY SUM_TIMER_WAIT DESC
            LIMIT #{TOP_N}
          SQL
        end

        def wait_or_stop(seconds)
          @mutex.synchronize do
            return true if @stop_signal

            @cv.wait(@mutex, seconds)
            @stop_signal
          end
        end
      end
    end
  end
end
