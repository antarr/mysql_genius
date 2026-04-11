# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::UnusedIndexes) do
  subject(:analysis) { described_class.new(connection) }

  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }

  before do
    connection.stub_current_database("app_test")
  end

  describe "#call" do
    let(:columns) { ["table_schema", "table_name", "index_name", "reads", "writes", "table_rows"] }

    it "returns an empty array when performance_schema has no unused-index rows" do
      connection.stub_query(/performance_schema\.table_io_waits_summary_by_index_usage/, columns: columns, rows: [])

      expect(analysis.call).to(eq([]))
    end

    it "returns hashes with drop_sql for each unused index" do
      connection.stub_query(
        /performance_schema\.table_io_waits_summary_by_index_usage/,
        columns: columns,
        rows: [
          ["app_test", "users", "index_users_on_legacy_field", 0, 500, 10_000],
          ["app_test", "posts", "idx_abandoned", 0, 120, 2_500],
        ],
      )

      result = analysis.call

      expect(result.length).to(eq(2))
      expect(result[0]).to(include(
        table: "users",
        index_name: "index_users_on_legacy_field",
        reads: 0,
        writes: 500,
        table_rows: 10_000,
        drop_sql: "ALTER TABLE `users` DROP INDEX `index_users_on_legacy_field`;",
      ))
      expect(result[1][:table]).to(eq("posts"))
      expect(result[1][:drop_sql]).to(eq("ALTER TABLE `posts` DROP INDEX `idx_abandoned`;"))
    end

    it "handles uppercase column names" do
      connection.stub_query(
        /performance_schema/,
        columns: ["TABLE_SCHEMA", "TABLE_NAME", "INDEX_NAME", "READS", "WRITES", "TABLE_ROWS"],
        rows: [["app_test", "users", "index_users_on_email", 0, 100, 1000]],
      )

      expect(analysis.call.first[:table]).to(eq("users"))
      expect(analysis.call.first[:index_name]).to(eq("index_users_on_email"))
    end

    it "zero-fills missing numeric columns" do
      connection.stub_query(
        /performance_schema/,
        columns: columns,
        rows: [["app_test", "users", "index_users_on_email", nil, nil, nil]],
      )

      result = analysis.call.first
      expect(result[:reads]).to(eq(0))
      expect(result[:writes]).to(eq(0))
      expect(result[:table_rows]).to(eq(0))
    end
  end
end
