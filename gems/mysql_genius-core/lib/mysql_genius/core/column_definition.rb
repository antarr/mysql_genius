# frozen_string_literal: true

module MysqlGenius
  module Core
    # Column metadata as returned by Core::Connection#columns_for. Mirrors
    # the subset of ActiveRecord::ConnectionAdapters::Column that the
    # analyses and AI services rely on.
    class ColumnDefinition
      attr_reader :name, :type, :sql_type, :null, :default, :primary_key

      def initialize(name:, type:, sql_type:, null:, default:, primary_key:)
        @name = name
        @type = type
        @sql_type = sql_type
        @null = null
        @default = default
        @primary_key = primary_key
        freeze
      end

      def null?
        @null
      end

      def primary_key?
        @primary_key
      end
    end
  end
end
