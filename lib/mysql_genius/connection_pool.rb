# frozen_string_literal: true

module MysqlGenius
  module ConnectionPool
    @pools = {}
    @mutex = Mutex.new

    class << self
      def connection_for(spec_name)
        @mutex.synchronize do
          @pools[spec_name] ||= establish_pool(spec_name)
        end
        @pools[spec_name].connection
      rescue StandardError
        ActiveRecord::Base.connection
      end

      def clear!
        @mutex.synchronize do
          @pools.each_value do |pool|
            pool.disconnect! rescue nil # rubocop:disable Style/RescueModifier
          end
          @pools.clear
        end
      end

      private

      def establish_pool(spec_name)
        db_config = resolve_config(spec_name)
        return ActiveRecord::Base.connection_pool unless db_config

        base_class = connection_class_for(spec_name)
        base_class.establish_connection(db_config)
        base_class.connection_pool
      end

      def connection_class_for(spec_name)
        class_name = "MysqlGenius#{spec_name.to_s.split("_").map(&:capitalize).join}Connection"
        if MysqlGenius.const_defined?(class_name, false)
          MysqlGenius.const_get(class_name, false)
        else
          klass = Class.new(ActiveRecord::Base) { self.abstract_class = true }
          MysqlGenius.const_set(class_name, klass)
          klass
        end
      end

      def resolve_config(spec_name)
        configs = ActiveRecord::Base.configurations
        if configs.respond_to?(:configs_for)
          resolve_config_modern(spec_name, configs)
        elsif configs.is_a?(Hash)
          resolve_config_legacy(spec_name, configs)
        end
      end

      def resolve_config_modern(spec_name, configs)
        db_config = configs.configs_for(env_name: Rails.env).find do |c|
          name = c.respond_to?(:spec_name) ? c.spec_name : c.name
          name.to_s == spec_name.to_s
        end
        return db_config.respond_to?(:configuration_hash) ? db_config.configuration_hash : db_config.config if db_config

        configs.configs_for(env_name: spec_name.to_s).first&.then do |c|
          c.respond_to?(:configuration_hash) ? c.configuration_hash : c.config
        end
      end

      def resolve_config_legacy(spec_name, configs)
        env_config = configs[Rails.env]
        if env_config.is_a?(Hash) && !env_config.key?("adapter")
          env_config[spec_name.to_s]
        end || configs[spec_name.to_s]
      end
    end
  end
end
