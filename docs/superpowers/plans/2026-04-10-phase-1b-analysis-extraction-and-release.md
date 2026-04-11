# Phase 1b — Extract Analyses, QueryRunner, QueryExplainer + Paired Release

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Phase 1 of the desktop-app extraction by moving the 5 database analyses, the query runner, and the query explainer out of the Rails controller concerns and into `mysql_genius-core`, then do the paired release of `mysql_genius-core 0.1.0` + `mysql_genius 0.4.0` to RubyGems.

**Architecture:** Each analysis becomes a standalone class in `MysqlGenius::Core::Analysis::*` taking a `Core::Connection`. `Core::QueryRunner` owns SQL validation, row-limit/timeout-hint application, execution, and result masking — but not audit logging (that stays Rails-specific in the concern). `Core::QueryExplainer` owns EXPLAIN execution plus truncation detection. The publish workflow gets updated to build and push both gems in the correct order (core first, so its dependency resolves at `gem install` time).

**Tech Stack:** Ruby 2.7+, RSpec 3, `double()` / `instance_double` mocks matching project convention. No new runtime dependencies. Uses `Core::Connection::FakeAdapter` (from Phase 1a) to stub `information_schema` and `performance_schema` queries in core specs.

---

## Scope notes

This plan covers **Phase 1b** from the design spec at `docs/superpowers/specs/2026-04-10-desktop-app-design.md` §9. Phase 1b is the second half of Phase 1; Phase 1a extracted the foundation (SqlValidator, AI services, value objects, Connection contract, ActiveRecordAdapter) and is merged as of commit `9d8e626` on main.

**What this plan delivers:**

- Extract 5 analysis classes (`TableSizes`, `DuplicateIndexes`, `QueryStats`, `UnusedIndexes`, `ServerOverview`) into `MysqlGenius::Core::Analysis::*`
- Extract `MysqlGenius::Core::QueryRunner` from the `execute` action in `QueryExecution` concern
- Extract `MysqlGenius::Core::QueryExplainer` from the `explain` action
- Introduce `Core::ExecutionResult` value object for `QueryRunner`'s return type
- Introduce `Core::QueryRunner::Config` keyword-init Struct for runner configuration
- Update `.github/workflows/publish.yml` to build and push both gems in correct order
- Bump versions: `mysql_genius-core` → `0.1.0`, `mysql_genius` → `0.4.0`
- Update `mysql_genius.gemspec` dependency from `"~> 0.1.0.pre"` to `"~> 0.1"`
- Flip `CHANGELOG.md` `## Unreleased` section to `## 0.4.0` and add Phase 1b notes
- Tag and publish the paired release

**What this plan does NOT deliver:**

