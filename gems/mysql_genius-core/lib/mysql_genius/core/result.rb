# frozen_string_literal: true

module MysqlGenius
  module Core
    # Immutable value object representing the result of a query.
    # Adapters translate their native result types into this shape.
    class Result
      include Enumerable

      attr_reader :columns, :rows

      def initialize(columns:, rows:)
        @columns = columns.freeze
        @rows = rows.freeze
        freeze
      end

      def each(&block)
        return @rows.each unless block

        @rows.each(&block)
      end

      def to_a
        @rows.dup
      end

      def count
        @rows.length
      end

      def empty?
        @rows.empty?
      end

      # Returns rows as an array of hashes keyed by column name. Mirrors
      # ActiveRecord::Result#to_a's hashification behavior.
      def to_hashes
        @rows.map { |row| @columns.zip(row).to_h }
      end
    end
  end
end
