# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::ExecutionResult) do
  subject(:result) do
    described_class.new(
      columns: ["id", "name"],
      rows: [[1, "Alice"], [2, "Bob"]],
      execution_time_ms: 12.5,
      truncated: false,
    )
  end

  it "exposes columns, rows, row_count, execution_time_ms, truncated" do
    expect(result.columns).to(eq(["id", "name"]))
    expect(result.rows).to(eq([[1, "Alice"], [2, "Bob"]]))
    expect(result.row_count).to(eq(2))
    expect(result.execution_time_ms).to(eq(12.5))
    expect(result.truncated).to(be(false))
  end

  it "computes row_count from rows length" do
    empty = described_class.new(columns: ["x"], rows: [], execution_time_ms: 0.1, truncated: false)
    expect(empty.row_count).to(eq(0))
  end

  it "is frozen after construction" do
    expect(result).to(be_frozen)
  end

  it "freezes its columns and rows arrays" do
    expect(result.columns).to(be_frozen)
    expect(result.rows).to(be_frozen)
  end
end