- ERB template extraction (deferred from Phase 1 entirely; will be handled in Phase 2 alongside the desktop sidecar's concrete non-Rails consumer)
- The 7 inline AI features in `AiFeatures` concern (`describe_query`, `schema_review`, `rewrite_query`, `index_advisor`, `anomaly_detection`, `root_cause`, `migration_risk`) — these use `ai_client` via a Phase 1a helper and already delegate correctly through `Core::Ai::Client`. They don't need class extraction for Phase 1b because they're not analyses-on-a-connection; they're prompt builders that compose the existing `Core::Ai::Client`. Phase 2 or later can extract them if the desktop app needs them structured differently.
- `slow_queries` action (Redis-backed, Rails-specific, stays in the adapter per spec §4.4)
- `columns` action (reads AR-specific column metadata, stays in the adapter — Phase 2 can introduce a `Core::Connection`-based equivalent when needed)
- `index` action (reads `queryable_tables`, stays in the adapter)

**Zero public API change.** The Rails engine's mountpoint, routes, JSON response shapes, and config DSL remain identical. A host app running `bundle update mysql_genius` from 0.3.2 to 0.4.0 should see no behavior change — only a new transitive dependency on `mysql_genius-core 0.1.0`.

---

## File Structure

After this plan, these files will exist:

```
mysql_genius/                             (repo root — Rails adapter gem)
├── app/controllers/concerns/mysql_genius/
│   ├── database_analysis.rb              (REWRITTEN — thin delegation to Core::Analysis::*)
│   └── query_execution.rb                (REWRITTEN — thin delegation to Core::QueryRunner + Core::QueryExplainer)
├── lib/mysql_genius/
│   └── version.rb                        (BUMP: 0.3.2 → 0.4.0)
├── mysql_genius.gemspec                  (BUMP DEP: "~> 0.1.0.pre" → "~> 0.1")
├── CHANGELOG.md                          (FLIP: ## Unreleased → ## 0.4.0, add Phase 1b notes)
│
├── .github/workflows/
│   └── publish.yml                       (UPDATE: build and push both gems)
│
└── gems/mysql_genius-core/
    ├── lib/mysql_genius/
    │   ├── core.rb                       (ADD requires for new files)
    │   └── core/
    │       ├── version.rb                (BUMP: 0.1.0.pre → 0.1.0)
    │       ├── execution_result.rb       (NEW — value object for QueryRunner's return)
    │       ├── query_runner.rb           (NEW)
    │       ├── query_runner/
    │       │   └── config.rb             (NEW — keyword-init Struct)
    │       ├── query_explainer.rb        (NEW)
    │       └── analysis/
    │           ├── table_sizes.rb        (NEW)
    │           ├── duplicate_indexes.rb  (NEW)
    │           ├── query_stats.rb        (NEW)
    │           ├── unused_indexes.rb     (NEW)
    │           └── server_overview.rb    (NEW)
    └── spec/mysql_genius/core/
        ├── execution_result_spec.rb      (NEW)
        ├── query_runner_spec.rb          (NEW)
        ├── query_runner/
        │   └── config_spec.rb            (NEW)
        ├── query_explainer_spec.rb       (NEW)
        └── analysis/
            ├── table_sizes_spec.rb       (NEW)
            ├── duplicate_indexes_spec.rb (NEW)
            ├── query_stats_spec.rb       (NEW)
            ├── unused_indexes_spec.rb    (NEW)
            └── server_overview_spec.rb   (NEW)
```

**Design responsibilities:**

- `Core::Analysis::TableSizes` — takes a `Core::Connection`, queries `information_schema.tables` + per-table `COUNT(*)`, returns an array of hashes with size/row/fragmentation metadata
- `Core::Analysis::DuplicateIndexes` — takes a `Core::Connection` + `blocked_tables:`, calls `connection.indexes_for(table)` for each queryable table, detects left-prefix covering, returns an array of hashes
- `Core::Analysis::QueryStats` — takes a `Core::Connection`, queries `performance_schema.events_statements_summary_by_digest` with sort + limit params, returns an array of hashes
- `Core::Analysis::UnusedIndexes` — takes a `Core::Connection`, queries `performance_schema.table_io_waits_summary_by_index_usage` JOINed with `information_schema.tables`, returns an array of hashes
- `Core::Analysis::ServerOverview` — takes a `Core::Connection`, queries `SHOW GLOBAL STATUS`, `SHOW GLOBAL VARIABLES`, `SELECT VERSION()`, computes derived metrics, returns a nested hash
- `Core::ExecutionResult` — immutable frozen value object: columns, rows, row_count, execution_time_ms, truncated
- `Core::QueryRunner::Config` — keyword-init Struct: blocked_tables, masked_column_patterns, query_timeout_ms
- `Core::QueryRunner` — takes a `Core::Connection` + `Config`, `.run(sql, row_limit:)` validates, applies limit/timeout, executes, masks columns, returns `ExecutionResult` or raises `Rejected` / `Timeout`
- `Core::QueryExplainer` — takes a `Core::Connection` + `Config`, `.explain(sql, skip_validation: false)` validates (unless skipped), checks truncation, runs `EXPLAIN`, returns `Core::Result` or raises `Rejected` / `Truncated`

**Result iteration convention:** Analysis classes use `result.to_hashes` (added in Phase 1a's `Core::Result`) to iterate rows as column-keyed hashes. This matches the existing `ActiveRecord::Result` iteration pattern the old code relied on.

**Audit logging stays in the Rails adapter.** `QueryRunner` does not know about audit loggers. The `execute` action in the concern calls `QueryRunner#run`, then audits the result (or error) using `mysql_genius_config.audit_logger` before rendering JSON. This preserves Rails-specific behavior without leaking it into core.

---

## Stage A — Extract the 5 analysis classes

Each analysis follows the same TDD pattern: write a failing spec using `FakeAdapter`, implement the class, wire it up in `core.rb`, update the concern action to delegate, run the full suite, commit. Each analysis is one task with 8 steps.

### Task 1: Extract `Core::Analysis::TableSizes`

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/analysis/table_sizes_spec.rb`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/analysis/table_sizes.rb`
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`
- Modify: `app/controllers/concerns/mysql_genius/database_analysis.rb` (lines 51-99)

- [ ] **Step 1: Create the spec directory and write the failing spec**

```bash
mkdir -p gems/mysql_genius-core/spec/mysql_genius/core/analysis
```

Write `gems/mysql_genius-core/spec/mysql_genius/core/analysis/table_sizes_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run the spec, verify it fails**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/table_sizes_spec.rb 2>&1 | tail -10
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Analysis` (and/or `Analysis::TableSizes`).

- [ ] **Step 3: Create the analysis directory and implement `TableSizes`**

```bash
mkdir -p gems/mysql_genius-core/lib/mysql_genius/core/analysis
```

Write `gems/mysql_genius-core/lib/mysql_genius/core/analysis/table_sizes.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Queries information_schema.tables for data/index/fragmentation metrics
      # per BASE TABLE in the current database, plus an exact SELECT COUNT(*)
      # for each table. Returns an array of hashes suitable for JSON rendering.
      #
      # Takes a Core::Connection. No configuration required — the current
      # database is read from connection.current_database.
      class TableSizes
        def initialize(connection)
          @connection = connection
        end

        def call
          db_name = @connection.current_database

          result = @connection.exec_query(<<~SQL)
            SELECT
              table_name,
              engine,
              table_collation,
              auto_increment,
              update_time,
              ROUND(data_length / 1024 / 1024, 2) AS data_mb,
              ROUND(index_length / 1024 / 1024, 2) AS index_mb,
              ROUND((data_length + index_length) / 1024 / 1024, 2) AS total_mb,
              ROUND(data_free / 1024 / 1024, 2) AS fragmented_mb
            FROM information_schema.tables
            WHERE table_schema = #{@connection.quote(db_name)}
              AND table_type = 'BASE TABLE'
            ORDER BY (data_length + index_length) DESC
          SQL

          result.to_hashes.map do |row|
            table_name = row["table_name"] || row["TABLE_NAME"]
            row_count = begin
              @connection.select_value("SELECT COUNT(*) FROM #{@connection.quote_table_name(table_name)}")
            rescue StandardError
              nil
            end

            total_mb = (row["total_mb"] || 0).to_f
            fragmented_mb = (row["fragmented_mb"] || 0).to_f

            {
              table: table_name,
              rows: row_count,
              engine: row["engine"] || row["ENGINE"],
              collation: row["table_collation"] || row["TABLE_COLLATION"],
              auto_increment: row["auto_increment"] || row["AUTO_INCREMENT"],
              updated_at: row["update_time"] || row["UPDATE_TIME"],
              data_mb: (row["data_mb"] || 0).to_f,
              index_mb: (row["index_mb"] || 0).to_f,
              total_mb: total_mb,
              fragmented_mb: fragmented_mb,
              needs_optimize: total_mb.positive? && fragmented_mb > (total_mb * 0.1),
            }
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Require the new file from `core.rb`**

Edit `gems/mysql_genius-core/lib/mysql_genius/core.rb` and append after the existing `require` lines:

```ruby
require "mysql_genius/core/analysis/table_sizes"
```

- [ ] **Step 5: Run the spec, verify it passes**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/table_sizes_spec.rb 2>&1 | tail -10
```

Expected: 5 examples, 0 failures.

- [ ] **Step 6: Update the `table_sizes` concern action to delegate**

In `app/controllers/concerns/mysql_genius/database_analysis.rb`, replace the entire `table_sizes` method (lines 51-99) with:

```ruby
    def table_sizes
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      tables = MysqlGenius::Core::Analysis::TableSizes.new(connection).call
      render(json: tables)
    end
```

- [ ] **Step 7: Run both suites**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius && bundle exec rspec 2>&1 | tail -5
cd /Users/abyrd/Code/GitHub/mysql_genius/gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -5
```

Expected: both suites green. Rails adapter suite unchanged in count (36/36). Core gem suite grows by 5 examples.

- [ ] **Step 8: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Extract TableSizes analysis into mysql_genius-core

Move the information_schema.tables query and result transformation
out of the DatabaseAnalysis concern into a new
MysqlGenius::Core::Analysis::TableSizes class that takes a
Core::Connection. The concern's table_sizes action now builds an
ActiveRecordAdapter and delegates.

Behavior is byte-identical — same SQL, same result shape, same
per-table COUNT(*) fallback on error, same needs_optimize threshold.
The 5 new core specs use FakeAdapter to stub information_schema
results and verify row handling (hash access, MariaDB uppercase
column names, COUNT(*) error fallback, needs_optimize computation).
EOF
)"
```

---

### Task 2: Extract `Core::Analysis::DuplicateIndexes`

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/analysis/duplicate_indexes_spec.rb`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/analysis/duplicate_indexes.rb`
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`
- Modify: `app/controllers/concerns/mysql_genius/database_analysis.rb` (lines 7-49)

- [ ] **Step 1: Write the failing spec**

Write `gems/mysql_genius-core/spec/mysql_genius/core/analysis/duplicate_indexes_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::DuplicateIndexes) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:blocked_tables) { ["sessions"] }
  subject(:analysis) { described_class.new(connection, blocked_tables: blocked_tables) }

  def idx(name, columns, unique: false)
    MysqlGenius::Core::IndexDefinition.new(name: name, columns: columns, unique: unique)
  end

  describe "#call" do
    it "returns an empty array when there are no queryable tables" do
      connection.stub_tables([])

      expect(analysis.call).to(eq([]))
    end

    it "returns an empty array when tables have fewer than 2 indexes" do
      connection.stub_tables(["users"])
      connection.stub_indexes_for("users", [idx("index_users_on_email", ["email"], unique: true)])

      expect(analysis.call).to(eq([]))
    end

    it "detects a left-prefix duplicate" do
      connection.stub_tables(["users"])
      connection.stub_indexes_for("users", [
        idx("index_users_on_email", ["email"]),
        idx("index_users_on_email_and_name", ["email", "name"]),
      ])

      result = analysis.call

      expect(result.length).to(eq(1))
      expect(result.first).to(include(
        table: "users",
        duplicate_index: "index_users_on_email",
        duplicate_columns: ["email"],
        covered_by_index: "index_users_on_email_and_name",
        covered_by_columns: ["email", "name"],
        unique: false,
      ))
    end

    it "does not flag two indexes on different columns" do
      connection.stub_tables(["users"])
      connection.stub_indexes_for("users", [
        idx("index_users_on_email", ["email"]),
        idx("index_users_on_name", ["name"]),
      ])

      expect(analysis.call).to(eq([]))
    end

    it "does not drop a unique index covered only by a non-unique one" do
      connection.stub_tables(["users"])
      connection.stub_indexes_for("users", [
        idx("index_users_on_email_unique", ["email"], unique: true),
        idx("index_users_on_email_and_name", ["email", "name"], unique: false),
      ])

      expect(analysis.call).to(eq([]))
    end

    it "skips blocked tables" do
      connection.stub_tables(["users", "sessions"])
      connection.stub_indexes_for("sessions", [
        idx("index_sessions_on_token", ["token"]),
        idx("index_sessions_on_token_and_user_id", ["token", "user_id"]),
      ])
      connection.stub_indexes_for("users", [idx("index_users_on_email", ["email"])])

      expect(analysis.call).to(eq([]))
    end

    it "deduplicates when two indexes cover each other with identical columns" do
      connection.stub_tables(["users"])
      connection.stub_indexes_for("users", [
        idx("idx_a", ["email"]),
        idx("idx_b", ["email"]),
      ])

      result = analysis.call

      expect(result.length).to(eq(1))
    end
  end
end
```

- [ ] **Step 2: Run spec, verify fail**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/duplicate_indexes_spec.rb 2>&1 | tail -10
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Analysis::DuplicateIndexes`.

- [ ] **Step 3: Implement `DuplicateIndexes`**

Write `gems/mysql_genius-core/lib/mysql_genius/core/analysis/duplicate_indexes.rb`:

```ruby
# frozen_string_literal: true

require "set"

module MysqlGenius
  module Core
    module Analysis
      # Detects indexes whose columns are a left-prefix of another index on
      # the same table (meaning the shorter index is redundant — the longer
      # one can satisfy the same queries). Preserves unique indexes: a unique
      # index is never flagged as redundant when only covered by a non-unique
      # index.
      #
      # Takes a Core::Connection plus a list of tables to exclude from the
      # scan. Returns an array of hashes describing each duplicate pair, with
      # the (duplicate_index, covered_by_index) pair deduplicated across
      # symmetrical relationships.
      class DuplicateIndexes
        def initialize(connection, blocked_tables:)
          @connection = connection
          @blocked_tables = blocked_tables
        end

        def call
          duplicates = []

          queryable_tables.each do |table|
            indexes = @connection.indexes_for(table)
            next if indexes.size < 2

            indexes.each do |idx|
              indexes.each do |other|
                next if idx.name == other.name
                next unless covers?(other, idx)

                duplicates << {
                  table: table,
                  duplicate_index: idx.name,
                  duplicate_columns: idx.columns,
                  covered_by_index: other.name,
                  covered_by_columns: other.columns,
                  unique: idx.unique,
                }
              end
            end
          end

          deduplicate(duplicates)
        end

        private

        def queryable_tables
          @connection.tables - @blocked_tables
        end

        # True if `other` covers `idx` (idx's columns are a left-prefix of
        # other's columns). Protects unique indexes from being covered by
        # non-unique ones.
        def covers?(other, idx)
          return false unless idx.columns.size <= other.columns.size
          return false unless other.columns.first(idx.columns.size) == idx.columns
          return false if idx.unique && !other.unique

          true
        end

        def deduplicate(duplicates)
          seen = Set.new
          duplicates.reject do |d|
            key = [d[:table], [d[:duplicate_index], d[:covered_by_index]].sort].flatten.join(":")
            if seen.include?(key)
              true
            else
              seen.add(key)
              false
            end
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Require the new file from `core.rb`**

Edit `gems/mysql_genius-core/lib/mysql_genius/core.rb` and append:

```ruby
require "mysql_genius/core/analysis/duplicate_indexes"
```

- [ ] **Step 5: Run spec, verify pass**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/duplicate_indexes_spec.rb 2>&1 | tail -10
```

Expected: 7 examples, 0 failures.

- [ ] **Step 6: Update the `duplicate_indexes` concern action**

In `app/controllers/concerns/mysql_genius/database_analysis.rb`, replace the entire `duplicate_indexes` method (lines 7-49) with:

```ruby
    def duplicate_indexes
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      duplicates = MysqlGenius::Core::Analysis::DuplicateIndexes
        .new(connection, blocked_tables: mysql_genius_config.blocked_tables)
        .call
      render(json: duplicates)
    end
```

- [ ] **Step 7: Run both suites**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius && bundle exec rspec 2>&1 | tail -5
cd /Users/abyrd/Code/GitHub/mysql_genius/gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -5
```

Expected: both green.

- [ ] **Step 8: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Extract DuplicateIndexes analysis into mysql_genius-core

Move the left-prefix duplicate-index detection out of the
DatabaseAnalysis concern into a new
MysqlGenius::Core::Analysis::DuplicateIndexes class. The class takes
a Core::Connection plus a blocked_tables list and returns an array
of duplicate pairs, with the symmetrical-coverage dedup preserved.

The concern now builds an ActiveRecordAdapter and delegates,
passing blocked_tables from the configuration.
EOF
)"
```

---

### Task 3: Extract `Core::Analysis::QueryStats`

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/analysis/query_stats_spec.rb`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/analysis/query_stats.rb`
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`
- Modify: `app/controllers/concerns/mysql_genius/database_analysis.rb` (lines 101-167)

- [ ] **Step 1: Write the failing spec**

