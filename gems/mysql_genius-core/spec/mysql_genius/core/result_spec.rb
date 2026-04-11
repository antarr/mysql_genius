# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Result) do
  subject(:result) do
    described_class.new(
      columns: ["id", "name"],
      rows: [[1, "Alice"], [2, "Bob"]],
    )
  end

  it "exposes columns" do
    expect(result.columns).to(eq(["id", "name"]))
  end

  it "exposes rows" do
    expect(result.rows).to(eq([[1, "Alice"], [2, "Bob"]]))
  end

  it "is empty when rows is empty" do
    empty = described_class.new(columns: ["id"], rows: [])
    expect(empty.empty?).to(be(true))
    expect(empty.count).to(eq(0))
  end

  it "is not empty when rows has data" do
    expect(result.empty?).to(be(false))
  end

  it "returns row count" do
    expect(result.count).to(eq(2))
  end

  it "iterates rows with #each" do
    rows = []
    result.each { |row| rows << row }
    expect(rows).to(eq([[1, "Alice"], [2, "Bob"]]))
  end

  it "returns an Enumerator when #each is called without a block" do
    expect(result.each).to(be_a(Enumerator))
    expect(result.each.to_a).to(eq([[1, "Alice"], [2, "Bob"]]))
  end

  it "converts to array with #to_a" do
    expect(result.to_a).to(eq([[1, "Alice"], [2, "Bob"]]))
  end

  it "returns an array of hashes with #to_hashes" do
    expect(result.to_hashes).to(eq([
      { "id" => 1, "name" => "Alice" },
      { "id" => 2, "name" => "Bob" },
    ]))
  end

  it "freezes columns and rows after construction" do
    expect(result.columns).to(be_frozen)
    expect(result.rows).to(be_frozen)
  end
end
