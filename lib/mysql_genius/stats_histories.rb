# frozen_string_literal: true

module MysqlGenius
  # Keyed collection of per-database StatsHistory instances. Replaces the
  # singleton `MysqlGenius.stats_history` attribute so multi-DB deployments
  # can track digest snapshots per database.
  #
  # The engine initializer populates this at boot by iterating the
  # DatabaseRegistry; controllers read per-request via [] with the current
  # database's key.
  class StatsHistories
    def initialize
      @data = {}
      @mutex = Mutex.new
    end

    def []=(key, history)
      @mutex.synchronize { @data[key.to_s] = history }
    end

    def [](key)
      @mutex.synchronize { @data[key.to_s] }
    end

    def fetch(key, &block)
      @mutex.synchronize do
        @data.fetch(key.to_s) do
          block ? block.call(key) : raise(KeyError, "No StatsHistory for database: #{key.inspect}")
        end
      end
    end

    def keys
      @mutex.synchronize { @data.keys.dup }
    end

    def values
      @mutex.synchronize { @data.values.dup }
    end

    def each_pair(&block)
      @mutex.synchronize { @data.each_pair(&block) }
    end

    def size
      @mutex.synchronize { @data.size }
    end

    def empty?
      @mutex.synchronize { @data.empty? }
    end

    def any?
      @mutex.synchronize { @data.any? }
    end

    # Convenience for the single-DB common case — returns the first (or only)
    # history. Used by specs and by legacy callers that existed before multi-DB.
    def first
      @mutex.synchronize { @data.values.first }
    end
  end
end