Write `gems/mysql_genius-core/spec/mysql_genius/core/analysis/query_stats_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::QueryStats) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  subject(:analysis) { described_class.new(connection) }

  before do
    connection.stub_current_database("app_test")
  end

  describe "#call" do
    let(:columns) do
      %w[
        DIGEST_TEXT calls total_time_ms avg_time_ms max_time_ms
        rows_examined rows_sent tmp_disk_tables sort_rows
        FIRST_SEEN LAST_SEEN
      ]
    end

    it "returns an empty array when performance_schema has no digest rows" do
      connection.stub_query(/performance_schema\.events_statements_summary_by_digest/, columns: columns, rows: [])

      expect(analysis.call).to(eq([]))
    end

    it "transforms digest rows into hashes keyed by symbol" do
      connection.stub_query(
        /performance_schema\.events_statements_summary_by_digest/,
        columns: columns,
        rows: [
          ["SELECT * FROM users WHERE id = ?", 100, 500.5, 5.005, 42.1, 1000, 100, 0, 0, "2026-04-01T00:00:00Z", "2026-04-10T00:00:00Z"],
        ],
      )

      result = analysis.call

      expect(result.length).to(eq(1))
      expect(result.first).to(include(
        sql: "SELECT * FROM users WHERE id = ?",
        calls: 100,
        total_time_ms: 500.5,
        avg_time_ms: 5.005,
        max_time_ms: 42.1,
        rows_examined: 1000,
        rows_sent: 100,
        rows_ratio: 10.0,
      ))
    end

    it "computes rows_ratio as 0 when rows_sent is 0" do
      connection.stub_query(
        /performance_schema\.events_statements_summary_by_digest/,
        columns: columns,
        rows: [["SET NAMES ?", 50, 10.0, 0.2, 1.0, 0, 0, 0, 0, nil, nil]],
      )

      expect(analysis.call.first[:rows_ratio]).to(eq(0))
    end

    it "accepts the sort parameter (total_time default)" do
      captured_sql = nil
      connection.stub_query(
        /performance_schema\.events_statements_summary_by_digest/,
        columns: columns,
        rows: [],
      )
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql|
        captured_sql = sql
        original.call(sql)
      end)

      analysis.call(sort: "total_time")
      expect(captured_sql).to(match(/ORDER BY SUM_TIMER_WAIT DESC/))
    end

    it "supports sort=avg_time" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql|
        captured_sql = sql
        original.call(sql)
      end)

      analysis.call(sort: "avg_time")
      expect(captured_sql).to(match(/ORDER BY AVG_TIMER_WAIT DESC/))
    end

    it "supports sort=calls" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql|
        captured_sql = sql
        original.call(sql)
      end)

      analysis.call(sort: "calls")
      expect(captured_sql).to(match(/ORDER BY COUNT_STAR DESC/))
    end

    it "supports sort=rows_examined" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql|
        captured_sql = sql
        original.call(sql)
      end)

      analysis.call(sort: "rows_examined")
      expect(captured_sql).to(match(/ORDER BY SUM_ROWS_EXAMINED DESC/))
    end

    it "rejects invalid sort values and falls back to total_time" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql|
        captured_sql = sql
        original.call(sql)
      end)

      analysis.call(sort: "' OR 1=1 --")
      expect(captured_sql).to(match(/ORDER BY SUM_TIMER_WAIT DESC/))
    end

    it "clamps limit to [1, 50]" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql|
        captured_sql = sql
        original.call(sql)
      end)

      analysis.call(limit: 99)
      expect(captured_sql).to(match(/LIMIT 50/))
    end

    it "handles a small limit" do
      captured_sql = nil
      connection.stub_query(/performance_schema/, columns: columns, rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql|
        captured_sql = sql
        original.call(sql)
      end)

      analysis.call(limit: 5)
      expect(captured_sql).to(match(/LIMIT 5/))
    end

    it "truncates long digest text to 500 characters" do
      long_digest = "SELECT * FROM users WHERE " + ("foo = 1 AND " * 100)
      connection.stub_query(
        /performance_schema/,
        columns: columns,
        rows: [[long_digest, 1, 1.0, 1.0, 1.0, 1, 1, 0, 0, nil, nil]],
      )

      result = analysis.call
      expect(result.first[:sql].length).to(be <= 500)
    end
  end
end
```

- [ ] **Step 2: Run spec, verify fail**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/query_stats_spec.rb 2>&1 | tail -10
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Analysis::QueryStats`.

- [ ] **Step 3: Implement `QueryStats`**

Write `gems/mysql_genius-core/lib/mysql_genius/core/analysis/query_stats.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Queries performance_schema.events_statements_summary_by_digest for
      # the top statements by a given sort dimension, excluding noise
      # (internal schema queries, EXPLAIN, SHOW, SET STATEMENT, etc.).
      # Returns an array of per-digest hashes with call counts, timing
      # percentiles, row examine/sent ratios, and temp-table metadata.
      #
      # If performance_schema is not enabled, the underlying exec_query
      # call will raise — the caller decides how to render that.
      class QueryStats
        VALID_SORTS = ["total_time", "avg_time", "calls", "rows_examined"].freeze
        MAX_LIMIT = 50

        def initialize(connection)
          @connection = connection
        end

        def call(sort: "total_time", limit: MAX_LIMIT)
          order_clause = order_clause_for(sort)
          effective_limit = limit.to_i.clamp(1, MAX_LIMIT)

          result = @connection.exec_query(build_sql(order_clause, effective_limit))
          result.to_hashes.map { |row| transform(row) }
        end

        private

        def order_clause_for(sort)
          case sort
          when "total_time"    then "SUM_TIMER_WAIT DESC"
          when "avg_time"      then "AVG_TIMER_WAIT DESC"
          when "calls"         then "COUNT_STAR DESC"
          when "rows_examined" then "SUM_ROWS_EXAMINED DESC"
          else "SUM_TIMER_WAIT DESC"
          end
        end

        def build_sql(order_clause, limit)
          <<~SQL
            SELECT
              DIGEST_TEXT,
              COUNT_STAR AS calls,
              ROUND(SUM_TIMER_WAIT / 1000000000, 1) AS total_time_ms,
              ROUND(AVG_TIMER_WAIT / 1000000000, 1) AS avg_time_ms,
              ROUND(MAX_TIMER_WAIT / 1000000000, 1) AS max_time_ms,
              SUM_ROWS_EXAMINED AS rows_examined,
              SUM_ROWS_SENT AS rows_sent,
              SUM_CREATED_TMP_DISK_TABLES AS tmp_disk_tables,
              SUM_SORT_ROWS AS sort_rows,
              FIRST_SEEN,
              LAST_SEEN
            FROM performance_schema.events_statements_summary_by_digest
            WHERE SCHEMA_NAME = #{@connection.quote(@connection.current_database)}
              AND DIGEST_TEXT IS NOT NULL
              AND DIGEST_TEXT NOT LIKE 'EXPLAIN%'
              AND DIGEST_TEXT NOT LIKE '%`information_schema`%'
              AND DIGEST_TEXT NOT LIKE '%`performance_schema`%'
              AND DIGEST_TEXT NOT LIKE '%information_schema.%'
              AND DIGEST_TEXT NOT LIKE '%performance_schema.%'
              AND DIGEST_TEXT NOT LIKE 'SHOW %'
              AND DIGEST_TEXT NOT LIKE 'SET STATEMENT %'
              AND DIGEST_TEXT NOT LIKE 'SELECT VERSION ( )%'
              AND DIGEST_TEXT NOT LIKE 'SELECT @@%'
            ORDER BY #{order_clause}
            LIMIT #{limit}
          SQL
        end

        def transform(row)
          digest = (row["DIGEST_TEXT"] || row["digest_text"] || "").to_s
          calls = (row["calls"] || row["CALLS"] || 0).to_i
          rows_examined = (row["rows_examined"] || row["ROWS_EXAMINED"] || 0).to_i
          rows_sent = (row["rows_sent"] || row["ROWS_SENT"] || 0).to_i

          {
            sql: truncate(digest, 500),
            calls: calls,
            total_time_ms: (row["total_time_ms"] || 0).to_f,
            avg_time_ms: (row["avg_time_ms"] || 0).to_f,
            max_time_ms: (row["max_time_ms"] || 0).to_f,
            rows_examined: rows_examined,
            rows_sent: rows_sent,
            rows_ratio: rows_sent.positive? ? (rows_examined.to_f / rows_sent).round(1) : 0,
            tmp_disk_tables: (row["tmp_disk_tables"] || row["TMP_DISK_TABLES"] || 0).to_i,
            sort_rows: (row["sort_rows"] || row["SORT_ROWS"] || 0).to_i,
            first_seen: row["FIRST_SEEN"] || row["first_seen"],
            last_seen: row["LAST_SEEN"] || row["last_seen"],
          }
        end

        def truncate(string, max)
          return string if string.length <= max

          "#{string[0, max - 3]}..."
        end
      end
    end
  end
end
```

- [ ] **Step 4: Require from `core.rb`**

Append to `gems/mysql_genius-core/lib/mysql_genius/core.rb`:

```ruby
require "mysql_genius/core/analysis/query_stats"
```

- [ ] **Step 5: Run spec, verify pass**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/query_stats_spec.rb 2>&1 | tail -10
```

Expected: 11 examples, 0 failures.

- [ ] **Step 6: Update the `query_stats` concern action**

In `app/controllers/concerns/mysql_genius/database_analysis.rb`, replace the entire `query_stats` method (lines 101-167) with:

```ruby
    def query_stats
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      sort = params[:sort].to_s
      limit = params.fetch(:limit, MysqlGenius::Core::Analysis::QueryStats::MAX_LIMIT).to_i
      queries = MysqlGenius::Core::Analysis::QueryStats.new(connection).call(sort: sort, limit: limit)
      render(json: queries)
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Query statistics require performance_schema to be enabled. #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end
```

- [ ] **Step 7: Run both suites**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius && bundle exec rspec 2>&1 | tail -5
cd /Users/abyrd/Code/GitHub/mysql_genius/gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -5
```

Expected: both green.

- [ ] **Step 8: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Extract QueryStats analysis into mysql_genius-core

Move the performance_schema.events_statements_summary_by_digest
query out of the DatabaseAnalysis concern into a new
MysqlGenius::Core::Analysis::QueryStats class. Sort whitelist and
limit clamping now live in the class as VALID_SORTS and MAX_LIMIT
constants; the concern action parses params and hands them to
.call(sort:, limit:).

performance_schema availability errors continue to be caught by
the concern (Rails-specific ActiveRecord::StatementInvalid) and
rendered with the same user-facing message as before.
EOF
)"
```

---

### Task 4: Extract `Core::Analysis::UnusedIndexes`

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/analysis/unused_indexes_spec.rb`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/analysis/unused_indexes.rb`
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`
- Modify: `app/controllers/concerns/mysql_genius/database_analysis.rb` (lines 169-208)

- [ ] **Step 1: Write the failing spec**

Write `gems/mysql_genius-core/spec/mysql_genius/core/analysis/unused_indexes_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::UnusedIndexes) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  subject(:analysis) { described_class.new(connection) }

  before do
    connection.stub_current_database("app_test")
  end

  describe "#call" do
    let(:columns) { %w[table_schema table_name index_name reads writes table_rows] }

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
        columns: %w[TABLE_SCHEMA TABLE_NAME INDEX_NAME READS WRITES TABLE_ROWS],
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
```

- [ ] **Step 2: Run spec, verify fail**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/unused_indexes_spec.rb 2>&1 | tail -10
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Analysis::UnusedIndexes`.

- [ ] **Step 3: Implement `UnusedIndexes`**

Write `gems/mysql_genius-core/lib/mysql_genius/core/analysis/unused_indexes.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Queries performance_schema.table_io_waits_summary_by_index_usage
      # joined with information_schema.tables to find indexes with zero
      # reads but non-zero row counts in their parent table. Returns hashes
      # with a ready-to-run DROP INDEX statement per result.
      #
      # Skips the PRIMARY index (should never be dropped) and anonymous
      # rows (where INDEX_NAME IS NULL). Raises if performance_schema is
      # unavailable.
      class UnusedIndexes
        def initialize(connection)
          @connection = connection
        end

        def call
          db_name = @connection.current_database

          result = @connection.exec_query(<<~SQL)
            SELECT
              s.OBJECT_SCHEMA AS table_schema,
              s.OBJECT_NAME AS table_name,
              s.INDEX_NAME AS index_name,
              s.COUNT_READ AS `reads`,
              s.COUNT_WRITE AS `writes`,
              t.TABLE_ROWS AS table_rows
            FROM performance_schema.table_io_waits_summary_by_index_usage s
            JOIN information_schema.tables t
              ON t.TABLE_SCHEMA = s.OBJECT_SCHEMA AND t.TABLE_NAME = s.OBJECT_NAME
            WHERE s.OBJECT_SCHEMA = #{@connection.quote(db_name)}
              AND s.INDEX_NAME IS NOT NULL
              AND s.INDEX_NAME != 'PRIMARY'
              AND s.COUNT_READ = 0
              AND t.TABLE_ROWS > 0
            ORDER BY s.COUNT_WRITE DESC
          SQL

          result.to_hashes.map do |row|
            table = row["table_name"] || row["TABLE_NAME"]
            index_name = row["index_name"] || row["INDEX_NAME"]
            {
              table: table,
              index_name: index_name,
              reads: (row["reads"] || row["READS"] || 0).to_i,
              writes: (row["writes"] || row["WRITES"] || 0).to_i,
              table_rows: (row["table_rows"] || row["TABLE_ROWS"] || 0).to_i,
              drop_sql: "ALTER TABLE `#{table}` DROP INDEX `#{index_name}`;",
            }
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Require from `core.rb`**

