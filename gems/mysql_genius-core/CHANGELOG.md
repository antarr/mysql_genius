# Changelog

## 0.7.1

### Fixed
- **ERB templates missing from gem package.** The `spec.files` glob in the gemspec only matched `*.rb` files, excluding the shared ERB templates at `lib/mysql_genius/core/views/`. The `mysql_genius-desktop` sidecar crashed with `Errno::ENOENT` when installed from RubyGems (vs path dependency). Fixed by changing the glob to `*.{rb,erb}`.

## 0.7.0

### Added
- `MysqlGenius::Core::Analysis::StatsHistory` — thread-safe in-memory ring buffer storing per-digest query performance snapshots. Supports `record`, `series_for`, `digests`, `clear`. Max 1440 samples per digest (24 hours at 60-second intervals).
- `MysqlGenius::Core::Analysis::StatsCollector` — background thread that samples `performance_schema.events_statements_summary_by_digest` at a configurable interval, computes per-interval deltas, and records them into a `StatsHistory` instance. Handles server restarts (negative deltas clamped to 0) and performance_schema unavailability (stops gracefully).
- `MysqlGenius::Core::Analysis::QueryStats` now includes `digest:` (the `DIGEST` hex hash from performance_schema) in its return value for stable URL keys.
- `capability?(name)` template helper contract — shared templates gate Redis-backed UI via `<% if capability?(:slow_queries) %>` guards. Rails adapter returns `true` for all names; the desktop sidecar returns `true` only for `:ai`.
- Query detail shared template (`query_detail.html.erb`) with SQL display, Explain button, stats cards, and inline SVG time-series charts.
- Query Stats dashboard tab now renders SQL cells as clickable links to `/queries/:digest`.

## 0.6.0

No functional changes in `mysql_genius-core`. Version bumped to maintain lockstep with `mysql_genius 0.6.0`, which drops Rails 5.2 support from the Rails adapter. See the root `CHANGELOG.md` for the full change list.

## 0.5.0

### Added
- `MysqlGenius::Core::Analysis::Columns` — service class for `GET /columns` logic with a tagged-result struct (`:ok`, `:blocked`, `:not_found`). Takes a `Core::Connection`, uses `Core::SqlValidator.masked_column?` for the masked-column rule.
- `MysqlGenius::Core::Ai::{DescribeQuery, SchemaReview, RewriteQuery, IndexAdvisor, MigrationRisk}` — 5 AI prompt builder classes extracted from the `mysql_genius` Rails adapter's `AiFeatures` concern. Each takes `(client, config)` or `(client, config, connection)` and exposes a single `#call` method.
- `MysqlGenius::Core::Ai::SchemaContextBuilder` — shared helper for building "Table: X (~N rows), Columns: …, Indexes: …" schema descriptions. Supports `detail: :basic` and `detail: :with_cardinality`.
- `MysqlGenius::Core::Ai::Config#domain_context` — new optional keyword field (empty string default) interpolated into every extracted prompt builder's system prompt.
- `MysqlGenius::Core.views_path` — public module method returning the absolute path to the shared ERB template directory. Adapters register this path with their own view loader.
- **ERB templates extracted from the Rails adapter.** `MysqlGenius::Core.views_path` now points at `lib/mysql_genius/core/views/` which contains `mysql_genius/queries/dashboard.html.erb` and the 10 tab/partial files. Any adapter (Rails, Sinatra, or future desktop) can load these templates by registering this path with its own view loader. Templates depend on a minimal 2-method contract: `path_for(name)` and `render_partial(name)`.

## 0.4.1

No functional changes in `mysql_genius-core`. Version bumped to maintain lockstep with `mysql_genius 0.4.1`, which hotfixes a regression in the Rails adapter's `GET /columns` endpoint. See the root `CHANGELOG.md` for details.

## 0.4.0

First published release of `mysql_genius-core`. This gem is the Rails-free foundation library for `mysql_genius` and will be the shared core for the forthcoming `mysql_genius-desktop` standalone app. From 0.4.0 onward, `mysql_genius-core` and `mysql_genius` release in lockstep under matching version numbers.

### Added
- `MysqlGenius::Core::Connection` — connection contract with `ActiveRecordAdapter` (used by the Rails engine) and `FakeAdapter` (used in specs).
- `MysqlGenius::Core::SqlValidator` — SELECT-only validation, blocked-table enforcement, row-limit application.
- `MysqlGenius::Core::Ai::{Client, Suggestion, Optimization}` — AI service layer taking an explicit `Core::Ai::Config` instead of reading global configuration.
- `MysqlGenius::Core::Result`, `ColumnDefinition`, `IndexDefinition`, `ServerInfo` — value objects returned by adapters and analyses.
- `MysqlGenius::Core::Analysis::TableSizes` — queries `information_schema.tables` + per-table `COUNT(*)` with size/row/fragmentation metadata.
- `MysqlGenius::Core::Analysis::DuplicateIndexes` — detects left-prefix covering across indexes per table.
- `MysqlGenius::Core::Analysis::QueryStats` — reads `performance_schema.events_statements_summary_by_digest` with sort + limit.
- `MysqlGenius::Core::Analysis::UnusedIndexes` — reads `performance_schema.table_io_waits_summary_by_index_usage` JOINed with `information_schema.tables`.
- `MysqlGenius::Core::Analysis::ServerOverview` — reads `SHOW GLOBAL STATUS` / `SHOW GLOBAL VARIABLES` / `SELECT VERSION()`, computes derived metrics.
- `MysqlGenius::Core::ExecutionResult` — immutable value object for `QueryRunner`'s return.
- `MysqlGenius::Core::QueryRunner` + `QueryRunner::Config` — owns validation, row-limit/timeout-hint application, execution, column masking. Returns `ExecutionResult` or raises `Rejected` / `Timeout`.
- `MysqlGenius::Core::QueryExplainer` — owns EXPLAIN with optional validation-skipping. Returns `Core::Result` or raises `Rejected` / `Truncated`.

MariaDB vs MySQL is detected at runtime so timeout hints use the correct syntax (`SET STATEMENT max_statement_time` vs `MAX_EXECUTION_TIME` optimizer hint).
