# frozen_string_literal: true

module MysqlGenius
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates a MysqlGenius initializer and mounts the engine in routes."

      def copy_initializer
        template("initializer.rb", "config/initializers/mysql_genius.rb")
      end

      def copy_yaml_config
        template("mysql_genius.yml", "config/mysql_genius.yml")
      end

      def mount_engine
        route('mount MysqlGenius::Engine, at: "/mysql_genius"')
      end
    end
  end
end