Append to `gems/mysql_genius-core/lib/mysql_genius/core.rb`:

```ruby
require "mysql_genius/core/analysis/unused_indexes"
```

- [ ] **Step 5: Run spec, verify pass**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/unused_indexes_spec.rb 2>&1 | tail -10
```

Expected: 4 examples, 0 failures.

- [ ] **Step 6: Update the `unused_indexes` concern action**

In `app/controllers/concerns/mysql_genius/database_analysis.rb`, replace the entire `unused_indexes` method (lines 169-208) with:

```ruby
    def unused_indexes
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      indexes = MysqlGenius::Core::Analysis::UnusedIndexes.new(connection).call
      render(json: indexes)
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Unused index detection requires performance_schema. #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end
```

- [ ] **Step 7: Run both suites**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius && bundle exec rspec 2>&1 | tail -5
cd /Users/abyrd/Code/GitHub/mysql_genius/gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -5
```

Expected: both green.

- [ ] **Step 8: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Extract UnusedIndexes analysis into mysql_genius-core

Move the performance_schema.table_io_waits_summary_by_index_usage
JOIN query out of the DatabaseAnalysis concern into a new
MysqlGenius::Core::Analysis::UnusedIndexes class. The class takes
a Core::Connection and returns an array of hashes with a
ready-to-run ALTER TABLE DROP INDEX statement per entry.

performance_schema availability errors stay in the concern's
ActiveRecord::StatementInvalid rescue.
EOF
)"
```

---

### Task 5: Extract `Core::Analysis::ServerOverview`

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/analysis/server_overview_spec.rb`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/analysis/server_overview.rb`
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`
- Modify: `app/controllers/concerns/mysql_genius/database_analysis.rb` (lines 210-293)

- [ ] **Step 1: Write the failing spec**

Write `gems/mysql_genius-core/spec/mysql_genius/core/analysis/server_overview_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::ServerOverview) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  subject(:analysis) { described_class.new(connection) }

  before do
    connection.stub_query(/SELECT VERSION/, columns: ["VERSION()"], rows: [["8.0.35"]])

    connection.stub_query(
      /SHOW GLOBAL STATUS/,
      columns: ["Variable_name", "Value"],
      rows: [
        ["Uptime", "90061"],
        ["Threads_connected", "15"],
        ["Threads_running", "2"],
        ["Threads_cached", "5"],
        ["Threads_created", "120"],
        ["Aborted_connects", "3"],
        ["Aborted_clients", "1"],
        ["Max_used_connections", "42"],
        ["Innodb_buffer_pool_read_requests", "1000000"],
        ["Innodb_buffer_pool_reads", "10000"],
        ["Innodb_buffer_pool_pages_dirty", "100"],
        ["Innodb_buffer_pool_pages_free", "500"],
        ["Innodb_buffer_pool_pages_total", "8000"],
        ["Innodb_row_lock_waits", "5"],
        ["Innodb_row_lock_time", "250.5"],
        ["Created_tmp_tables", "100"],
        ["Created_tmp_disk_tables", "10"],
        ["Slow_queries", "7"],
        ["Questions", "901000"],
        ["Select_full_join", "3"],
        ["Sort_merge_passes", "0"],
      ],
    )

    connection.stub_query(
      /SHOW GLOBAL VARIABLES/,
      columns: ["Variable_name", "Value"],
      rows: [
        ["max_connections", "150"],
        ["innodb_buffer_pool_size", "134217728"], # 128 MB
      ],
    )
  end

  describe "#call" do
    it "returns a server block with version and uptime string" do
      result = analysis.call

      expect(result[:server][:version]).to(eq("8.0.35"))
      expect(result[:server][:uptime_seconds]).to(eq(90_061))
      expect(result[:server][:uptime]).to(eq("1d 1h 1m"))
    end

    it "computes connection usage percentage" do
      result = analysis.call

      expect(result[:connections][:max]).to(eq(150))
      expect(result[:connections][:current]).to(eq(15))
      expect(result[:connections][:usage_pct]).to(eq(10.0))
      expect(result[:connections][:threads_running]).to(eq(2))
      expect(result[:connections][:threads_cached]).to(eq(5))
      expect(result[:connections][:threads_created]).to(eq(120))
      expect(result[:connections][:aborted_connects]).to(eq(3))
      expect(result[:connections][:aborted_clients]).to(eq(1))
      expect(result[:connections][:max_used]).to(eq(42))
    end

    it "computes buffer pool size in MB and hit rate" do
      result = analysis.call

      expect(result[:innodb][:buffer_pool_mb]).to(eq(128.0))
      expect(result[:innodb][:buffer_pool_hit_rate]).to(eq(99.0))
      expect(result[:innodb][:buffer_pool_pages_dirty]).to(eq(100))
      expect(result[:innodb][:buffer_pool_pages_free]).to(eq(500))
      expect(result[:innodb][:buffer_pool_pages_total]).to(eq(8000))
      expect(result[:innodb][:row_lock_waits]).to(eq(5))
      expect(result[:innodb][:row_lock_time_ms]).to(eq(251))
    end

    it "computes query stats including qps from questions/uptime" do
      result = analysis.call

      expect(result[:queries][:questions]).to(eq(901_000))
      expect(result[:queries][:qps]).to(eq(10.0))
      expect(result[:queries][:slow_queries]).to(eq(7))
      expect(result[:queries][:tmp_tables]).to(eq(100))
      expect(result[:queries][:tmp_disk_tables]).to(eq(10))
      expect(result[:queries][:tmp_disk_pct]).to(eq(10.0))
      expect(result[:queries][:select_full_join]).to(eq(3))
      expect(result[:queries][:sort_merge_passes]).to(eq(0))
    end

    it "handles zero uptime gracefully (qps = 0)" do
      connection.stub_query(
        /SHOW GLOBAL STATUS/,
        columns: ["Variable_name", "Value"],
        rows: [
          ["Uptime", "0"],
          ["Questions", "0"],
          ["Threads_connected", "0"],
          ["Max_used_connections", "0"],
          ["Created_tmp_tables", "0"],
          ["Innodb_buffer_pool_read_requests", "0"],
          ["Innodb_buffer_pool_reads", "0"],
        ],
      )

      result = analysis.call
      expect(result[:queries][:qps]).to(eq(0))
      expect(result[:innodb][:buffer_pool_hit_rate]).to(eq(0))
    end
  end
end
```

- [ ] **Step 2: Run spec, verify fail**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/server_overview_spec.rb 2>&1 | tail -10
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Analysis::ServerOverview`.

- [ ] **Step 3: Implement `ServerOverview`**

Write `gems/mysql_genius-core/lib/mysql_genius/core/analysis/server_overview.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    module Analysis
      # Collects a dashboard-worthy snapshot of server state by combining
      # SHOW GLOBAL STATUS, SHOW GLOBAL VARIABLES, and SELECT VERSION().
      # Computes derived metrics (uptime formatting, connection usage
      # percentage, buffer pool hit rate, tmp-disk percentage, QPS).
      #
      # Returns a nested hash with four top-level sections: server,
      # connections, innodb, queries. Errors propagate; the caller
      # decides how to render failure.
      class ServerOverview
        def initialize(connection)
          @connection = connection
        end

        def call
          status = load_status
          vars = load_variables
          version = @connection.select_value("SELECT VERSION()")

          uptime_seconds = status["Uptime"].to_i
          {
            server: server_block(version, uptime_seconds),
            connections: connections_block(status, vars),
            innodb: innodb_block(status, vars),
            queries: queries_block(status, uptime_seconds),
          }
        end

        private

        def load_status
          result = @connection.exec_query("SHOW GLOBAL STATUS")
          result.to_hashes.each_with_object({}) do |row, acc|
            name = (row["Variable_name"] || row["variable_name"]).to_s
            value = (row["Value"] || row["value"]).to_s
            acc[name] = value
          end
        end

        def load_variables
          result = @connection.exec_query("SHOW GLOBAL VARIABLES")
          result.to_hashes.each_with_object({}) do |row, acc|
            name = (row["Variable_name"] || row["variable_name"]).to_s
            value = (row["Value"] || row["value"]).to_s
            acc[name] = value
          end
        end

        def server_block(version, uptime_seconds)
          days = uptime_seconds / 86_400
          hours = (uptime_seconds % 86_400) / 3600
          minutes = (uptime_seconds % 3600) / 60

          {
            version: version,
            uptime: "#{days}d #{hours}h #{minutes}m",
            uptime_seconds: uptime_seconds,
          }
        end

        def connections_block(status, vars)
          max_conn = vars["max_connections"].to_i
          current_conn = status["Threads_connected"].to_i
          usage_pct = max_conn.positive? ? ((current_conn.to_f / max_conn) * 100).round(1) : 0

          {
            max: max_conn,
            current: current_conn,
            usage_pct: usage_pct,
            threads_running: status["Threads_running"].to_i,
            threads_cached: status["Threads_cached"].to_i,
            threads_created: status["Threads_created"].to_i,
            aborted_connects: status["Aborted_connects"].to_i,
            aborted_clients: status["Aborted_clients"].to_i,
            max_used: status["Max_used_connections"].to_i,
          }
        end

        def innodb_block(status, vars)
          buffer_pool_bytes = vars["innodb_buffer_pool_size"].to_i
          buffer_pool_mb = (buffer_pool_bytes / 1024.0 / 1024.0).round(1)

          reads = status["Innodb_buffer_pool_read_requests"].to_f
          disk_reads = status["Innodb_buffer_pool_reads"].to_f
          hit_rate = reads.positive? ? (((reads - disk_reads) / reads) * 100).round(2) : 0

          {
            buffer_pool_mb: buffer_pool_mb,
            buffer_pool_hit_rate: hit_rate,
            buffer_pool_pages_dirty: status["Innodb_buffer_pool_pages_dirty"].to_i,
            buffer_pool_pages_free: status["Innodb_buffer_pool_pages_free"].to_i,
            buffer_pool_pages_total: status["Innodb_buffer_pool_pages_total"].to_i,
            row_lock_waits: status["Innodb_row_lock_waits"].to_i,
            row_lock_time_ms: status["Innodb_row_lock_time"].to_f.round(0),
          }
        end

        def queries_block(status, uptime_seconds)
          tmp_tables = status["Created_tmp_tables"].to_i
          tmp_disk_tables = status["Created_tmp_disk_tables"].to_i
          tmp_disk_pct = tmp_tables.positive? ? ((tmp_disk_tables.to_f / tmp_tables) * 100).round(1) : 0

          questions = status["Questions"].to_i
          qps = uptime_seconds.positive? ? (questions.to_f / uptime_seconds).round(1) : 0

          {
            questions: questions,
            qps: qps,
            slow_queries: status["Slow_queries"].to_i,
            tmp_tables: tmp_tables,
            tmp_disk_tables: tmp_disk_tables,
            tmp_disk_pct: tmp_disk_pct,
            select_full_join: status["Select_full_join"].to_i,
            sort_merge_passes: status["Sort_merge_passes"].to_i,
          }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Require from `core.rb`**

