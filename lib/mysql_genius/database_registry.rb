# frozen_string_literal: true

require "mysql_genius/database"

module MysqlGenius
  # Auto-discovers MySQL connections from ActiveRecord::Base.configurations
  # for the current Rails.env, pairs writers with their replicas, and exposes
  # a keyed registry of MysqlGenius::Database instances.
  #
  # config/database.yml is the single source of truth. Engine config can trim
  # the discovered set (allowlist, blocklist) or relabel entries, but cannot
  # introduce new connections the Rails app doesn't know about.
  #
  # Empty registry is a valid state — the dashboard renders a setup page
  # directing the user to add a MySQL connection to config/database.yml.
  class DatabaseRegistry
    MYSQL_ADAPTERS = %w[mysql2 trilogy jdbcmysql mysql].freeze

    # Config names that would collide with existing URL segments under the
    # engine mount. Prefixed with "_" during discovery to avoid routing chaos.
    RESERVED_URL_SEGMENTS = %w[api].freeze

    attr_reader :databases

    def self.discover(
      configurations: default_configurations,
      env: default_env,
      config: MysqlGenius.configuration
    )
      new(configurations: configurations, env: env, config: config).tap(&:build!)
    end

    def self.default_configurations
      return nil unless defined?(ActiveRecord::Base)
      return nil unless ActiveRecord::Base.respond_to?(:configurations)

      ActiveRecord::Base.configurations
    end

    def self.default_env
      defined?(Rails) && Rails.respond_to?(:env) ? Rails.env.to_s : "test"
    end

    def initialize(configurations:, env:, config:)
      @configurations = configurations
      @env = env
      @config = config
      @databases = {}
    end

    def build!
      configs = mysql_configs_for_env
      return @databases if configs.empty?

      writers, readers = partition_writers_and_readers(configs)
      writers.each do |writer|
        key = url_safe_key(writer.name)
        next if filtered_out?(key)

        reader = find_reader_for(writer, readers)
        @databases[key] = Database.new(
          key: key,
          writer_config: writer,
          reader_config: reader,
          label: label_for(key),
        )
      end
      apply_ordering!
      @databases
    end

    def keys
      @databases.keys
    end

    def fetch(key)
      @databases.fetch(key.to_s) do
        raise KeyError, "Unknown mysql_genius database: #{key.inspect}. Known: #{keys.inspect}"
      end
    end

    def [](key)
      @databases[key.to_s]
    end

    def default_key
      return nil if @databases.empty?

      configured = @config.default_database
      if configured && @databases.key?(configured.to_s)
        configured.to_s
      else
        @databases.keys.first
      end
    end

    def empty?
      @databases.empty?
    end

    def size
      @databases.size
    end

    def each(&block)
      @databases.each_value(&block)
    end

    # Looks up a Database by AR config name (the key from config/database.yml).
    # Handles both writer and reader config names so callers that see a replica
    # connection on an ActiveSupport::Notifications payload still resolve to
    # the logical Database entry.
    #
    # Returns nil if no database matches. Callers (notably SlowQueryMonitor)
    # fall back to a global key when this happens so data isn't dropped on
    # connections mysql_genius doesn't know about.
    def find_by_config_name(config_name)
      name = config_name.to_s
      return nil if name.empty?

      @databases.each_value do |db|
        return db if db.config_names.include?(name)
      end
      nil
    end

    # Given an AR connection, returns the Database it belongs to by inspecting
    # `connection.pool.db_config.name`. Falls back to `pool.spec.name` for
    # Rails 6.0, and returns nil on any adapter that doesn't expose either
    # (e.g. non-AR connections handed in by tests).
    def find_by_connection(ar_connection)
      return nil unless ar_connection.respond_to?(:pool)

      pool = ar_connection.pool
      name = if pool.respond_to?(:db_config) && pool.db_config.respond_to?(:name)
        pool.db_config.name
      elsif pool.respond_to?(:spec) && pool.spec.respond_to?(:name)
        pool.spec.name
      end
      name ? find_by_config_name(name) : nil
    rescue StandardError
      nil
    end

    private

    def mysql_configs_for_env
      return [] if @configurations.nil?

      all = if @configurations.respond_to?(:configs_for)
        @configurations.configs_for(env_name: @env)
      else
        []
      end
      all.select { |c| MYSQL_ADAPTERS.include?(c.adapter.to_s) }
    end

    def partition_writers_and_readers(configs)
      configs.partition { |c| !replica?(c) }
    end

    def replica?(config)
      return true if config.respond_to?(:replica?) && config.replica?

      hash = config.respond_to?(:configuration_hash) ? config.configuration_hash : config
      !!(hash.is_a?(Hash) && (hash[:replica] == true || hash["replica"] == true))
    end

    # Naming conventions that Rails applications use for replica pairs:
    # - <name>_replica (PgHero/Rails guide convention)
    # - <name>_reading
    # - <name>_read
    # First matching reader wins. Returns nil if no reader paired.
    def find_reader_for(writer, readers)
      candidates = %W[
        #{writer.name}_replica
        #{writer.name}_reading
        #{writer.name}_read
      ]
      readers.find { |r| candidates.include?(r.name) }
    end

    def url_safe_key(name)
      key = name.to_s
      RESERVED_URL_SEGMENTS.include?(key) ? "_#{key}" : key
    end

    def filtered_out?(key)
      allow = Array(@config.databases).map(&:to_s)
      deny  = Array(@config.exclude_databases).map(&:to_s)
      return true if deny.include?(key)
      return true if allow.any? && !allow.include?(key)

      false
    end

    def label_for(key)
      labels = @config.database_labels || {}
      labels[key] || labels[key.to_sym] || key
    end

    def apply_ordering!
      configured_order = Array(@config.databases).map(&:to_s)
      return if configured_order.empty?

      ordered = {}
      configured_order.each do |k|
        ordered[k] = @databases[k] if @databases.key?(k)
      end
      @databases.each do |k, v|
        ordered[k] ||= v
      end
      @databases = ordered
    end
  end
end
