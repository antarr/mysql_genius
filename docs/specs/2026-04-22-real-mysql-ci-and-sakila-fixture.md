# Real-MySQL CI + Sakila Integration Fixture

**Status:** Draft
**Date:** 2026-04-22
**Target version:** 0.9.0-pre (ships before multi-DB and digest-history specs)

## Motivation

mysql_genius specs today use `FakeConnectionHelper` — a pure `double("AR::Base.connection")` with hand-stubbed `exec_query` responses. Nothing in CI ever runs against a real MySQL server. This has three concrete costs:

1. **Parser correctness is untested.** Our analysis classes parse `performance_schema` rows, `information_schema` results, and `EXPLAIN FORMAT=JSON` output. Whether those parsers actually work against real server output is unverified. The 0.8.1 hotfix for "missing DIGEST column on older MySQL versions" (commit `21971e7`) is the kind of bug stubs let through.
2. **Adapter differences are invisible.** `mysql2` and `trilogy` return slightly different types for the same columns. Specs can't catch that.
3. **Feature work coming in 0.9.x needs real MySQL.** Multi-DB support (reading from replicas, role switching), digest-history snapshots (cumulative counters across time windows), and regression detection all need real cumulative `performance_schema` state that stubs can't synthesize.

Shipping real-MySQL CI + a committed Sakila fixture *before* the 0.9.x feature work means those features can be developed with integration tests from day one, not retrofitted later.

## Goals