Append to `gems/mysql_genius-core/lib/mysql_genius/core.rb`:

```ruby
require "mysql_genius/core/analysis/server_overview"
```

- [ ] **Step 5: Run spec, verify pass**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/analysis/server_overview_spec.rb 2>&1 | tail -10
```

Expected: 5 examples, 0 failures.

- [ ] **Step 6: Update the `server_overview` concern action**

In `app/controllers/concerns/mysql_genius/database_analysis.rb`, replace the entire `server_overview` method (lines 210-293) with:

```ruby
    def server_overview
      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      overview = MysqlGenius::Core::Analysis::ServerOverview.new(connection).call
      render(json: overview)
    rescue => e
      render(json: { error: "Failed to load server overview: #{e.message}" }, status: :unprocessable_entity)
    end
```

- [ ] **Step 7: Run both suites**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius && bundle exec rspec 2>&1 | tail -5
cd /Users/abyrd/Code/GitHub/mysql_genius/gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -5
```

Expected: both green. The `DatabaseAnalysis` concern is now fully delegated for all 5 analyses.

- [ ] **Step 8: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Extract ServerOverview analysis into mysql_genius-core

Move SHOW GLOBAL STATUS / SHOW GLOBAL VARIABLES / SELECT VERSION()
collection and derived-metric computation out of the DatabaseAnalysis
concern into a new MysqlGenius::Core::Analysis::ServerOverview class.
Structure the output into server/connections/innodb/queries blocks
with the same keys and types as before.

This completes the 5-analysis extraction. DatabaseAnalysis concern
is now fully delegated to core; the concern's 5 actions have
shrunk from 295 lines of inline SQL and transformations to
short delegating wrappers.
EOF
)"
```

---

## Stage B — Extract `QueryRunner` and `QueryExplainer`

Stage B extracts the query execution path from the `QueryExecution` concern. `execute` becomes `QueryRunner#run`, `explain` becomes `QueryExplainer#explain`. Both take a new `Core::QueryRunner::Config` struct for per-request configuration. `QueryRunner` returns a new `Core::ExecutionResult` value object.

### Task 6: Create `Core::ExecutionResult` value object

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/execution_result_spec.rb`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/execution_result.rb`
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`

- [ ] **Step 1: Write the failing spec**

Write `gems/mysql_genius-core/spec/mysql_genius/core/execution_result_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run spec, verify fail**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/execution_result_spec.rb 2>&1 | tail -10
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::ExecutionResult`.

- [ ] **Step 3: Implement `ExecutionResult`**

Write `gems/mysql_genius-core/lib/mysql_genius/core/execution_result.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    # Immutable frozen value object returned from Core::QueryRunner#run.
    # Contains the executed columns and (possibly masked) rows plus runtime
    # metrics: row count, wall-clock execution time in milliseconds, and a
    # truncated flag indicating whether the row count reached the applied
    # LIMIT.
    #
    # This is distinct from Core::Result (which models a plain query result
    # shape) because QueryRunner returns runtime metadata that plain results
    # don't carry.
    class ExecutionResult
      attr_reader :columns, :rows, :row_count, :execution_time_ms, :truncated

      def initialize(columns:, rows:, execution_time_ms:, truncated:)
        @columns = columns.freeze
        @rows = rows.freeze
        @row_count = rows.length
        @execution_time_ms = execution_time_ms
        @truncated = truncated
        freeze
      end
    end
  end
end
```

- [ ] **Step 4: Require from `core.rb`**

Append to `gems/mysql_genius-core/lib/mysql_genius/core.rb`:

```ruby
require "mysql_genius/core/execution_result"
```

- [ ] **Step 5: Run spec, verify pass**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/execution_result_spec.rb 2>&1 | tail -10
```

Expected: 4 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Add Core::ExecutionResult value object

Immutable frozen value object returned from Core::QueryRunner#run
(to be added in the next task). Contains columns, rows (post-masking),
row_count, execution_time_ms, and a truncated flag. Distinct from
Core::Result because it carries runtime metadata that plain results
don't need.
EOF
)"
```

---

### Task 7: Create `Core::QueryRunner::Config` struct

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/query_runner/config_spec.rb`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/query_runner/config.rb`
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`

- [ ] **Step 1: Create directories and write the failing spec**

```bash
mkdir -p gems/mysql_genius-core/spec/mysql_genius/core/query_runner
mkdir -p gems/mysql_genius-core/lib/mysql_genius/core/query_runner
```

Write `gems/mysql_genius-core/spec/mysql_genius/core/query_runner/config_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run spec, verify fail**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/query_runner/config_spec.rb 2>&1 | tail -10
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::QueryRunner`.

- [ ] **Step 3: Create the placeholder `QueryRunner` module and the `Config` struct**

We need `MysqlGenius::Core::QueryRunner` namespace to exist before `QueryRunner::Config` can be defined. Write `gems/mysql_genius-core/lib/mysql_genius/core/query_runner/config.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    # Forward declaration so Config can be namespaced under QueryRunner.
    # The full QueryRunner class is defined in query_runner.rb.
    class QueryRunner
      Config = Struct.new(
        :blocked_tables,
        :masked_column_patterns,
        :query_timeout_ms,
        keyword_init: true,
      ) do
        def initialize(*)
          super
          freeze
        end
      end
    end
  end
end
```

- [ ] **Step 4: Require from `core.rb`**

Append to `gems/mysql_genius-core/lib/mysql_genius/core.rb`:

```ruby
require "mysql_genius/core/query_runner/config"
```

Note: this must be required BEFORE `mysql_genius/core/query_runner` (added in the next task) since `query_runner.rb` reopens the class and Config should already exist.

- [ ] **Step 5: Run spec, verify pass**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/query_runner/config_spec.rb 2>&1 | tail -10
```

Expected: 2 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Add Core::QueryRunner::Config keyword-init Struct

Holds the runner-specific subset of MysqlGenius::Configuration:
blocked_tables, masked_column_patterns, query_timeout_ms.
Frozen on initialize for defensive immutability.

Forward-declares the QueryRunner class so Config can be namespaced
under it. The full QueryRunner implementation lands in the next
task.
EOF
)"
```

---

### Task 8: Implement `Core::QueryRunner`

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/query_runner_spec.rb`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/query_runner.rb`
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`
- Modify: `app/controllers/concerns/mysql_genius/query_execution.rb` (execute method)

- [ ] **Step 1: Write the failing spec**

Write `gems/mysql_genius-core/spec/mysql_genius/core/query_runner_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::QueryRunner) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:config) do
    MysqlGenius::Core::QueryRunner::Config.new(
      blocked_tables: ["sessions"],
      masked_column_patterns: ["password", "token"],
      query_timeout_ms: 30_000,
    )
  end
  subject(:runner) { described_class.new(connection, config) }

  before do
    connection.stub_tables(["users", "posts"])
    connection.stub_server_version("8.0.35")
  end

  describe "#run" do
    it "executes a valid SELECT and returns an ExecutionResult" do
      connection.stub_query(
        /SELECT.*FROM users/i,
        columns: ["id", "name"],
        rows: [[1, "Alice"]],
      )

      result = runner.run("SELECT id, name FROM users", row_limit: 25)

      expect(result).to(be_a(MysqlGenius::Core::ExecutionResult))
      expect(result.columns).to(eq(["id", "name"]))
      expect(result.rows).to(eq([[1, "Alice"]]))
      expect(result.row_count).to(eq(1))
      expect(result.execution_time_ms).to(be_a(Float))
      expect(result.execution_time_ms).to(be >= 0)
      expect(result.truncated).to(be(false))
    end

    it "raises Rejected for a non-SELECT statement" do
      expect { runner.run("DROP TABLE users", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /Only SELECT/))
    end

    it "raises Rejected for a blocked table" do
      expect { runner.run("SELECT * FROM sessions", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /sessions/))
    end

    it "raises Rejected for an empty SQL string" do
      expect { runner.run("", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /Please enter/))
    end

    it "applies the row limit to queries without an existing LIMIT" do
      captured_sql = nil
      connection.stub_query(/SELECT/, columns: ["id"], rows: [[1]])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      runner.run("SELECT id FROM users", row_limit: 25)
      expect(captured_sql).to(match(/LIMIT 25/))
    end

    it "masks columns matching configured patterns with [REDACTED]" do
      connection.stub_query(
        /SELECT/,
        columns: ["id", "encrypted_password", "email"],
        rows: [[1, "hash123", "alice@example.com"]],
      )

      result = runner.run("SELECT id, encrypted_password, email FROM users", row_limit: 25)

      expect(result.rows).to(eq([[1, "[REDACTED]", "alice@example.com"]]))
    end

    it "masks multiple columns matching different patterns" do
      connection.stub_query(
        /SELECT/,
        columns: ["id", "api_token", "reset_password_digest"],
        rows: [[1, "tok_abc", "digest_xyz"]],
      )

      result = runner.run("SELECT id, api_token, reset_password_digest FROM users", row_limit: 25)

      expect(result.rows).to(eq([[1, "[REDACTED]", "[REDACTED]"]]))
    end

    it "sets truncated=true when row count reaches the row_limit" do
      connection.stub_query(
        /SELECT/,
        columns: ["id"],
        rows: [[1], [2], [3]],
      )

      result = runner.run("SELECT id FROM users", row_limit: 3)

      expect(result.truncated).to(be(true))
    end

    it "wraps SELECT with MAX_EXECUTION_TIME hint on MySQL" do
      captured_sql = nil
      connection.stub_server_version("8.0.35")
      connection.stub_query(/SELECT/, columns: ["id"], rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      runner.run("SELECT id FROM users", row_limit: 25)
      expect(captured_sql).to(include("MAX_EXECUTION_TIME(30000)"))
    end

    it "wraps SELECT with SET STATEMENT max_statement_time on MariaDB" do
      captured_sql = nil
      connection.stub_server_version("10.11.5-MariaDB")
      connection.stub_query(/SELECT/, columns: ["id"], rows: [])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      runner.run("SELECT id FROM users", row_limit: 25)
      expect(captured_sql).to(match(/SET STATEMENT max_statement_time=30 FOR/))
    end

    it "raises Timeout when the database reports a statement timeout" do
      connection.stub_query(
        /SELECT/,
        raises: StandardError.new("Query execution was interrupted, max_statement_time exceeded"),
      )

      expect { runner.run("SELECT id FROM users", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Timeout))
    end

    it "raises Timeout when the error message mentions max_execution_time" do
      connection.stub_query(
        /SELECT/,
        raises: StandardError.new("max_execution_time exceeded"),
      )

      expect { runner.run("SELECT id FROM users", row_limit: 25) }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Timeout))
    end

    it "propagates non-timeout database errors" do
      connection.stub_query(
        /SELECT/,
        raises: StandardError.new("ERROR 1146 (42S02): Table 'app.nonexistent' doesn't exist"),
      )

      expect { runner.run("SELECT id FROM users", row_limit: 25) }
        .to(raise_error(StandardError, /nonexistent/))
    end
  end
