# Digest History & Regression Detector

**Status:** Draft
**Date:** 2026-04-22
**Target version:** 0.9.0

## Motivation

Today mysql_genius is point-in-time: every dashboard query hits `events_statements_summary_by_digest` fresh. Users can see the Top-N slow queries *right now* but not:

- Was this query always slow, or did it regress on Tuesday?
- Which query got 3x slower after last week's deploy?
- When did that N+1 start happening?

Snapshotting digest stats on a schedule unlocks a large feature family: regression detection, trend charts, anomaly alerts, deploy-diff correlation. Historical snapshots are also the foundation PgHero uses for its "Query Stats" view and every paid competitor (PlanetScale Insights, Datadog DBM, Releem) builds on the same primitive.

## Goals

1. Persist digest-level stats to a host-app-owned table on a schedule.
2. Detect regressions (p95 latency delta ≥ N× over a baseline window) and surface them in the dashboard.
3. Ship a clean v1 in 1–2 weeks with clear extension points for anomaly alerts, deploy-diff, and AI narration later.

## Non-goals (v1)

- Full time-series analytics UI (sparklines in tables are enough for v1)
- AI root-cause narration — add in 0.9.1 once the data is flowing
- Slack/email alerting — webhook hook only; wire up later
- Multi-database support (tracked separately, see "Open questions")

## Design

### 1. Snapshot table

Host app runs a Rails migration that creates:

```ruby
create_table :mysql_genius_digest_snapshots do |t|
  t.string  :digest,               null: false, limit: 64   # MD5 hex from perf_schema
  t.text    :digest_text                                     # normalized SQL (nullable)
  t.string  :schema_name,          limit: 64
  t.bigint  :count_star,           null: false
  t.bigint  :sum_timer_wait,       null: false              # picoseconds
  t.bigint  :sum_rows_examined,    null: false
  t.bigint  :sum_rows_sent,        null: false
  t.bigint  :sum_errors,           null: false, default: 0
  t.bigint  :sum_no_index_used,    null: false, default: 0
  t.bigint  :sum_created_tmp_tables, null: false, default: 0
  t.datetime :captured_at,         null: false
  t.index [:digest, :captured_at]
  t.index :captured_at
end
```

Design notes:
- Columns mirror perf_schema's cumulative counters — we store **raw cumulatives**, not deltas. Deltas are computed at read time between two snapshots. This keeps the schema simple, handles MySQL restarts gracefully (counter reset → negative delta → ignore the window), and makes the data resampleable.
- Host app owns the table so they control migrations, retention, backups, and can query it directly for custom dashboards.
- A generator provides the migration: `rails g mysql_genius:digest_history`.

### 2. Snapshot collector

New class: `MysqlGenius::Core::DigestSnapshotter` (lives in `mysql_genius-core` so the desktop sidecar can reuse it).

```ruby
MysqlGenius::Core::DigestSnapshotter.new(connection:, store:).capture!
```

- `connection` — existing `Core::Connection` contract (already abstracted)
- `store` — pluggable sink. Default `ActiveRecordStore` writes to the migration table above. Desktop sidecar can implement a `Sqlite3Store`.
- `capture!` issues one `SELECT ... FROM performance_schema.events_statements_summary_by_digest WHERE digest IS NOT NULL` and bulk-inserts rows with a single `captured_at`.

### 3. Scheduling

Default cadence: **every 5 minutes**. Tunable via config:

```ruby
MysqlGenius.configure do |c|
  c.digest_history.enabled = true
  c.digest_history.interval = 5.minutes
  c.digest_history.retention = 30.days
end
```

Scheduling strategy — we do NOT ship a background worker. Three supported modes:

1. **`rake mysql_genius:capture`** — host app wires into whatever they already use (cron, Solid Queue, Sidekiq-Cron, GoodJob, Heroku Scheduler).
2. **Auto-pruning**: captures trigger opportunistic pruning of rows older than `retention`. No separate reaper.
3. **Fallback in-process** (dev/test convenience): a middleware-ish thread that self-schedules if the host has no scheduler. Off by default, documented as "not for production."

Rationale: Rails has no universally agreed-upon scheduler; PgHero takes the same "bring your own cron" approach.

