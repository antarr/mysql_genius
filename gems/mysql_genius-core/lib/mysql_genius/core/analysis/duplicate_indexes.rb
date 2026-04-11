# frozen_string_literal: true

require "set"

module MysqlGenius
  module Core
    module Analysis
      # Detects indexes whose columns are a left-prefix of another index on
      # the same table (meaning the shorter index is redundant — the longer
      # one can satisfy the same queries). Preserves unique indexes: a unique
      # index is never flagged as redundant when only covered by a non-unique
      # index.
      #
      # Takes a Core::Connection plus a list of tables to exclude from the
      # scan. Returns an array of hashes describing each duplicate pair, with
      # the (duplicate_index, covered_by_index) pair deduplicated across
      # symmetrical relationships.
      class DuplicateIndexes
        def initialize(connection, blocked_tables:)
          @connection = connection
          @blocked_tables = blocked_tables
        end

        def call
          duplicates = []

          queryable_tables.each do |table|
            indexes = @connection.indexes_for(table)
            next if indexes.size < 2

            indexes.each do |idx|
              indexes.each do |other|
                next if idx.name == other.name
                next unless covers?(other, idx)

                duplicates << {
                  table: table,
                  duplicate_index: idx.name,
                  duplicate_columns: idx.columns,
                  covered_by_index: other.name,
                  covered_by_columns: other.columns,
                  unique: idx.unique,
                }
              end
            end
          end

          deduplicate(duplicates)
        end

        private

        def queryable_tables
          @connection.tables - @blocked_tables
        end

        # True if `other` covers `idx` (idx's columns are a left-prefix of
        # other's columns). Protects unique indexes from being covered by
        # non-unique ones.
        def covers?(other, idx)
          return false if idx.columns.size > other.columns.size
          return false unless other.columns.first(idx.columns.size) == idx.columns
          return false if idx.unique && !other.unique

          true
        end

        def deduplicate(duplicates)
          seen = Set.new
          duplicates.reject do |d|
            key = [d[:table], [d[:duplicate_index], d[:covered_by_index]].sort].flatten.join(":")
            if seen.include?(key)
              true
            else
              seen.add(key)
              false
            end
          end
        end
      end
    end
  end
end