end
```

- [ ] **Step 2: Run spec, verify fail**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/query_runner_spec.rb 2>&1 | tail -10
```

Expected: FAIL with multiple errors — `Rejected`, `Timeout`, `run` method missing.

- [ ] **Step 3: Implement `Core::QueryRunner`**

Write `gems/mysql_genius-core/lib/mysql_genius/core/query_runner.rb`:

```ruby
# frozen_string_literal: true

require "set"

module MysqlGenius
  module Core
    # Runs SELECT queries against a Core::Connection with SQL validation,
    # row-limit application, timeout hints (MySQL or MariaDB flavor), and
    # column masking. Returns a Core::ExecutionResult on success or raises
    # a specific error class on failure.
    #
    # Does NOT handle audit logging — the caller (Rails concern or future
    # desktop sidecar) is responsible for recording successful queries and
    # errors using whatever logger it owns.
    class QueryRunner
      class Rejected < Core::Error; end
      class Timeout < Core::Error; end

      TIMEOUT_PATTERNS = [
        "max_statement_time",
        "max_execution_time",
        "Query execution was interrupted",
      ].freeze

      def initialize(connection, config)
        @connection = connection
        @config = config
      end

      def run(sql, row_limit:)
        validation_error = SqlValidator.validate(
          sql,
          blocked_tables: @config.blocked_tables,
          connection: @connection,
        )
        raise Rejected, validation_error if validation_error

        limited = SqlValidator.apply_row_limit(sql, row_limit)
        timed = apply_timeout_hint(limited)

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = begin
          @connection.exec_query(timed)
        rescue StandardError => e
          raise Timeout, e.message if timeout_error?(e)

          raise
        end
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

        masked_rows = mask_rows(result)

        ExecutionResult.new(
          columns: result.columns,
          rows: masked_rows,
          execution_time_ms: duration_ms,
          truncated: masked_rows.length >= row_limit,
        )
      end

      private

      def apply_timeout_hint(sql)
        if mariadb?
          timeout_seconds = @config.query_timeout_ms / 1000
          "SET STATEMENT max_statement_time=#{timeout_seconds} FOR #{sql}"
        else
          sql.sub(/\bSELECT\b/i, "SELECT /*+ MAX_EXECUTION_TIME(#{@config.query_timeout_ms}) */")
        end
      end

      def mariadb?
        @connection.server_version.mariadb?
      end

      def mask_rows(result)
        mask_indices = result.columns.each_with_index.select do |name, _i|
          SqlValidator.masked_column?(name, @config.masked_column_patterns)
        end.map { |(_name, i)| i }.to_set

        return result.rows if mask_indices.empty?

        result.rows.map do |row|
          row.each_with_index.map { |value, i| mask_indices.include?(i) ? "[REDACTED]" : value }
        end
      end

      def timeout_error?(exception)
        msg = exception.message
        TIMEOUT_PATTERNS.any? { |pattern| msg.include?(pattern) }
      end
    end
  end
end
```

`require "set"` at the top is needed because `mask_rows` uses `Set` via `.to_set` for O(1) column-index lookups.

- [ ] **Step 4: Require from `core.rb`**

Append to `gems/mysql_genius-core/lib/mysql_genius/core.rb` (after `query_runner/config`):

```ruby
require "mysql_genius/core/query_runner"
```

- [ ] **Step 5: Run spec, verify pass**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/query_runner_spec.rb 2>&1 | tail -15
```

Expected: 13 examples, 0 failures.

- [ ] **Step 6: Update the `execute` concern action**

In `app/controllers/concerns/mysql_genius/query_execution.rb`, replace the entire `execute` method with:

```ruby
    def execute
      sql = params[:sql].to_s.strip
      row_limit = if params[:row_limit].present?
        params[:row_limit].to_i.clamp(1, mysql_genius_config.max_row_limit)
      else
        mysql_genius_config.default_row_limit
      end

      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      runner_config = MysqlGenius::Core::QueryRunner::Config.new(
        blocked_tables: mysql_genius_config.blocked_tables,
        masked_column_patterns: mysql_genius_config.masked_column_patterns,
        query_timeout_ms: mysql_genius_config.query_timeout_ms,
      )
      runner = MysqlGenius::Core::QueryRunner.new(connection, runner_config)

      begin
        result = runner.run(sql, row_limit: row_limit)
      rescue MysqlGenius::Core::QueryRunner::Rejected => e
        audit(:rejection, sql: sql, reason: e.message)
        return render(json: { error: e.message }, status: :unprocessable_entity)
      rescue MysqlGenius::Core::QueryRunner::Timeout
        audit(:error, sql: sql, error: "Query timeout")
        return render(json: { error: "Query exceeded the #{mysql_genius_config.query_timeout_ms / 1000} second timeout limit.", timeout: true }, status: :unprocessable_entity)
      rescue ActiveRecord::StatementInvalid => e
        audit(:error, sql: sql, error: e.message)
        return render(json: { error: "Query error: #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
      end

      audit(:query, sql: sql, execution_time_ms: result.execution_time_ms, row_count: result.row_count)

      render(json: {
        columns: result.columns,
        rows: result.rows,
        row_count: result.row_count,
        execution_time_ms: result.execution_time_ms,
        truncated: result.truncated,
      })
    end
```

- [ ] **Step 7: Remove the now-unused helpers from `query_execution.rb`**

The extracted `QueryRunner` subsumes `validate_sql`, `apply_timeout_hint`, `mariadb?`, `apply_row_limit`, `timeout_error?`, and `masked_column?` from the concern. Those helpers were only called by `execute`. But `explain` (in the next task) still uses `validate_sql` — so wait for the `QueryExplainer` task before removing them.

For now, leave the private helpers in place. They'll be cleaned up in Task 9 when `QueryExplainer` replaces the last consumer.

- [ ] **Step 8: Run both suites**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius && bundle exec rspec 2>&1 | tail -5
cd /Users/abyrd/Code/GitHub/mysql_genius/gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -5
```

Expected: both green.

- [ ] **Step 9: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Extract QueryRunner into mysql_genius-core

Core::QueryRunner owns SQL validation, row-limit application,
timeout-hint wrapping (MySQL vs MariaDB flavors), execution, column
masking, and timeout detection. Returns a Core::ExecutionResult
or raises Rejected / Timeout. Does NOT handle audit logging —
the concern still owns that.

The execute action in the QueryExecution concern now parses params,
builds an ActiveRecordAdapter and a QueryRunner::Config, calls
runner.run, and catches the specific error classes to produce the
same JSON response shapes as before. Rails-specific ActiveRecord
error translation stays in the concern.

Helpers validate_sql / apply_timeout_hint / mariadb? / apply_row_limit /
timeout_error? / masked_column? stay in the concern temporarily
because explain still uses validate_sql — they're removed in Task 9
when QueryExplainer replaces that last consumer.

13 new core specs cover happy-path execution, each rejection reason,
row limit application, column masking (single and multiple
patterns), truncation detection, MySQL vs MariaDB timeout hints,
timeout detection via error message, and non-timeout error
propagation.
EOF
)"
```

---

### Task 9: Implement `Core::QueryExplainer`

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/query_explainer_spec.rb`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/query_explainer.rb`
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`
- Modify: `app/controllers/concerns/mysql_genius/query_execution.rb` (explain method and remove unused helpers)

- [ ] **Step 1: Write the failing spec**

Write `gems/mysql_genius-core/spec/mysql_genius/core/query_explainer_spec.rb`:

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::QueryExplainer) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:config) do
    MysqlGenius::Core::QueryRunner::Config.new(
      blocked_tables: ["sessions"],
      masked_column_patterns: [],
      query_timeout_ms: 30_000,
    )
  end
  subject(:explainer) { described_class.new(connection, config) }

  before do
    connection.stub_tables(["users", "posts"])
  end

  describe "#explain" do
    it "returns a Core::Result for a valid SELECT" do
      connection.stub_query(
        /EXPLAIN SELECT/,
        columns: ["id", "select_type", "table", "type"],
        rows: [[1, "SIMPLE", "users", "ALL"]],
      )

      result = explainer.explain("SELECT id FROM users")

      expect(result).to(be_a(MysqlGenius::Core::Result))
      expect(result.columns).to(eq(["id", "select_type", "table", "type"]))
      expect(result.rows).to(eq([[1, "SIMPLE", "users", "ALL"]]))
    end

    it "raises Rejected for a non-SELECT query" do
      expect { explainer.explain("DELETE FROM users") }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /Only SELECT/))
    end

    it "raises Rejected for a blocked table" do
      expect { explainer.explain("SELECT * FROM sessions") }
        .to(raise_error(MysqlGenius::Core::QueryRunner::Rejected, /sessions/))
    end

    it "skips validation when skip_validation: true" do
      # Even a query that would normally fail (non-SELECT) is attempted
      # when skip_validation is true — this is used for explaining captured
      # slow queries from mysql's own logs.
      connection.stub_query(/EXPLAIN SELECT/, columns: ["id"], rows: [[1]])

      expect { explainer.explain("SELECT id FROM users", skip_validation: true) }
        .not_to(raise_error)
    end

    it "raises Truncated when the SQL appears to be cut mid-statement" do
      expect { explainer.explain("SELECT id, name FROM users WHERE", skip_validation: true) }
        .to(raise_error(MysqlGenius::Core::QueryExplainer::Truncated, /truncated/))
    end

    it "accepts SQL ending with a closing paren" do
      connection.stub_query(/EXPLAIN/, columns: ["id"], rows: [[1]])

      expect { explainer.explain("SELECT id FROM (SELECT id FROM users)", skip_validation: true) }
        .not_to(raise_error)
    end

    it "accepts SQL ending with a number" do
      connection.stub_query(/EXPLAIN/, columns: ["id"], rows: [[1]])

      expect { explainer.explain("SELECT id FROM users LIMIT 10", skip_validation: true) }
        .not_to(raise_error)
    end

    it "accepts SQL ending with a closing quote" do
      connection.stub_query(/EXPLAIN/, columns: ["id"], rows: [[1]])

      expect { explainer.explain("SELECT id FROM users WHERE name = 'alice'", skip_validation: true) }
        .not_to(raise_error)
    end

    it "strips a trailing semicolon before wrapping in EXPLAIN" do
      captured_sql = nil
      connection.stub_query(/EXPLAIN/, columns: ["id"], rows: [[1]])
      allow(connection).to(receive(:exec_query).and_wrap_original do |original, sql, **kwargs|
        captured_sql = sql
        original.call(sql, **kwargs)
      end)

      explainer.explain("SELECT id FROM users;")
      expect(captured_sql).to(eq("EXPLAIN SELECT id FROM users"))
    end
  end
end
```

- [ ] **Step 2: Run spec, verify fail**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/query_explainer_spec.rb 2>&1 | tail -10
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::QueryExplainer`.

- [ ] **Step 3: Implement `Core::QueryExplainer`**