### 4. Regression detector

New class: `MysqlGenius::Core::RegressionDetector`.

```ruby
detector = MysqlGenius::Core::RegressionDetector.new(
  store:,
  baseline_window: 7.days,      # average p95 over this
  comparison_window: 1.hour,    # vs. recent p95 over this
  min_count: 100,               # ignore rare queries
  threshold: 2.0                # flag at ≥2× slower
)
detector.regressions  # => [Regression struct, ...]
```

Algorithm for v1 (deliberately simple):

1. For each digest seen in the last `comparison_window`, compute:
   - `recent_p95 = sum_timer_wait / count_star` averaged over rows in comparison window
   - `baseline_p95 = same, over baseline_window ending before comparison_window`
2. Discard digests where either window has fewer than `min_count` executions.
3. Return digests where `recent_p95 / baseline_p95 ≥ threshold`, sorted by absolute impact (`delta_p95 × recent_count`).
4. Skip digests whose recent `count_star < baseline count_star` (new query pattern, not a regression).

We store **averages of p95**, not true p95, because perf_schema gives us `sum_timer_wait / count_star`. A true p95 would need raw samples or histograms (perf_schema has `BUCKET_*` views in 8.0+, worth a v2 upgrade).

### 5. Dashboard surface

New dashboard panel: **"Regressions"** above the existing top-queries table.

- Shows at most 10 regressions, sorted by impact.
- Each row: digest snippet, baseline vs. recent p95, multiplier, execution count, "investigate" link to existing query detail page.
- If `digest_history.enabled = false` or no data yet, panel shows a setup CTA pointing at the generator.

Query detail page gains a **sparkline** of p95 over the last N days using the same snapshot table.

### 6. Configuration

```ruby
MysqlGenius.configure do |c|
  c.digest_history.enabled     = true       # default false; opt-in
  c.digest_history.interval    = 5.minutes
  c.digest_history.retention   = 30.days
  c.digest_history.store       = :active_record   # or a custom class
  c.regressions.threshold      = 2.0
  c.regressions.baseline_window = 7.days
  c.regressions.comparison_window = 1.hour
  c.regressions.min_count      = 100
end
```

## Rollout plan

- **0.9.0-rc1**: snapshot table generator, `DigestSnapshotter`, rake task, config DSL. No UI yet.
- **0.9.0-rc2**: `RegressionDetector`, dashboard panel, sparklines.
- **0.9.0**: docs, CHANGELOG, blog post.
- **0.9.1**: AI regression narrator (uses Sonnet to explain root cause from digest + EXPLAIN diff + recent migrations).
- **0.9.2**: webhook / Slack hook on regression fire.

## Open questions

1. **Multi-database**: the engine is single-DB today (hardcoded to `ActiveRecord::Base.connection`). If/when we add multi-DB support, the snapshot table needs a `database_id` or `connection_name` column. Should we add it now (cheap to include, hard to add later) or defer until multi-DB support is real? **Recommendation: add `connection_name` column now, default `"primary"`, so the migration is stable.**
2. Do we want `events_statements_histogram_by_digest` (MySQL 8.0.20+) for true p95/p99? Detect at runtime and prefer it when available?
3. Retention: is 30 days sensible? PgHero defaults to 14. Larger windows enable better weekly/monthly comparisons but bloat the table. Make it a config, pick 30 as default.

## Files touched

- `gems/mysql_genius-core/lib/mysql_genius/core/digest_snapshotter.rb` (new)
- `gems/mysql_genius-core/lib/mysql_genius/core/regression_detector.rb` (new)
- `gems/mysql_genius-core/lib/mysql_genius/core/stores/active_record_store.rb` (new)
- `lib/mysql_genius/configuration.rb` — add `digest_history` and `regressions` namespaces
- `lib/generators/mysql_genius/digest_history/...` (new generator for migration)
- `lib/tasks/mysql_genius.rake` — add `mysql_genius:capture`
- `app/controllers/mysql_genius/queries_controller.rb` — wire regression panel data
- `app/views/mysql_genius/queries/_regressions.html.erb` (new partial, in core views path)
- `spec/` coverage for snapshotter, detector, store
