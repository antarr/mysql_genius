# frozen_string_literal: true

require_relative "integration_helper"

RSpec.describe(MysqlGenius::Core::Analysis::SlowQueries, :integration) do
  subject(:analysis) { described_class.new(ar_core_adapter, threshold_ms: 0, limit: 100) }

  it "reports performance_schema as available on a stock MySQL server" do
    expect(analysis.availability).to(be_available)
  end

  it "returns events from the Sakila workload when the threshold is 0" do
    result = analysis.call
    expect(result).to(be_available)
    expect(result.queries).not_to(be_empty)
  end

  it "each returned event has source=performance_schema and a non-empty sql" do
    q = analysis.call.queries.first
    expect(q[:source]).to(eq("performance_schema"))
    expect(q[:sql]).not_to(be_empty)
    expect(q[:digest]).not_to(be_empty)
  end

  it "filters out the noise patterns (no EXPLAIN / SET / information_schema in results)" do
    # Run some noise queries that SHOULD NOT appear in slow_queries output.
    conn = ActiveRecord::Base.connection
    conn.execute("EXPLAIN SELECT * FROM sakila.film")
    conn.execute("SHOW TABLES")
    conn.execute("SELECT * FROM information_schema.TABLES LIMIT 1")

    sqls = analysis.call.queries.map { |q| q[:sql] }
    expect(sqls.any? { |s| s.match?(/^EXPLAIN/i) }).to(be(false))
    expect(sqls.any? { |s| s.match?(/^SHOW/i) }).to(be(false))
    expect(sqls.any? { |s| s.match?(/information_schema\./i) }).to(be(false))
  end

  it "returns an empty queries array (not an error) when threshold is absurdly high" do
    result = described_class.new(ar_core_adapter, threshold_ms: 10_000_000).call
    expect(result).to(be_available)
    expect(result.queries).to(eq([]))
  end
end
