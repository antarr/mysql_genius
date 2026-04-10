# frozen_string_literal: true

module MysqlGenius
  class DatabaseConfig
    OVERRIDABLE_SETTINGS = [
      :blocked_tables,
      :masked_column_patterns,
      :featured_tables,
      :default_columns,
      :max_row_limit,
      :default_row_limit,
      :query_timeout_ms,
    ].freeze

    attr_reader :key
    attr_accessor :label, :connection_spec

    OVERRIDABLE_SETTINGS.each do |setting|
      define_method(setting) do
        value = instance_variable_get(:"@#{setting}")
        value.nil? ? @global_config.public_send(setting) : value
      end

      define_method(:"#{setting}=") do |value|
        instance_variable_set(:"@#{setting}", value)
      end
    end

    def initialize(key, global_config)
      @key = key.to_sym
      @global_config = global_config
      @label = @key.to_s.tr("_", " ").capitalize
    end

    def load_from_yaml(hash)
      hash.each do |k, v|
        setter = :"#{k}="
        public_send(setter, v) if respond_to?(setter)
      end
    end
  end
end
