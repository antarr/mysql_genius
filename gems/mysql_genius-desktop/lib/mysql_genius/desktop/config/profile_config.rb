# frozen_string_literal: true

module MysqlGenius
  module Desktop
    class Config
      class ProfileConfig < Struct.new(:name, :mysql, keyword_init: true)
        class << self
          def from_hash(hash)
            hash = hash.transform_keys(&:to_s)
            name = hash["name"]
            raise Config::InvalidConfigError, "profile: name is required" if name.nil? || name.to_s.empty?

            mysql_section = hash["mysql"]
            raise Config::InvalidConfigError, "profile '#{name}': mysql section is required" if mysql_section.nil?

            new(name: name, mysql: MysqlConfig.from_hash(mysql_section))
          end
        end
      end
    end
  end
end