Write `gems/mysql_genius-core/lib/mysql_genius/core/query_explainer.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    # Runs EXPLAIN against a SELECT query via a Core::Connection. Optionally
    # skips SQL validation (used for explaining captured slow queries from
    # mysql's own logs where the exact text may include references to
    # otherwise-blocked tables).
    #
    # Rejects obviously-truncated SQL — captured slow queries from the
    # slow query log are capped at ~2000 characters, so if the last
    # character doesn't look like a valid terminator we refuse to try.
    # This avoids confusing EXPLAIN errors from partial statements.
    #
    # Reuses Core::QueryRunner::Rejected for validation failures so
    # callers can rescue one error type for both runners.
    class QueryExplainer
      class Truncated < Core::Error; end

      def initialize(connection, config)
        @connection = connection
        @config = config
      end

      def explain(sql, skip_validation: false)
        unless skip_validation
          error = SqlValidator.validate(
            sql,
            blocked_tables: @config.blocked_tables,
            connection: @connection,
          )
          raise QueryRunner::Rejected, error if error
        end

        unless looks_complete?(sql)
          raise Truncated, "This query appears to be truncated and cannot be explained."
        end

        explain_sql = "EXPLAIN #{sql.gsub(/;\s*\z/, "")}"
        @connection.exec_query(explain_sql)
      end

      private

      # Heuristic: the final non-whitespace character should be one of
      # ) (closing paren), a word character, a closing quote, or a digit.
      def looks_complete?(sql)
        sql.match?(/\)\s*$/) || sql.match?(/\w\s*$/) || sql.match?(/['"`]\s*$/) || sql.match?(/\d\s*$/)
      end
    end
  end
end
```

- [ ] **Step 4: Require from `core.rb`**

Append to `gems/mysql_genius-core/lib/mysql_genius/core.rb`:

```ruby
require "mysql_genius/core/query_explainer"
```

- [ ] **Step 5: Run spec, verify pass**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/query_explainer_spec.rb 2>&1 | tail -10
```

Expected: 9 examples, 0 failures.

- [ ] **Step 6: Update the `explain` concern action and remove unused helpers**

In `app/controllers/concerns/mysql_genius/query_execution.rb`, replace the entire `explain` method with:

```ruby
    def explain
      sql = params[:sql].to_s.strip
      skip_validation = params[:from_slow_query] == "true"

      connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
      runner_config = MysqlGenius::Core::QueryRunner::Config.new(
        blocked_tables: mysql_genius_config.blocked_tables,
        masked_column_patterns: mysql_genius_config.masked_column_patterns,
        query_timeout_ms: mysql_genius_config.query_timeout_ms,
      )
      explainer = MysqlGenius::Core::QueryExplainer.new(connection, runner_config)

      result = explainer.explain(sql, skip_validation: skip_validation)
      render(json: { columns: result.columns, rows: result.rows })
    rescue MysqlGenius::Core::QueryRunner::Rejected,
           MysqlGenius::Core::QueryExplainer::Truncated => e
      render(json: { error: e.message }, status: :unprocessable_entity)
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Explain error: #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end
```

Now remove the private helpers that are no longer used. The extracted `Core::QueryRunner` and `Core::QueryExplainer` subsume them entirely.

In the same file, delete these six methods from the `private` section: `validate_sql`, `apply_timeout_hint`, `mariadb?`, `apply_row_limit`, `timeout_error?`, `masked_column?`.

Keep `sanitize_ai_sql` and `audit` in the `private` section — `sanitize_ai_sql` is still called by `suggest` in the `AiFeatures` concern (private methods are shared across all concerns included in the same controller, so its placement in `query_execution.rb` is fine), and `audit` is still called by the `execute` action after the `QueryRunner` refactor in Task 8.

The final `private` section of `query_execution.rb` should look exactly like this:

```ruby
    private

    def sanitize_ai_sql(sql)
      sql.gsub(/```(?:sql)?\s*/i, "").gsub("```", "").strip
    end

    def audit(type, **attrs)
      logger = mysql_genius_config.audit_logger
      return unless logger

      prefix = "[#{Time.current.iso8601}] [mysql_genius]"
      case type
      when :query
        logger.info("#{prefix} rows=#{attrs[:row_count]} time=#{attrs[:execution_time_ms]}ms sql=#{attrs[:sql].squish}")
      when :rejection
        logger.warn("#{prefix} REJECTED reason=#{attrs[:reason]} sql=#{attrs[:sql].to_s.squish}")
      when :error
        logger.error("#{prefix} ERROR error=#{attrs[:error]} sql=#{attrs[:sql].to_s.squish}")
      end
    end
```

- [ ] **Step 7: Run both suites**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius && bundle exec rspec 2>&1 | tail -5
cd /Users/abyrd/Code/GitHub/mysql_genius/gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -5
```

Expected: both green.

- [ ] **Step 8: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Extract QueryExplainer into mysql_genius-core + clean up concern helpers

Core::QueryExplainer wraps EXPLAIN around validated SELECT queries,
with an optional skip_validation flag for explaining captured slow
queries from mysql's own logs. Reuses Core::QueryRunner::Rejected
for validation failures and adds a new Core::QueryExplainer::Truncated
class for SQL that appears cut mid-statement.

The explain action in the QueryExecution concern now builds an
ActiveRecordAdapter + Config and delegates. The concern's private
helpers validate_sql, apply_timeout_hint, mariadb?, apply_row_limit,
timeout_error?, and masked_column? are deleted — they were the
internal plumbing that is now owned by Core::QueryRunner and
Core::QueryExplainer. sanitize_ai_sql and audit remain because
they're used elsewhere in the controller.

This completes Stage B and all code extraction for Phase 1b. The
next stage is the paired release to rubygems.
EOF
)"
```

---

## Stage C — Paired release

Stage C does the operational work for releasing `mysql_genius-core 0.1.0` alongside `mysql_genius 0.4.0`: updating the publish workflow to handle two gems, bumping versions, flipping the CHANGELOG, committing, tagging, and watching the release.

### Task 10: Update the publish workflow to build and push both gems

**Files:**
- Modify: `.github/workflows/publish.yml`

- [ ] **Step 1: Read the current workflow and plan the update**

The current workflow has a `publish` job with two steps: `gem build mysql_genius.gemspec` and `gem push mysql_genius-*.gem`. It needs two new steps inserted before those to build and push `mysql_genius-core` first. The order matters: `mysql_genius-core` must be on rubygems before `mysql_genius` so the dependency resolves at `gem install` time.

- [ ] **Step 2: Rewrite `publish.yml`**

Replace the entire contents of `.github/workflows/publish.yml` with:

```yaml
name: Publish to RubyGems

on:
  push:
    tags: ["v*"]
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.3
          bundler-cache: true
      - run: bundle exec rspec
      - name: Test mysql_genius-core gem
        working-directory: gems/mysql_genius-core
        run: |
          bundle install
          bundle exec rspec

  publish:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.3

      # Build and push mysql_genius-core FIRST so that mysql_genius's
      # runtime dependency on it can resolve at gem install time.
      - name: Build mysql_genius-core
        working-directory: gems/mysql_genius-core
        run: gem build mysql_genius-core.gemspec

      - name: Publish mysql_genius-core
        working-directory: gems/mysql_genius-core
        run: gem push mysql_genius-core-*.gem
        env:
          GEM_HOST_API_KEY: ${{ secrets.RUBYGEMS_API_KEY }}

      - name: Build mysql_genius
        run: gem build mysql_genius.gemspec

      - name: Publish mysql_genius
        run: gem push mysql_genius-*.gem
        env:
          GEM_HOST_API_KEY: ${{ secrets.RUBYGEMS_API_KEY }}
```

Notes on the design:
- The `test` job now runs `bundle exec rspec` at the root (Rails adapter specs) AND in `gems/mysql_genius-core` (core specs). Both must pass before publishing.
- The `publish` job's steps use `working-directory` to isolate the core gem's build and push to its subdirectory. This avoids the risk of `gem push mysql_genius-*.gem` at the root matching `mysql_genius-core-*.gem` if both were built in the same directory.
- `mysql_genius-core` is built and pushed before `mysql_genius`. If the core push fails, the main gem push doesn't run, avoiding a broken release.

- [ ] **Step 3: Verify the YAML is valid**

```bash
ruby -ryaml -e "YAML.load_file('.github/workflows/publish.yml'); puts 'valid'"
```

Expected: `valid`.

- [ ] **Step 4: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add .github/workflows/publish.yml
git commit -m "$(cat <<'EOF'
Update publish workflow to release mysql_genius-core + mysql_genius

The workflow now builds and publishes mysql_genius-core first,
then mysql_genius, so the runtime dependency on mysql_genius-core
resolves at gem install time. The test job also runs the core
gem's spec suite to ensure it passes before publishing anything.

working-directory is used to keep the core gem's build artifacts
in gems/mysql_genius-core/ so the root-level "gem push
mysql_genius-*.gem" glob matches only the Rails adapter gem and
not the core gem.
EOF
)"
```

---

### Task 11: Bump versions, update gemspec dep, flip CHANGELOG

**Files:**
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core/version.rb`
- Modify: `lib/mysql_genius/version.rb`
- Modify: `mysql_genius.gemspec`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Bump `mysql_genius-core` version**

Edit `gems/mysql_genius-core/lib/mysql_genius/core/version.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    VERSION = "0.1.0"
  end
end
```

(Drop the `.pre` suffix.)

- [ ] **Step 2: Bump `mysql_genius` version**

Edit `lib/mysql_genius/version.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  VERSION = "0.4.0"
end
```

- [ ] **Step 3: Update the gemspec dependency**

Edit `mysql_genius.gemspec` and change the dependency line from:

```ruby
  spec.add_dependency("mysql_genius-core", "~> 0.1.0.pre")
```

to:

```ruby
  spec.add_dependency("mysql_genius-core", "~> 0.1")
```

The `~> 0.1` pessimistic constraint allows any `0.x` version ≥ `0.1.0` but < `1.0`, giving us room to release `0.1.1`, `0.2.0`, etc. without touching the adapter's gemspec.

- [ ] **Step 4: Flip `CHANGELOG.md` to 0.4.0**

Edit `CHANGELOG.md` — change the top `## Unreleased` header to `## 0.4.0`, and add Phase 1b-specific bullets. Replace the entire top section (from `## Unreleased` through the end of its last bullet) with:

