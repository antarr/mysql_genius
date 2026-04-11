# frozen_string_literal: true

module MysqlGenius
  module Core
    module Connection
      # In-memory fake connection used by core specs. Supports stubbing
      # queries by regex and returning canned Core::Result values, plus
      # stubbing metadata methods. See spec/mysql_genius/core/connection/
      # fake_adapter_spec.rb for the full surface.
      class FakeAdapter
        class NoStubError < StandardError; end

        def initialize
          @stubs = []
          @tables = []
          @columns_for = {}
          @indexes_for = {}
          @primary_keys = {}
          @server_version = "8.0.35"
          @current_database = "test_db"
        end

        # ----- stub registration -----

        def stub_query(pattern, columns: [], rows: [], raises: nil)
          @stubs << { pattern: pattern, columns: columns, rows: rows, raises: raises }
        end

        def stub_server_version(version)
          @server_version = version
        end

        def stub_current_database(name)
          @current_database = name
        end

        def stub_tables(list)
          @tables = list
        end

        def stub_columns_for(table, columns)
          @columns_for[table] = columns
        end

        def stub_indexes_for(table, indexes)
          @indexes_for[table] = indexes
        end

        def stub_primary_key(table, name)
          @primary_keys[table] = name
        end

        # ----- contract -----

        def exec_query(sql, binds: [])
          _ = binds
          stub = @stubs.find { |s| s[:pattern] =~ sql }
          raise NoStubError, "No stub matched SQL: #{sql}" unless stub
          raise stub[:raises] if stub[:raises]

          Result.new(columns: stub[:columns], rows: stub[:rows])
        end

        def select_value(sql)
          result = exec_query(sql)
          return nil if result.empty?

          result.rows.first&.first
        end

        def server_version
          ServerInfo.parse(@server_version)
        end

        def current_database
          @current_database
        end

        def quote(value)
          case value
          when nil then "NULL"
          when Integer, Float then value.to_s
          when String then "'#{value.gsub("'", "''")}'"
          else "'#{value.to_s.gsub("'", "''")}'"
          end
        end

        def quote_table_name(name)
          "`#{name}`"
        end

        def tables
          @tables
        end

        def columns_for(table)
          @columns_for.fetch(table, [])
        end

        def indexes_for(table)
          @indexes_for.fetch(table, [])
        end

        def primary_key(table)
          @primary_keys[table]
        end

        def close
          nil
        end
      end
    end
  end
end
