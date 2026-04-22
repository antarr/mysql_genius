# frozen_string_literal: true

# Test helper: builds a stubbed ActiveRecord::Base.connection double with
# configurable return values. Each request spec calls `stub_connection(...)`
# in a `before` block, passing whichever table/column/query responses the
# action under test needs.
#
# Usage:
#
#   before do
#     stub_connection(
#       tables: %w[users orders],
#       columns_for: {
#         "users" => [
#           fake_column(name: "id", sql_type: "bigint", type: :integer),
#           fake_column(name: "email", sql_type: "varchar(255)", type: :string),
#           fake_column(name: "password_hash", sql_type: "varchar(255)", type: :string),
#         ],
#       },
#     )
#   end
module FakeConnectionHelper
  # Returns a double that responds to the subset of ActiveRecord::Base.connection
  # methods the engine's concerns use.
  #
  # Pass `allow_unmatched_exec_query: true` to silently return an empty result
  # for SQL strings that don't match any key in the `exec_query:` hash.
  # By default an unmatched query raises, surfacing test bugs early.
  def stub_connection(
    tables: [],
    columns_for: {},
    exec_query: {},
    select_value: nil,
    current_database: "test_db",
    primary_key: "id",
    indexes: [],
    allow_unmatched_exec_query: false
  )
    connection = double("AR::Base.connection")

    columns_for.each do |table, cols|
      allow(connection).to(receive(:columns).with(table).and_return(cols))
    end

    matchers = exec_query.to_a
    empty_result = fake_result
    allow(connection).to(receive(:exec_query)) do |sql|
      match = matchers.find { |pat, _| pat.is_a?(Regexp) ? sql =~ pat : sql == pat }
      if match
        match[1]
      elsif allow_unmatched_exec_query
        empty_result
      else
        raise "FakeConnectionHelper#stub_connection: unstubbed exec_query: #{sql.inspect}"
      end
    end

    allow(connection).to(receive(:select_value).and_return(select_value)) if select_value
    allow(connection).to(receive(:quote) { |v| "'#{v}'" })
    allow(connection).to(receive(:quote_table_name) { |n| "`#{n}`" })
    allow(connection).to(receive_messages(tables: tables, current_database: current_database, indexes: indexes, primary_key: primary_key))

    allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))

    # Stub MysqlGenius.database_registry so the BaseController before_action
    # resolves to a single "primary" database whose ar_connection returns the
    # same stubbed connection. This lets request specs hit /mysql_genius/primary/...
    # without needing a real AR configuration.
    stub_database_registry(connection)

    connection
  end

  # Builds a Database double whose ar_connection + connection both point at
  # the stubbed AR connection, and registers it in a DatabaseRegistry double
  # keyed by "primary". The registry returns the database ONLY for its own
  # key — other keys return nil, simulating real production behavior where
  # unknown database_ids trigger either a legacy redirect or a 404.
  def stub_database_registry(connection, key: "primary")
    database = double(
      "MysqlGenius::Database",
      key: key,
      label: key,
      reader?: false,
      adapter_name: "mysql2",
      ar_connection: connection,
      connection: MysqlGenius::Core::Connection::ActiveRecordAdapter.new(connection),
    )
    registry = double("MysqlGenius::DatabaseRegistry",
      keys: [key],
      default_key: key,
      empty?: false,
      size: 1)
    allow(registry).to(receive(:[])) { |k| k.to_s == key ? database : nil }
    allow(registry).to(receive(:fetch)) do |k|
      k.to_s == key ? database : raise(KeyError, "Unknown mysql_genius database: #{k.inspect}")
    end
    allow(registry).to(receive(:each).and_yield(database))
    allow(MysqlGenius).to(receive(:database_registry).and_return(registry))
    registry
  end

  # Builds an ActiveRecord column double with the fields the controllers read.
  def fake_column(name:, sql_type: "varchar(255)", type: :string, null: true, default: nil)
    double(
      "ActiveRecord::ConnectionAdapters::Column",
      name: name,
      sql_type: sql_type,
      type: type,
      null: null,
      default: default,
    )
  end

  # Builds an ActiveRecord::Result double with the three methods the engine
  # actions call on it (`columns`, `rows`, `to_a`). Use for stubbing the
  # return value of `ActiveRecord::Base.connection.exec_query(...)` either
  # via `stub_connection(exec_query: { /regex/ => fake_result(rows: [...]) })`
  # or via a direct `allow(...).to receive(:exec_query).and_return(fake_result)`.
  def fake_result(columns: [], rows: [], to_a: nil)
    instance_double(
      "ActiveRecord::Result",
      columns: columns,
      rows: rows,
      to_a: to_a.nil? ? rows.map { |row| columns.zip(row).to_h } : to_a,
    )
  end
end
