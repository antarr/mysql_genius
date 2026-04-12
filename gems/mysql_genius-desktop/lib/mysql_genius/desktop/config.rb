# frozen_string_literal: true

require "yaml"
require "mysql_genius/desktop/config/mysql_config"
require "mysql_genius/desktop/config/server_config"
require "mysql_genius/desktop/config/security_config"
require "mysql_genius/desktop/config/query_config"
require "mysql_genius/desktop/config/ai_config"
require "mysql_genius/desktop/config/profile_config"

module MysqlGenius
  module Desktop
    # YAML-driven configuration loader for the sidecar. Handles path
    # resolution, ${ENV_VAR} interpolation, version validation, and
    # delegation to the five sub-config structs.
    #
    # Path resolution order:
    #   1. Explicit path argument (from --config)
    #   2. $MYSQL_GENIUS_CONFIG environment variable
    #   3. Each entry in LOOKUP_PATHS, in order
    class Config
      LOOKUP_PATHS = [
        "./mysql_genius.yml",
        File.join(Dir.home, ".config", "mysql_genius", "config.yml"),
        File.join(Dir.home, ".mysql_genius.yml"),
      ].freeze

      SUPPORTED_VERSIONS = [1, 2].freeze

      attr_reader :profiles, :default_profile, :server, :security, :query, :ai, :source_path

      class << self
        def load(path: nil, override_port: nil, override_bind: nil)
          resolved = resolve_path(path)
          raise InvalidConfigError, "no config file found (tried: #{[path, ENV["MYSQL_GENIUS_CONFIG"], *LOOKUP_PATHS].compact.uniq.join(", ")}). Pass --config PATH." unless resolved

          raw = File.read(resolved)
          interpolated = interpolate_env(raw, resolved)
          data = YAML.safe_load(interpolated, permitted_classes: [], aliases: false) || {}

          new(data, source_path: resolved, override_port: override_port, override_bind: override_bind)
        end

        private

        def resolve_path(explicit)
          return explicit if explicit && File.exist?(explicit)
          return if explicit && !File.exist?(explicit)

          env_path = ENV["MYSQL_GENIUS_CONFIG"]
          return env_path if env_path && File.exist?(env_path)

          LOOKUP_PATHS.find { |p| File.exist?(p) }
        end

        def interpolate_env(raw, source_path)
          raw.gsub(/\$\{(\w+)\}/) do
            var = Regexp.last_match(1)
            value = ENV[var]
            raise InvalidConfigError, "config #{source_path} references ${#{var}} but #{var} is not set in the environment" if value.nil?

            value
          end
        end
      end

      def initialize(data, source_path:, override_port: nil, override_bind: nil)
        @source_path = source_path
        validate_version!(data)

        version = data["version"]
        if version == 1
          build_from_v1(data)
        else
          build_from_v2(data)
        end

        @server   = ServerConfig.from_hash(data["server"] || {}, override_port: override_port, override_bind: override_bind)
        @security = SecurityConfig.from_hash(data["security"] || {})
        @query    = QueryConfig.from_hash(data["query"] || {})
        @ai       = AiConfig.from_hash(data["ai"] || {})
      end

      def profile_by_name(name)
        @profiles.find { |p| p.name == name }
      end

      def active_mysql_config
        profile_by_name(@default_profile)&.mysql
      end

      # Backward-compat alias — existing code calls config.mysql.host etc.
      def mysql
        active_mysql_config
      end

      private

      def build_from_v1(data)
        mysql_section = data["mysql"]
        raise InvalidConfigError, "config #{@source_path}: mysql: section is required" if mysql_section.nil?

        @profiles = [ProfileConfig.new(name: "default", mysql: MysqlConfig.from_hash(mysql_section))]
        @default_profile = "default"
      end

      def build_from_v2(data)
        profiles_data = data["profiles"]
        raise InvalidConfigError, "config #{@source_path}: profiles: section is required for version 2" if profiles_data.nil? || !profiles_data.is_a?(Array) || profiles_data.empty?

        @profiles = profiles_data.map { |p| ProfileConfig.from_hash(p) }
        @default_profile = data["default_profile"] || @profiles.first.name

        unless profile_by_name(@default_profile)
          raise InvalidConfigError, "config #{@source_path}: default_profile '#{@default_profile}' does not match any profile name"
        end
      end

      def validate_version!(data)
        raise InvalidConfigError, "config #{@source_path}: missing top-level version: key" unless data.key?("version")

        version = data["version"]
        return if SUPPORTED_VERSIONS.include?(version)

        raise InvalidConfigError, "config #{@source_path}: unsupported version #{version} (expected #{SUPPORTED_VERSIONS.join(" or ")})"
      end
    end
  end
end
