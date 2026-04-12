# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Thread-safe in-memory ring buffer that stores per-digest query stats
      # snapshots. Each digest key maps to an array of snapshots capped at
      # +max_samples+. Oldest entries are dropped when the cap is reached.
      class StatsHistory
        DEFAULT_MAX_SAMPLES = 1440

        def initialize(max_samples: DEFAULT_MAX_SAMPLES)
          @max_samples = max_samples
          @mutex = Mutex.new
          @data = {}
        end

        def record(digest_text, snapshot)
          @mutex.synchronize do
            buf = (@data[digest_text] ||= [])
            buf << snapshot
            buf.shift if buf.length > @max_samples
          end
        end

        def series_for(digest_text)
          @mutex.synchronize do
            (@data[digest_text] || []).dup
          end
        end

        def digests
          @mutex.synchronize { @data.keys.dup }
        end

        def clear
          @mutex.synchronize { @data.clear }
        end
      end
    end
  end
end