```markdown
## 0.4.0

### Changed
- **Internal refactor: extracted Rails-free core library into a new `mysql_genius-core` gem.** The validator, AI services, value objects, database analyses, query runner, and query explainer now live in `mysql_genius-core`; the `mysql_genius` Rails engine delegates through a new `Core::Connection::ActiveRecordAdapter`. Public API, routes, config DSL, and JSON response shapes are unchanged — host apps see no difference after `bundle update`. See [the design spec](docs/superpowers/specs/2026-04-10-desktop-app-design.md) for the motivation: the new core gem is the foundation for a forthcoming `mysql_genius-desktop` standalone app.
- `mysql_genius` now declares a runtime dependency on `mysql_genius-core ~> 0.1`. This dependency resolves transitively; host apps do not need to add it to their Gemfile.
- `MysqlGenius::SqlValidator` moved to `MysqlGenius::Core::SqlValidator`.
- `MysqlGenius::AiClient`, `MysqlGenius::AiSuggestionService`, `MysqlGenius::AiOptimizationService` moved to `MysqlGenius::Core::Ai::{Client, Suggestion, Optimization}` and now take an explicit `Core::Ai::Config` instead of reading `MysqlGenius.configuration` at construction time.
- The 5 database analyses (`table_sizes`, `duplicate_indexes`, `query_stats`, `unused_indexes`, `server_overview`) moved from the `DatabaseAnalysis` controller concern into `MysqlGenius::Core::Analysis::*` classes, each taking a `Core::Connection`.
- `MysqlGenius::Core::QueryRunner` now owns SQL validation, row-limit application, timeout-hint wrapping (MySQL / MariaDB flavors), execution, column masking, and timeout detection. The `execute` controller action delegates to it. Audit logging stays in the Rails adapter.
- `MysqlGenius::Core::QueryExplainer` now owns the EXPLAIN path with optional validation-skipping for captured slow queries. The `explain` controller action delegates to it.

### Documentation
- Added README troubleshooting section covering `SSL_connect ... EC lib` / `unable to decode issuer public key` errors that hit Ruby 2.7 + OpenSSL 1.1.x users talking to Google Trust Services-backed hosts like Ollama Cloud. Recommends local Ollama (`http://localhost:11434`) as the fastest unblock, `SSL_CERT_FILE` pointing at a fresher CA bundle as an intermediate fix, and upgrading to Ruby 3.2+ as the durable fix.
- Added `docs/superpowers/specs/2026-04-10-desktop-app-design.md` — the full design spec for the eventual `mysql_genius-desktop` standalone app.
```

Leave everything below untouched (the `## 0.3.2`, `## 0.3.1`, `## 0.3.0`, ... sections).

- [ ] **Step 5: Verify everything still works after the bumps**

```bash
bundle install 2>&1 | tail -3
bundle exec rspec 2>&1 | tail -5
cd gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -5 && cd ..
```

Expected: bundle resolves with the new versions. Both suites green.

- [ ] **Step 6: Commit**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git add -A
git commit -m "$(cat <<'EOF'
Bump versions for 0.4.0 paired release

- mysql_genius-core: 0.1.0.pre -> 0.1.0
- mysql_genius: 0.3.2 -> 0.4.0
- mysql_genius.gemspec dep: "~> 0.1.0.pre" -> "~> 0.1"
- CHANGELOG.md: ## Unreleased -> ## 0.4.0 with Phase 1b additions

The next commit tags v0.4.0 and kicks off the publish workflow,
which will push mysql_genius-core 0.1.0 first and then
mysql_genius 0.4.0 to rubygems.
EOF
)"
```

---

### Task 12: Tag v0.4.0 and trigger release

**Files:**
- None modified; this task does git operations only.

- [ ] **Step 1: Verify main is in a clean state and tests are green**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git status
bundle exec rspec 2>&1 | tail -3
cd gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -3 && cd ..
```

Expected: clean working tree (or only the Phase 1b changes staged/committed), both suites green.

- [ ] **Step 2: Merge the feature branch to main**

At this point, Phase 1b is ready to land. You have two choices depending on your merge preferences:

**Option A (recommended for large multi-stage branches like this):** Rebase and merge via GitHub PR so each of the 12 Phase 1b task commits lands on main linearly, preserving bisect history.

**Option B:** Squash and merge into one `Phase 1b (#N)` commit.

For either option, you'll need to open PR first:

```bash
git push -u origin feature/mysql-genius-core-phase-1b
gh pr create --title "Phase 1b: Extract analyses, QueryRunner, QueryExplainer + 0.4.0 release" \
  --body "$(cat <<'EOF'
## Summary

Complete Phase 1 of the desktop-app extraction by moving the 5 database analyses plus the query runner and query explainer out of the Rails controller concerns into `mysql_genius-core`, then do the paired release of `mysql_genius-core 0.1.0` + `mysql_genius 0.4.0`.

Host apps see no public API change — this is entirely an internal refactor. After `bundle update`, the `mysql_genius` gem will pull in `mysql_genius-core` as a transitive dependency; no Gemfile changes are required.

## What's included

- 5 new analysis classes under `MysqlGenius::Core::Analysis::*`
- `Core::QueryRunner` + `Core::QueryRunner::Config` + `Core::ExecutionResult`
- `Core::QueryExplainer`
- Publish workflow updated to build and push both gems in the correct order
- Version bumps: `mysql_genius-core` → `0.1.0`, `mysql_genius` → `0.4.0`
- CHANGELOG.md flipped from `## Unreleased` → `## 0.4.0`
- Gemspec dep updated from `"~> 0.1.0.pre"` → `"~> 0.1"`

## Test plan

- [x] `bundle exec rspec` — Rails adapter suite green
- [x] `cd gems/mysql_genius-core && bundle exec rspec` — core gem suite green
- [x] Integration smoke-test against a real Rails host app: all tabs behave identically to pre-refactor
- [ ] After merge: tag `v0.4.0`, verify publish workflow publishes both gems to rubygems
- [ ] After release: `gem install mysql_genius` in a fresh terminal resolves `mysql_genius-core` transitively

## What's next

- Phase 2 — build `mysql_genius-desktop` standalone gem (Sinatra host, Trilogy adapter, Connection Manager UI)

See [the design spec](docs/superpowers/specs/2026-04-10-desktop-app-design.md) §9 for the full Phase 2+ roadmap.
EOF
)"
```

- [ ] **Step 3: Merge the PR**

Go to GitHub and merge via the UI. Use **"Rebase and merge"** if you want the per-task commits to land individually on main (12 commits), or **"Squash and merge"** for a single `Phase 1b (#N)` commit.

- [ ] **Step 4: Pull main locally and tag**

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
git checkout main
git pull --ff-only
git log --oneline -5
```

Verify the top commit is the merged PR.

```bash
git tag v0.4.0
git push origin v0.4.0
```

- [ ] **Step 5: Monitor the publish workflow**

```bash
gh run list --limit 3
```

Expected within ~60 seconds: `queued` → `in_progress` → `completed success` for `Release v0.4.0 / Publish to RubyGems`. If there's any failure, check the logs:

```bash
gh run view --log-failed
```

- [ ] **Step 6: Verify both gems landed on rubygems**

```bash
sleep 30  # let rubygems index update
gem search ^mysql_genius$ --remote --exact
gem search ^mysql_genius-core$ --remote --exact
```

Expected output:
```
mysql_genius (0.4.0)
mysql_genius-core (0.1.0)
```

- [ ] **Step 7: Verify a fresh install resolves the dependency**

```bash
mkdir -p /tmp/mysql_genius_install_test
cd /tmp/mysql_genius_install_test
cat > Gemfile <<'EOF'
source "https://rubygems.org"
gem "mysql_genius", "0.4.0"
EOF
bundle install 2>&1 | tail -5
bundle info mysql_genius-core
```

Expected: `bundle install` succeeds and `bundle info mysql_genius-core` shows `0.1.0` was pulled in transitively. Clean up:

```bash
cd /Users/abyrd/Code/GitHub/mysql_genius
rm -rf /tmp/mysql_genius_install_test
```

---

## Stage D — Final verification

### Task 13: Phase 1b ship criterion

- [ ] **Step 1: Verify the release is complete**

```bash
gem search ^mysql_genius$ --remote --exact
gem search ^mysql_genius-core$ --remote --exact
```

Expected:
```
mysql_genius (0.4.0)
mysql_genius-core (0.1.0)
```

- [ ] **Step 2: Verify main has the version bumps**

```bash
git checkout main
git log --oneline -5
ruby -r./lib/mysql_genius/version -e "puts MysqlGenius::VERSION"
ruby -I gems/mysql_genius-core/lib -r mysql_genius/core/version -e "puts MysqlGenius::Core::VERSION"
```

Expected:
```
0.4.0
0.1.0
```

- [ ] **Step 3: Verify the `DatabaseAnalysis` concern has shrunk**

```bash
wc -l app/controllers/concerns/mysql_genius/database_analysis.rb
wc -l app/controllers/concerns/mysql_genius/query_execution.rb
```

Expected: `database_analysis.rb` drops from 295 lines to roughly 40-50 lines (one short wrapper method per of 5 actions). `query_execution.rb` drops from 131 lines to roughly 60-80 lines (execute + explain wrappers, sanitize_ai_sql, audit).

- [ ] **Step 4: Confirm no stale references**

```bash
grep -rn "def apply_row_limit\|def apply_timeout_hint\|def mariadb\?\|def validate_sql\|def timeout_error\?\|def masked_column\?" app/ lib/ 2>&1 | head -10
```

Expected: empty (or only matches in core's SqlValidator, which is allowed). The private helpers moved to `Core::QueryRunner`.

- [ ] **Step 5: Confirm the `Core::Analysis::*` classes exist and are required**

```bash
ls gems/mysql_genius-core/lib/mysql_genius/core/analysis/
cat gems/mysql_genius-core/lib/mysql_genius/core.rb | grep "analysis/"
```

Expected list of files: `duplicate_indexes.rb`, `query_stats.rb`, `server_overview.rb`, `table_sizes.rb`, `unused_indexes.rb`. Expected requires: one line per file.

- [ ] **Step 6: Final smoke test**

```bash
bundle exec rspec 2>&1 | tail -5
(cd gems/mysql_genius-core && bundle exec rspec 2>&1 | tail -5)
bundle exec rubocop 2>&1 | tail -3
(cd gems/mysql_genius-core && bundle exec rubocop 2>&1 | tail -3)
```

Expected: all four pass.

---

## Phase 1b ship criterion

- [ ] All 5 analysis classes extracted into `MysqlGenius::Core::Analysis::*`
- [ ] `Core::QueryRunner`, `Core::QueryRunner::Config`, `Core::ExecutionResult` all implemented
- [ ] `Core::QueryExplainer` implemented
- [ ] `DatabaseAnalysis` concern actions are thin delegating wrappers
- [ ] `QueryExecution` concern `execute` and `explain` actions are thin delegating wrappers
- [ ] Private helpers `validate_sql` / `apply_timeout_hint` / `mariadb?` / `apply_row_limit` / `timeout_error?` / `masked_column?` removed from concern
- [ ] `bundle exec rspec` in repo root passes
- [ ] `(cd gems/mysql_genius-core && bundle exec rspec)` passes
- [ ] `bundle exec rubocop` passes in both repo root and core gem
- [ ] `.github/workflows/publish.yml` builds and pushes both gems in the correct order
- [ ] `mysql_genius-core/lib/mysql_genius/core/version.rb` reads `"0.1.0"`
- [ ] `lib/mysql_genius/version.rb` reads `"0.4.0"`
- [ ] `mysql_genius.gemspec` declares dependency as `"~> 0.1"` (no `.pre` suffix)
- [ ] `CHANGELOG.md` top section is `## 0.4.0` with Phase 1b bullets
- [ ] `v0.4.0` tag pushed to origin
- [ ] Publish workflow completed successfully
- [ ] `gem search` confirms `mysql_genius (0.4.0)` and `mysql_genius-core (0.1.0)` on rubygems
- [ ] Fresh `bundle install` against `gem "mysql_genius", "0.4.0"` resolves `mysql_genius-core 0.1.0` transitively
- [ ] The Rails engine's mountpoint, routes, and JSON responses are identical to 0.3.2

**Phase 1 is complete when this ships.** Phase 2 opens a fresh branch to build `mysql_genius-desktop`.
