# frozen_string_literal: true

module MysqlGenius
  module Core
    # Index metadata as returned by Core::Connection#indexes_for. Mirrors
    # the subset of ActiveRecord::ConnectionAdapters::IndexDefinition that
    # the analyses rely on.
    class IndexDefinition
      attr_reader :name, :columns, :unique

      def initialize(name:, columns:, unique:)
        @name = name
        @columns = columns.freeze
        @unique = unique
        freeze
      end

      def unique?
        @unique
      end
    end
  end
end
