# frozen_string_literal: true

require "yaml"
require "erb"

module MysqlGenius
  module DatabaseRegistry
    MYSQL_ADAPTERS = ["mysql2", "trilogy", "jdbcmysql"].freeze
    YAML_DEFAULTS_KEYS = [
      "blocked_tables",
      "masked_column_patterns",
      "featured_tables",
      "default_columns",
      "max_row_limit",
      "default_row_limit",
      "query_timeout_ms",
    ].freeze

    class << self
      def build!(config)
        yaml = load_yaml_files
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.info("[MG-build!] yaml_nil=#{yaml.nil?} yaml=#{yaml.inspect[0..200]}")
        end
        load_yaml(yaml, config) if yaml
        detect_databases(config)
      end

      def load_yaml_files
        base_path = defined?(Rails) ? Rails.root.join("config", "mysql_genius.yml") : nil
        return unless base_path&.exist?

        base = safe_load_yaml(base_path.read) || {}
        env_path = Rails.root.join("config", "mysql_genius.#{Rails.env}.yml")
        if env_path.exist?
          env = safe_load_yaml(env_path.read) || {}
          base = deep_merge(base, env)
        end
        base
      end

      def load_yaml(yaml, config)
        return if yaml.nil?

        excludes = Array(yaml["exclude"]).map(&:to_s)

        if (defaults = yaml["defaults"])
          YAML_DEFAULTS_KEYS.each do |key|
            config.public_send(:"#{key}=", defaults[key]) if defaults.key?(key)
          end
        end

        if (databases = yaml["databases"])
          databases.each do |key, settings|
            next if excludes.include?(key.to_s)

            db_config = config.database(key)
            db_config.load_from_yaml(settings) if settings.is_a?(Hash)
          end
        end
      end

      def detect_databases(config)
        if defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:configurations)
          detect_from_rails(config)
        end

        config.database(:primary) if config.databases.empty?
      end

      def multi_db?(config)
        config.databases.size > 1
      end

      def default_key(config)
        config.databases.keys.first || :primary
      end

      def deep_merge(base, override)
        base.merge(override) do |_key, old_val, new_val|
          if old_val.is_a?(Hash) && new_val.is_a?(Hash)
            deep_merge(old_val, new_val)
          else
            new_val
          end
        end
      end

      private

      def safe_load_yaml(content)
        yaml_str = ERB.new(content).result
        if YAML.method(:safe_load).parameters.any? { |_type, name| name == :permitted_classes }
          YAML.safe_load(yaml_str, permitted_classes: [Symbol])
        else
          YAML.safe_load(yaml_str, [Symbol])
        end
      end

      def detect_from_rails(config)
        configs = ActiveRecord::Base.configurations
        if configs.respond_to?(:configs_for)
          detect_from_rails_6_1_plus(config, configs)
        elsif configs.is_a?(Hash)
          detect_from_rails_legacy(config, configs)
        end
      end

      def detect_from_rails_6_1_plus(config, configs)
        env_configs = configs.configs_for(env_name: Rails.env)
        env_configs.each do |db_config|
          adapter = db_config.respond_to?(:adapter) ? db_config.adapter : db_config.configuration_hash[:adapter].to_s
          next unless MYSQL_ADAPTERS.include?(adapter)

          spec_name = db_config.respond_to?(:spec_name) ? db_config.spec_name : db_config.name
          key = spec_name.to_sym
          config.database(key) unless config.databases.key?(key)
          config.databases[key].connection_spec = spec_name
        end
      end

      def detect_from_rails_legacy(config, configs)
        env_configs = configs[Rails.env]
        return unless env_configs.is_a?(Hash)

        if env_configs.key?("adapter")
          if MYSQL_ADAPTERS.include?(env_configs["adapter"])
            config.database(:primary) unless config.databases.key?(:primary)
          end
        else
          env_configs.each do |key, db_hash|
            next unless db_hash.is_a?(Hash) && MYSQL_ADAPTERS.include?(db_hash["adapter"].to_s)

            sym_key = key.to_sym
            config.database(sym_key) unless config.databases.key?(sym_key)
            config.databases[sym_key].connection_spec = key
          end
        end
      end
    end
  end
end
