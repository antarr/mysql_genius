# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::IndexDefinition) do
  subject(:index) do
    described_class.new(
      name: "index_users_on_email",
      columns: ["email"],
      unique: true,
    )
  end

  it "exposes every attribute" do
    expect(index.name).to(eq("index_users_on_email"))
    expect(index.columns).to(eq(["email"]))
    expect(index.unique).to(eq(true))
  end

  it "aliases #unique? as a predicate" do
    expect(index.unique?).to(be(true))
    non_unique = described_class.new(name: "idx", columns: ["col"], unique: false)
    expect(non_unique.unique?).to(be(false))
  end

  it "freezes columns after construction" do
    expect(index.columns).to(be_frozen)
  end
end
