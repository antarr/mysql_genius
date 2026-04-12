# frozen_string_literal: true

require "yaml"
require "mysql_genius/desktop/config/mysql_config"
require "mysql_genius/desktop/active_session"

module MysqlGenius
  module Desktop
    class ProfileManager
      class ProfileNotFoundError < StandardError; end
      class DuplicateProfileError < StandardError; end
      class ActiveProfileError < StandardError; end

      def initialize(source_path)
        @source_path = source_path
      end

      def list
        data = read_raw
        (data["profiles"] || []).map { |p| { name: p["name"], mysql: p["mysql"] } }
      end

      def add(name:, mysql:)
        data = read_raw
        profiles = data["profiles"] || []
        raise DuplicateProfileError, "Profile '#{name}' already exists" if profiles.any? { |p| p["name"] == name }

        profiles << { "name" => name, "mysql" => stringify_keys(mysql) }
        data["profiles"] = profiles
        write_raw(data)
      end

      def update(name:, mysql:)
        data = read_raw
        profiles = data["profiles"] || []
        profile = profiles.find { |p| p["name"] == name }
        raise ProfileNotFoundError, "Profile '#{name}' not found" unless profile

        profile["mysql"] = stringify_keys(mysql)
        write_raw(data)
      end

      def delete(name:, current_profile:)
        raise ActiveProfileError, "Cannot delete the active profile '#{name}'" if name == current_profile

        data = read_raw
        profiles = data["profiles"] || []
        raise ProfileNotFoundError, "Profile '#{name}' not found" unless profiles.any? { |p| p["name"] == name }

        data["profiles"] = profiles.reject { |p| p["name"] == name }
        write_raw(data)
      end

      def test_connection(mysql:)
        mysql_config = Config::MysqlConfig.from_hash(mysql)
        switch_config = build_minimal_config(mysql_config)
        adapter = ActiveSession.open_adapter_for(switch_config)
        result = adapter.exec_query("SELECT VERSION()")
        version = result.rows.first&.first
        adapter.close
        { success: true, version: version }
      rescue StandardError => e
        { success: false, error: e.message }
      end

      private

      def read_raw
        raw = File.read(@source_path)
        YAML.safe_load(raw, permitted_classes: [], aliases: false) || {}
      end

      def write_raw(data)
        data["version"] = 2
        File.write(@source_path, YAML.dump(data))
      end

      def stringify_keys(hash)
        hash.transform_keys(&:to_s)
      end

      def build_minimal_config(mysql_config)
        Config.allocate.tap do |c|
          c.instance_variable_set(:@profiles, [Config::ProfileConfig.new(name: "_test", mysql: mysql_config)])
          c.instance_variable_set(:@default_profile, "_test")
          c.instance_variable_set(:@query, Config::QueryConfig.from_hash({}))
        end
      end
    end
  end
end