1. Real MySQL server in CI, matrixed across versions users actually run.
2. Small, zero-setup fixture data committed to the repo (Sakila) so `bundle exec rspec` works locally with no download step.
3. A workload generator that populates `performance_schema` with realistic digest stats, enabling end-to-end tests of the analysis features.
4. Keep fast unit tests as-is (`FakeConnectionHelper` still useful for pure-logic specs that don't need a DB).

## Non-goals

- Employees DB integration (too big for git; revisit only if Sakila's workload is insufficient).
- Percona / AWS Aurora / PlanetScale-specific CI. Standard MySQL + MariaDB is enough.
- Property-based or fuzzed workload generation. Scripted is fine for v1.

## Design

### 1. Sakila fixture — committed to git

Layout:

```
spec/fixtures/sakila/
  LICENSE              # Oracle BSD license text, verbatim
  README.md            # Provenance, version pinned, regeneration instructions
  schema.sql           # from sakila-schema.sql upstream
  data.sql.gz          # gzipped sakila-data.sql (~700KB compressed vs ~3MB raw)
```

- Total ~750KB committed. Insignificant for repo size.
- Gzipped so that PR diffs on the `data.sql` file stay renderable on github.com (1MB preview limit). `schema.sql` is small enough (~25KB) to stay uncompressed.
- `README.md` pins the upstream version (e.g. "Sakila 1.2.0 from dev.mysql.com, downloaded 2026-04-22") and provides a one-liner to regenerate.
- `LICENSE` carries the BSD text verbatim — this is the license's only redistribution requirement.

### 2. Sakila loader helper

New file: `spec/support/sakila_fixture.rb`.

```ruby
module SakilaFixture
  # Loads schema + data into the current test database.
  # Idempotent: drops and recreates the sakila schema on each call.
  # Called once per test run from a before(:suite) hook; no-ops after first load
  # unless SAKILA_RELOAD=1 is set.
  def self.load!(connection = ActiveRecord::Base.connection)
    return if loaded?(connection) && !ENV["SAKILA_RELOAD"]
    connection.execute(File.read(schema_path))
    connection.execute(Zlib::GzipReader.new(File.open(data_path_gz)).read)
  end

  def self.loaded?(conn)
    conn.exec_query("SHOW TABLES LIKE 'film'").rows.any?
  end

  def self.schema_path; "spec/fixtures/sakila/schema.sql"; end
  def self.data_path_gz; "spec/fixtures/sakila/data.sql.gz"; end
end
```

### 3. Workload generator

New file: `spec/support/workload_generator.rb`.

Purpose: run enough SQL against Sakila to populate `performance_schema.events_statements_summary_by_digest` with realistic variety — fast queries, slow queries, full scans, index hits, aggregates, joins, sorts — so integration specs have meaningful data.

```ruby
module WorkloadGenerator
  def self.run!(connection, iterations: 50)
    QUERIES.each do |sql|
      iterations.times { connection.exec_query(sql) }
    end
  end

  QUERIES = [
    # Indexed lookup
    "SELECT * FROM customer WHERE customer_id = 42",
    # Full scan
    "SELECT * FROM customer WHERE LOWER(email) LIKE '%@sakilacustomer.org'",
    # Join
    "SELECT c.first_name, r.rental_date FROM customer c JOIN rental r USING (customer_id) LIMIT 100",
    # Aggregate with GROUP BY
    "SELECT rating, COUNT(*) FROM film GROUP BY rating",
    # Sort w/o index
    "SELECT * FROM film ORDER BY length DESC LIMIT 20",
    # Subquery
    "SELECT title FROM film WHERE film_id IN (SELECT film_id FROM inventory WHERE store_id = 1)",
    # 3-way join
    "SELECT f.title, c.name FROM film f JOIN film_category fc USING (film_id) JOIN category c USING (category_id)",
    # ... ~12 queries total
  ].freeze
end
```

Called once per test run from `before(:suite)`. Iterations count makes digest counts meaningful (not `count_star=1` everywhere).

### 4. Integration spec layer

Add `spec/integration/` as a new spec directory. Specs here require `REAL_MYSQL=1` to run:

```ruby
# spec/spec_helper.rb
RSpec.configure do |config|
  config.filter_run_excluding(integration: true) unless ENV["REAL_MYSQL"]
end

# spec/integration/query_stats_integration_spec.rb
RSpec.describe "query stats against real MySQL", integration: true do
  before(:suite) do
    SakilaFixture.load!
    WorkloadGenerator.run!(ActiveRecord::Base.connection)
  end

  it "returns real digests from performance_schema"
  it "parses EXPLAIN JSON for a join query"
  it "detects unused indexes on Sakila schema"
  # ...
end
```

Unit specs (fast, stubbed) run by default. Integration specs run when `REAL_MYSQL=1` is set — which CI always does in its integration job, but local dev only when explicitly asked.

### 5. CI matrix

Split CI into two jobs:

**`test` (existing, unchanged):** unit specs against `FakeConnectionHelper`. Keeps the Ruby × Rails matrix — fast, no services needed.

**`integration` (new):** real MySQL. Smaller matrix to keep total CI time manageable:

```yaml
integration:
  runs-on: ubuntu-latest
  strategy:
    fail-fast: false
    matrix:
      include:
        - { ruby: "3.3", rails: "8.0", mysql: "mysql:8.4" }
        - { ruby: "3.3", rails: "8.0", mysql: "mysql:8.0" }
        - { ruby: "3.3", rails: "8.0", mysql: "mysql:5.7" }
        - { ruby: "3.3", rails: "8.0", mysql: "mariadb:11" }
        - { ruby: "3.3", rails: "7.1", mysql: "mysql:8.0" }
  services:
    mysql:
      image: ${{ matrix.mysql }}
      env:
        MYSQL_ROOT_PASSWORD: root
        MYSQL_DATABASE: mysql_genius_test
      ports: ["3306:3306"]
      options: >-
        --health-cmd="mysqladmin ping -h localhost"
        --health-interval=10s --health-timeout=5s --health-retries=10
  env:
    REAL_MYSQL: "1"
    DATABASE_URL: "mysql2://root:root@127.0.0.1:3306/mysql_genius_test"
  steps:
    - uses: actions/checkout@v5
    - uses: ruby/setup-ruby@v1
      with: { ruby-version: "${{ matrix.ruby }}", bundler-cache: true }
    - run: bundle exec rspec spec/integration
```

Rationale for matrix selection:
- **MySQL 8.4** (current LTS), **8.0** (previous LTS, still dominant), **5.7** (EOL but huge prod install base, caught the DIGEST bug in 0.8.1).
- **MariaDB 11** (latest) — many Rails shops run MariaDB, and `performance_schema` semantics differ slightly.
- Matrix deliberately narrow on Ruby/Rails (3.3 + 8.0 primary) — we're testing the DB layer, not the Ruby layer. Unit job already covers the Ruby × Rails explosion.

### 6. Dummy app database config

`spec/dummy/config/database.yml` currently doesn't exist (stubs made it unnecessary). Add:

```yaml
test:
  <% if ENV["REAL_MYSQL"] %>
  adapter: mysql2
  url: <%= ENV["DATABASE_URL"] || "mysql2://root:root@127.0.0.1:3306/mysql_genius_test" %>
  <% else %>
  adapter: sqlite3
  database: ":memory:"  # Placeholder — unit specs don't touch it
  <% end %>
```

When `REAL_MYSQL=1`, the dummy app connects to real MySQL; otherwise it uses a no-op SQLite in-memory connection just so Rails boots (unit specs stub everything anyway).

### 7. Adapter matrix: mysql2 vs trilogy

Add a `MYSQL_ADAPTER` env var to the integration job (default `mysql2`, one matrix row overrides to `trilogy`). Catches adapter-specific type coercion differences. Small cost, high value.

## Rollout plan

- **0.9.0-pre rc1**: commit Sakila fixture, SakilaFixture loader, WorkloadGenerator. Integration spec directory empty but wired up.
- **0.9.0-pre rc2**: CI integration job live, one matrix row (MySQL 8.4). Green.
- **0.9.0-pre rc3**: expand matrix (8.0, 5.7, MariaDB 11, trilogy adapter). Fix whatever breaks.
- **0.9.0-pre**: write the first few integration specs covering existing features (query_stats, unused_indexes, EXPLAIN). This is the baseline before adding multi-DB features on top.
- **0.9.0 and beyond**: every new feature ships with integration spec coverage.

## Open questions

1. **Where does the Sakila SQL get staged into the server?** Load into the same `mysql_genius_test` database as the test AR connection, or a separate `sakila` schema? *Recommendation: separate `sakila` schema — keeps fixture data isolated from any tables our own specs might create, and makes the multi-DB spec testable (we can register `sakila` as a second database).*
2. **Workload generator determinism**: should the query list be seeded/randomized or always run in-order? *Recommendation: in-order, fixed count. Deterministic. If a test needs randomness, it can opt in.*
3. **Sakila regeneration cadence**: Sakila upstream changes rarely, but when it does, do we re-pin or skip? *Recommendation: pin hard; only update with a deliberate PR citing the upstream change. Fixtures should be boring.*
4. **Mac local CI parity**: integration job is Linux-only; contributors on Mac need docker or a local MySQL. Document both paths in a `docs/guides/running-integration-tests.md`.

## Files touched

- `spec/fixtures/sakila/LICENSE` (new)
- `spec/fixtures/sakila/README.md` (new)
- `spec/fixtures/sakila/schema.sql` (new, from upstream)
- `spec/fixtures/sakila/data.sql.gz` (new, gzipped from upstream)
- `spec/support/sakila_fixture.rb` (new)
- `spec/support/workload_generator.rb` (new)
- `spec/integration/` (new directory with baseline specs)
- `spec/spec_helper.rb` — add `filter_run_excluding(integration: true)` guard
- `spec/dummy/config/database.yml` (new)
- `.github/workflows/ci.yml` — add `integration` job
- `docs/guides/running-integration-tests.md` (new) — how to run integration tests locally (docker-compose snippet)
- `Gemfile` — add `trilogy` to dev/test group (optional, gated)
