# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::ColumnDefinition) do
  subject(:column) do
    described_class.new(
      name: "email",
      type: :string,
      sql_type: "varchar(255)",
      null: false,
      default: nil,
      primary_key: false,
    )
  end

  it "exposes every attribute" do
    expect(column.name).to(eq("email"))
    expect(column.type).to(eq(:string))
    expect(column.sql_type).to(eq("varchar(255)"))
    expect(column.null).to(eq(false))
    expect(column.default).to(be_nil)
    expect(column.primary_key).to(eq(false))
  end

  it "is frozen after construction" do
    expect(column).to(be_frozen)
  end

  it "aliases #null? as a predicate" do
    expect(column.null?).to(be(false))
    nullable = described_class.new(name: "n", type: :integer, sql_type: "int", null: true, default: nil, primary_key: false)
    expect(nullable.null?).to(be(true))
  end

  it "aliases #primary_key? as a predicate" do
    expect(column.primary_key?).to(be(false))
    pk = described_class.new(name: "id", type: :integer, sql_type: "bigint", null: false, default: nil, primary_key: true)
    expect(pk.primary_key?).to(be(true))
  end
end
