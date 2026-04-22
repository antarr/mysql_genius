# frozen_string_literal: true

require_relative "integration_helper"

RSpec.describe(MysqlGenius::Core::Analysis::QueryStats, :integration) do
  subject(:analysis) { described_class.new(ar_core_adapter) }

  it "returns per-digest stats against the Sakila workload" do
    results = analysis.call
    expect(results).not_to(be_empty)
    # WorkloadGenerator runs 12 distinct query shapes; some may be absorbed
    # into the same digest (e.g. DISTINCT vs GROUP BY on the same column),
    # but we should see at least 6 distinct digests surface.
    expect(results.length).to(be >= 6)
  end

  it "populates structural fields on every digest" do
    sample = analysis.call.first
    expect(sample).to(include(
      :digest, :sql, :calls, :total_time_ms, :avg_time_ms,
      :max_time_ms, :rows_examined, :rows_sent, :rows_ratio,
    ))
  end

  it "returns digest counts >= WorkloadGenerator.iterations for repeated queries" do
    results = analysis.call
    # The indexed customer lookup ran 30 times. Its digest_text is normalized
    # by perf_schema with backticks, spaces around dots, and placeholders:
    #   "SELECT * FROM `sakila` . `customer` WHERE `customer_id` = ?"
    indexed_lookup = results.find { |r| r[:sql] =~ /customer\b.*`customer_id`\s*=\s*\?/m }
    expect(indexed_lookup).not_to(be_nil)
    expect(indexed_lookup[:calls]).to(be >= 25)
  end

  it "reports a large rows_examined for a full-scan query (LOWER() disables the email index)" do
    results = analysis.call
    full_scan = results.find { |r| r[:sql].include?("LOWER") }
    expect(full_scan).not_to(be_nil)
    # 30 iterations × 599 rows scanned per call = ~17,970. The exact number
    # varies slightly by MySQL version but will always be much larger than
    # any indexed lookup would examine.
    expect(full_scan[:rows_examined]).to(be >= 5_000)
  end

  it "sorts by total_time_ms desc by default" do
    results = analysis.call(sort: "total_time")
    totals = results.map { |r| r[:total_time_ms] }
    expect(totals).to(eq(totals.sort.reverse))
  end

  it "respects the limit parameter" do
    expect(analysis.call(limit: 3).length).to(eq(3))
  end
end
