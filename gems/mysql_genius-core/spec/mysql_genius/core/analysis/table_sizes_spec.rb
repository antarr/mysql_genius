# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::TableSizes) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  subject(:analysis) { described_class.new(connection) }

  before do
    connection.stub_current_database("app_test")
  end

  describe "#call" do
    it "returns an empty array when information_schema.tables has no BASE TABLE rows" do
      connection.stub_query(
        /FROM information_schema\.tables/i,
        columns: %w[table_name engine table_collation auto_increment update_time data_mb index_mb total_mb fragmented_mb],
        rows: [],
      )

      expect(analysis.call).to(eq([]))
    end

    it "returns a hash per table with size metadata and a row count" do
      connection.stub_query(
        /FROM information_schema\.tables/i,
        columns: %w[table_name engine table_collation auto_increment update_time data_mb index_mb total_mb fragmented_mb],
        rows: [
          ["users", "InnoDB", "utf8mb4_0900_ai_ci", 42, "2026-04-10 12:00:00", 1.50, 0.50, 2.00, 0.00],
          ["posts", "InnoDB", "utf8mb4_0900_ai_ci", 100, "2026-04-10 12:05:00", 5.00, 2.00, 7.00, 0.10],
        ],
      )
      connection.stub_query(/SELECT COUNT.*FROM `users`/, columns: ["COUNT(*)"], rows: [[41]])
      connection.stub_query(/SELECT COUNT.*FROM `posts`/, columns: ["COUNT(*)"], rows: [[99]])

      result = analysis.call

      expect(result.length).to(eq(2))
      expect(result[0]).to(include(
        table: "users",
        rows: 41,
        engine: "InnoDB",
        collation: "utf8mb4_0900_ai_ci",
        auto_increment: 42,
        data_mb: 1.5,
        index_mb: 0.5,
        total_mb: 2.0,
        fragmented_mb: 0.0,
        needs_optimize: false,
      ))
      expect(result[1]).to(include(
        table: "posts",
        rows: 99,
        total_mb: 7.0,
        fragmented_mb: 0.1,
        needs_optimize: false,
      ))
    end

    it "sets needs_optimize=true when fragmented_mb exceeds 10% of total_mb" do
      connection.stub_query(
        /FROM information_schema\.tables/i,
        columns: %w[table_name engine table_collation auto_increment update_time data_mb index_mb total_mb fragmented_mb],
        rows: [["users", "InnoDB", "utf8mb4", 1, nil, 10.0, 5.0, 15.0, 2.0]],
      )
      connection.stub_query(/SELECT COUNT.*FROM `users`/, columns: ["COUNT(*)"], rows: [[100]])

      expect(analysis.call.first[:needs_optimize]).to(be(true))
    end

    it "falls back to nil row count when the COUNT(*) query raises" do
      connection.stub_query(
        /FROM information_schema\.tables/i,
        columns: %w[table_name engine table_collation auto_increment update_time data_mb index_mb total_mb fragmented_mb],
        rows: [["broken", "InnoDB", "utf8mb4", 1, nil, 1.0, 0.0, 1.0, 0.0]],
      )
      connection.stub_query(/SELECT COUNT.*FROM `broken`/, raises: StandardError.new("no such table"))

      result = analysis.call
      expect(result.first[:rows]).to(be_nil)
    end

    it "handles uppercase column names (MariaDB compatibility)" do
      connection.stub_query(
        /FROM information_schema\.tables/i,
        columns: %w[TABLE_NAME ENGINE TABLE_COLLATION AUTO_INCREMENT UPDATE_TIME data_mb index_mb total_mb fragmented_mb],
        rows: [["users", "InnoDB", "utf8mb4", 1, nil, 1.0, 0.0, 1.0, 0.0]],
      )
      connection.stub_query(/SELECT COUNT.*FROM `users`/, columns: ["COUNT(*)"], rows: [[1]])

      result = analysis.call
      expect(result.first[:table]).to(eq("users"))
      expect(result.first[:engine]).to(eq("InnoDB"))
      expect(result.first[:collation]).to(eq("utf8mb4"))
    end
  end
end
