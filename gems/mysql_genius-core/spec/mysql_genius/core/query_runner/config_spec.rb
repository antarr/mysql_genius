# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::QueryRunner::Config) do
  it "exposes blocked_tables, masked_column_patterns, query_timeout_ms" do
    config = described_class.new(
      blocked_tables: ["sessions"],
      masked_column_patterns: ["password", "token"],
      query_timeout_ms: 30_000,
    )

    expect(config.blocked_tables).to(eq(["sessions"]))
    expect(config.masked_column_patterns).to(eq(["password", "token"]))
    expect(config.query_timeout_ms).to(eq(30_000))
  end

  it "is frozen after construction" do
    config = described_class.new(
      blocked_tables: [],
      masked_column_patterns: [],
      query_timeout_ms: 30_000,
    )

    expect(config).to(be_frozen)
  end
end
