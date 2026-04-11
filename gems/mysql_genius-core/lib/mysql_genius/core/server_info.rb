# frozen_string_literal: true

module MysqlGenius
  module Core
    # Identifies the database vendor and version. Adapters construct one
    # from the server's VERSION() output.
    class ServerInfo
      attr_reader :vendor, :version

      # vendor must be :mysql or :mariadb
      def initialize(vendor:, version:)
        @vendor = vendor
        @version = version
        freeze
      end

      def self.parse(version_string)
        vendor = version_string.to_s.downcase.include?("mariadb") ? :mariadb : :mysql
        new(vendor: vendor, version: version_string)
      end

      def mariadb?
        @vendor == :mariadb
      end

      def mysql?
        @vendor == :mysql
      end
    end
  end
end
