# Cross-Platform Desktop App — Design

**Status:** Design
**Date:** 2026-04-10
**Author:** Design brainstorm session

## 1. Overview

MySQLGenius ships today as a Rails engine that mounts into a host application, using the host's ActiveRecord connection to expose a MySQL performance dashboard. This design extends it into a **cross-platform desktop application** for DBAs and operators who don't run a Rails app and want to point the dashboard at arbitrary MySQL/MariaDB servers on demand — the way tools like TablePlus, DBeaver, or Sequel Ace are used, but focused on performance tuning rather than general SQL editing.

The Rails engine continues to ship and continues to work. The desktop app is an additional product that shares a core library with it.

### Goals

- Native desktop app for macOS, Linux, and Windows (all first-class)
- Users provide their own MySQL/MariaDB connections at runtime; no host Rails app required
- Maximum reuse of existing Ruby code — the refactor should create *one* implementation of each analysis, used by both products
- Existing `mysql_genius` gem consumers see no behavior change, no public API change
- Security-first: credentials in the OS keychain, never on disk as plaintext, session-token authenticated internal APIs
- Shippable in phases, each phase independently releasable and reviewable

### Non-goals (for v1)

- Code signing (deferred; design supports it — see §7.4)
- Multi-connection tabs; single active connection at a time
- Close-to-tray / background running
- Linux arm64 and Windows arm64 targets
- Mobile (iOS/Android)
- General-purpose SQL IDE features beyond what the current dashboard offers

## 2. Motivation

- Reach users who don't have a Rails application to mount a gem into
- Let operators point one tool at many different MySQL/MariaDB servers without editing code
- Justify a single-binary distribution so adoption doesn't require "add this to your Gemfile"

## 3. High-level architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Tauri 2 shell  (Rust, per-platform native)                   │
│  • Window, menus, tray hooks, auto-updater                   │
│  • WebView: WebKit / WebKitGTK / WebView2                    │
│  • Owns profile storage (profiles.json)                      │
│  • Owns credential storage (OS keychain)                     │
│  • Spawns and supervises the sidecar                         │
│  • ~200 lines of Rust                                        │
└──────────────────┬───────────────────────────────────────────┘
                   │ spawns sidecar as subprocess
                   │ exposes window.__TAURI__.invoke() to webview
                   ▼
┌──────────────────────────────────────────────────────────────┐
│ Tebako-packed Ruby binary  (per-platform)                    │
│                                                              │
│  mysql_genius-desktop  (new gem — Sinatra host)              │
│   • App: Sinatra routes                                      │
│   • ActiveSession: in-memory Trilogy connection holder       │
│   • PublicRoutes: dashboard + queries (cookie-authed)        │
│   • AdminRoutes: /internal/* (session-token-authed)          │
│   • Launcher: Tebako entry point                             │
│                                                              │
│  mysql_genius-core  (new gem — Rails-free library)           │
│   • Connection + Result value objects                        │
│   • SqlValidator, QueryRunner                                │
│   • Analysis::{TableSizes, DuplicateIndexes, UnusedIndexes,  │
│     QueryStats, ServerOverview, PerformanceSchemaDigest}     │
│   • Ai::{Client, SuggestionService, OptimizationService}     │
│   • Shared ERB templates (dashboard + partials)              │
│                                                              │
│  mysql_genius  (existing gem — Rails adapter, thin)          │
│   • Engine, BaseController, QueriesController                │
│   • Delegates to mysql_genius-core services                  │
│                                                              │
│  Dependencies: trilogy, sinatra, puma                        │
└──────────────────┬───────────────────────────────────────────┘
                   │ MySQL wire protocol (via trilogy gem)
                   ▼
            User's MySQL/MariaDB servers
```

### 3.1 Three-gem split

| Gem | Role | Rails? | New or existing |
|---|---|---|---|
| `mysql_genius-core` | Shared library: validators, analyses, AI services, connection abstraction, shared ERB templates | No | New |
| `mysql_genius` | Rails adapter: Engine, controllers, routes, `ActiveRecord` → `Core::Connection` bridge | Yes | Existing (refactored) |
| `mysql_genius-desktop` | Sinatra host: Connection Manager routes, `ActiveSession`, admin endpoints, Tebako entry point | No | New |

All three live in a monorepo (this repo). `mysql_genius` continues to live at the repo root for minimal release-machinery disruption; new gems live under `gems/`.

### 3.2 Key dependency choices

- **MySQL driver: Trilogy** — pure MySQL wire-protocol implementation, zero dependency on `libmysqlclient`. Critical for clean Tebako packaging across all three OSes. MariaDB supported via wire compatibility (`information_schema`, `performance_schema`, and standard SQL all work; MariaDB-specific auth plugins and replication extensions are untested).
- **`mysql_genius-core` avoids ActiveRecord.** The Rails adapter converts `ActiveRecord::Result` → `Core::Result` in a small adapter class (~30 lines). Keeps core lean and keeps the Tebako binary small.
- **Sinatra** for the desktop host. Small footprint, ~50ms boot. No full Rails boot in the sidecar.
- **Tebako** for Ruby bundling. The only currently-maintained option that handles Rails/Sinatra + native gems across macOS, Linux, and Windows.
- **Tauri 2** for the desktop shell. First-class Windows support (WebView2), native WebKit on macOS, WebKitGTK on Linux. ~10MB shell, small Rust surface.

## 4. Core refactor

### 4.1 File mapping

| Current file | Destination | Notes |
|---|---|---|
| `lib/mysql_genius/sql_validator.rb` | `mysql_genius-core` | Moves as-is; stateless |
| `lib/mysql_genius/configuration.rb` | Split 3 ways | Core: timeouts, row limits, blocked tables, masked columns, AI config. Rails adapter: auth lambda. Desktop: keychain service name, config dir path |
| `lib/mysql_genius/slow_query_monitor.rb` | `mysql_genius` (Rails adapter) | Stays Rails-only — subscribes to `ActiveSupport::Notifications`. Desktop has a different implementation |
| `lib/mysql_genius/engine.rb` | `mysql_genius` (Rails adapter) | Unchanged |
| `app/services/mysql_genius/ai_client.rb` | `mysql_genius-core` | Pure `Net::HTTP`, moves clean |
| `app/services/mysql_genius/ai_suggestion_service.rb` | `mysql_genius-core` | Moves clean |
| `app/services/mysql_genius/ai_optimization_service.rb` | `mysql_genius-core` | Moves clean |
| `app/controllers/mysql_genius/base_controller.rb` | `mysql_genius` (Rails adapter) | Auth + helpers stay Rails-side |
| `app/controllers/mysql_genius/queries_controller.rb` | `mysql_genius` (Rails adapter) | Rewritten as thin delegation to core services |
| `app/views/mysql_genius/queries/*.html.erb` (1569 lines + 11 partials) | `mysql_genius-core/lib/mysql_genius/core/views/` | Shared template directory. Both adapters load templates from core's installed location |
| New: analysis logic currently embedded in `queries_controller.rb` | `mysql_genius-core/lib/mysql_genius/core/analysis/*.rb` | One class per analysis |

### 4.2 New interfaces in `mysql_genius-core`

```ruby
# Connection abstraction. `Core::Connection` is the interface;
# concrete adapters are subclasses under that namespace.
# Services accept any object that conforms to this interface.
module MysqlGenius::Core::Connection
  # Implementing adapters:
  #   Core::Connection::ActiveRecordAdapter (Rails adapter gem)
  #   Core::Connection::TrilogyAdapter      (desktop gem or core)
  #   Core::Connection::FakeAdapter         (test helper in core)
  #
  # Contract every adapter must satisfy:
  #   #exec_query(sql, binds: []) -> Core::Result
  #   #server_version             -> Core::ServerInfo
  #   #close                      -> nil
end

# Uniform result shape — both adapters translate into this.
class MysqlGenius::Core::Result
  attr_reader :columns  # => [String]
  attr_reader :rows     # => [[Object]]
  def each(&block)
  def to_a
  def count
  def empty?
end

class MysqlGenius::Core::ServerInfo
  attr_reader :vendor   # => :mysql | :mariadb
  attr_reader :version  # => "8.0.35"
end
```

Services all take a `Connection` as their first argument — no globals, no `ActiveRecord::Base.connection`, no module-level state reaches into them:

```ruby
MysqlGenius::Core::QueryRunner.new(connection, config).run(sql)
MysqlGenius::Core::Analysis::TableSizes.new(connection).call
MysqlGenius::Core::Analysis::DuplicateIndexes.new(connection).call
MysqlGenius::Core::Analysis::UnusedIndexes.new(connection).call
MysqlGenius::Core::Analysis::QueryStats.new(connection).call
MysqlGenius::Core::Analysis::ServerOverview.new(connection).call
MysqlGenius::Core::Analysis::PerformanceSchemaDigest.new(connection).call
MysqlGenius::Core::Ai::SuggestionService.new(connection, ai_config).suggest(sql)
MysqlGenius::Core::Ai::OptimizationService.new(connection, ai_config).optimize(sql)
```

### 4.3 Adapter wiring

**Rails adapter** — `QueriesController` becomes a thin delegator:

```ruby
def table_sizes
  result = MysqlGenius::Core::Analysis::TableSizes
             .new(rails_core_connection)
             .call
  render json: result
end

private

def rails_core_connection
  MysqlGenius::Core::Connection::ActiveRecordAdapter
    .new(ActiveRecord::Base.connection)
end
```

`ActiveRecordAdapter` (~30 lines in the Rails adapter gem) wraps an AR connection and translates `ActiveRecord::Result` → `Core::Result`.

**Desktop adapter** — Sinatra routes resolve the active profile's connection from `ActiveSession` and hand it to the same core services:

```ruby
get "/table_sizes" do
  protect_with_session_cookie!
  conn = active_session.connection  # Trilogy-backed Core::Connection
  result = MysqlGenius::Core::Analysis::TableSizes.new(conn).call
  json(result)
end
```

### 4.4 SlowQueryMonitor split

The two adapters implement the Slow Queries feature over fundamentally different data sources:

- **Rails adapter** (existing): subscribes to `ActiveSupport::Notifications` `sql.active_record` events in the host app, stores to Redis. Captures the host application's own queries.
- **Desktop adapter** (new): polls `performance_schema.events_statements_summary_by_digest` on demand when the Slow Queries tab opens. Surfaces what the MySQL server has observed across all clients. Implemented as `Core::Analysis::PerformanceSchemaDigest`.

These are intentionally kept as separate implementations behind a capability flag returned from `/capabilities`. The frontend shows the Slow Queries tab the same way; its content differs based on the adapter. No forced unification.

## 5. Desktop-specific components

### 5.1 Component ownership

| Component | Owner | Why |
|---|---|---|
| Profile list (`profiles.json`) | Tauri (Rust) | File I/O simpler from Rust; avoids Ruby file-system edge cases |
| Credential storage (OS keychain) | Tauri (Rust) | Keychain FFI is the #1 Tebako pain point; keeping it out of Ruby dramatically simplifies the binary. Also lets OS keychain prompts come from Tauri's window, not a headless Ruby process |
| Sidecar supervision | Tauri (Rust) | Shell is the parent process; natural supervisor |
| Active MySQL connection | Sidecar (Ruby) | Needs `Trilogy` objects, which live in Ruby |
| Query execution, analysis, AI | Sidecar (Ruby) | All existing logic |
| UI rendering | WebView + Sidecar (Ruby ERB) | Existing templates, reused from `mysql_genius-core` |

The sidecar is **stateless** across restarts: its only state is the in-memory Trilogy connection. If it crashes, Tauri re-spawns it and re-posts the active profile's credentials; the user never sees a lost connection except as a brief spinner.

### 5.2 Storage layout

**Profile list (owned by Tauri):**

- macOS: `~/Library/Application Support/MySQLGenius/profiles.json`
- Linux: `$XDG_CONFIG_HOME/mysql-genius/profiles.json` (default `~/.config/mysql-genius/profiles.json`)
- Windows: `%APPDATA%\MysqlGenius\profiles.json`

Schema:

```json
{
  "version": 1,
  "profiles": [
    {
      "id": "01HXY...",
      "name": "Production RDS",
      "host": "db.example.com",
      "port": 3306,
      "username": "readonly",
      "default_database": "app_production",
      "tls_mode": "required",
      "ai_enabled": true,
      "blocked_tables": ["users", "sessions"],
      "masked_column_patterns": ["password", "token"],
      "query_timeout_seconds": 30,
      "row_limit": 1000,
      "created_at": "2026-04-10T12:34:56Z",
      "last_used_at": null
    }
  ]
}
```

Never contains passwords. Passwords live only in the OS keychain.

**Credentials (owned by Tauri via `keyring` crate):**

- Service name: `com.mysql-genius.app`
- Account name: profile ID
- Value: password (stored as OS keychain item)

**Log files:**

- `<config dir>/tauri.log` — shell events
- `<config dir>/sidecar.log` — request log, query shapes, errors
- Rotate at 10 MB, keep 5 files
- "Open Logs" menu item in the Tauri app menu

### 5.3 Session token (internal API protection)

Tauri generates a random 256-bit token at launch and:

1. Passes it to the sidecar via environment variable `MYSQL_GENIUS_SESSION_TOKEN`
2. Sets it as an HTTP-only cookie on the webview (`mg_session=<token>; Path=/; SameSite=Strict; HttpOnly`) before navigating to the sidecar URL
3. Includes it as an `X-Session-Token` header when Tauri itself calls the sidecar's `/internal/*` endpoints

The sidecar validates the session cookie on **every** public route and the session header on every `/internal/*` route. Requests without a valid token receive HTTP 401 and are logged at warn level. Bound strictly to loopback (`127.0.0.1`).

This protects against other local processes talking to the sidecar's localhost port.

### 5.4 Connection Manager UI

- Rendered by the sidecar, served at `/connections` via Sinatra + ERB
- Empty state: first-launch experience; `/capabilities` reports `profiles_count: 0`, dashboard redirects to `/connections`
- List view: shows all profiles with status indicator ("Last connected successfully," "Last attempt: connection refused")
- Add/Edit form:
  - Name, host, port, username, password, default database
  - TLS mode (disabled / preferred / required)
  - AI config (provider, model, API key, base URL)
  - Blocked tables, masked column patterns
  - Query timeout, row limit
- "Test Connection" button: POSTs to `/internal/test_connection` via Tauri (which relays with the session token), sidecar opens a throwaway Trilogy connection, runs `SELECT VERSION()`, returns success or error
- "Delete" requires confirmation
- All CRUD operations go through Tauri IPC (`window.__TAURI__.invoke(...)`); profiles and credentials are never persisted by the Ruby sidecar

### 5.5 Connection lifecycle

- **On activate profile:** Sidecar opens a new `Trilogy` connection, runs `SELECT VERSION()` as health check, stores in `Desktop::ActiveSession`
- **On request:** Reuses the same connection
- **On error during use:** Closes the dead connection, opens a new one using cached profile credentials, retries the failing query **once**. If the retry fails, returns the error
- **On deactivate / profile switch / shutdown:** Closes cleanly
- **No connection pool** — the webview issues ≤3 concurrent requests; a pool would be ceremony without benefit

## 6. Data flow

### 6.1 Launch sequence

```
t=0      User double-clicks MySQLGenius.app
t=50ms   Tauri process starts
         ├─ Reads profiles.json
         ├─ Generates random 256-bit session token
         ├─ Picks a random free port (e.g., 52431)
         └─ Shows splash window ("Starting…")
t=100ms  Tauri spawns the Tebako sidecar binary
         env: MYSQL_GENIUS_SESSION_TOKEN=<token>
              MYSQL_GENIUS_PORT=52431
              MYSQL_GENIUS_CONFIG_DIR=<platform path>
              MYSQL_GENIUS_LOG_FILE=<platform path>/sidecar.log
t=100-500ms  Sidecar boots
         ├─ Tebako decompresses Ruby runtime to temp dir (first launch only)
         ├─ Ruby boots, requires Sinatra + trilogy + mysql_genius-core + mysql_genius-desktop
         ├─ Starts Puma on 127.0.0.1:52431
         └─ Responds to GET /internal/health → { ok: true }
t=500ms  Tauri polls GET /internal/health (up to 10s timeout)
t=550ms  Tauri sets mg_session cookie on the webview cookie store
t=600ms  Tauri navigates webview to http://127.0.0.1:52431/
t=700ms  Webview calls:
         • GET /capabilities on the sidecar → { has_active_connection, slow_queries_source, server_version? }
         • window.__TAURI__.invoke('list_profiles') → array of profiles (from Tauri, no passwords)
t=750ms  Routing:
         • profiles.length == 0             → redirect /connections, empty state
         • has_active_connection == false   → connection picker modal
         • otherwise                        → auto-activate last-used profile, show dashboard
```

**State ownership split.** The sidecar owns runtime session state (active connection, current server version); Tauri owns persistent storage (profile list, passwords). The webview queries both during initial routing. This is why `/capabilities` on the sidecar does **not** know the profile count — it would be lying if it tried to return one.

**First-launch tax:** Tebako extracts the compressed Ruby runtime to a cache dir on first run (~200-500ms extra). Subsequent launches skip. Document in the installation page.

### 6.2 Query execution

```
User clicks "Run" on a SELECT
  ↓
Webview JS: fetch('/query', {
  method: 'POST',
  credentials: 'include',
  body: JSON.stringify({ sql })
})
  ↓
Sidecar: Desktop::PublicRoutes#post '/query'
  ├─ validate mg_session cookie
  ├─ require ActiveSession to have an open connection
  ├─ Core::QueryRunner.new(active_conn, profile_config).run(sql)
  │   ├─ SqlValidator.validate(sql) → raise if rejected
  │   ├─ apply row limit + timeout hint (MySQL vs MariaDB syntax)
  │   ├─ active_conn.exec_query(wrapped_sql)
  │   ├─ wrap as Core::Result
  │   └─ apply masked_column_patterns
  ├─ render JSON: { columns, rows, duration_ms, row_count }
  ↓
Webview JS renders the result table
```

### 6.3 Profile switch

```
User clicks "Connect to <profile>" in Connection Manager
  ↓
Webview JS: window.__TAURI__.invoke('activate_profile', { id })
  ↓
Tauri:
  ├─ read profiles.json → find profile
  ├─ read OS keychain → get password (may show OS prompt)
  ├─ POST /internal/activate
  │    header: X-Session-Token: <token>
  │    body:   { host, port, username, password, database, profile_config }
  ↓
Sidecar:
  ├─ close existing Trilogy connection (if any)
  ├─ open new Trilogy connection
  ├─ run SELECT VERSION() as health check
  ├─ store in Desktop::ActiveSession
  └─ return { ok, server_version, vendor }
  ↓
Tauri relays OK to JS
  ↓
JS navigates to dashboard (now scoped to the new active connection)
```

### 6.4 Shutdown

```
User closes window / Cmd+Q / Alt+F4
  ↓
Tauri on-close:
  ├─ POST /internal/shutdown (with session token)
  ├─ Sidecar: close active Trilogy connection, stop Puma, exit(0)
  ├─ wait up to 2s for sidecar to exit
  ├─ if still running: SIGTERM, wait 2s
  ├─ if still running: SIGKILL
  └─ Tauri exits
```

Graceful shutdown gives MySQL a chance to release the session; dangling connections leak server-side resources until `wait_timeout`.

### 6.5 Error paths

| Failure | Detection | Recovery |
|---|---|---|
| **Sidecar fails to start** (port in use, Tebako decompression fails, dependency missing) | `/internal/health` poll times out after 10s | Tauri shows native error dialog with last line of `sidecar.log`. Buttons: Open Logs, Quit |
| **Sidecar crashes while running** | Tauri child-process watcher sees exit | Tauri shows a toast "Backend crashed, restarting…" and re-spawns once. If it crashes twice within 60s, same error dialog as above |
| **Trilogy can't connect** (wrong creds, host unreachable, TLS mismatch) | `Trilogy.new` raises `Trilogy::ConnectionError` | Sidecar returns HTTP 400 `{ error: "connection_failed", message }`. Connection Manager shows inline error next to the profile. Profile not auto-deleted |
| **MySQL drops connection mid-query** (e.g., `wait_timeout` elapsed) | `exec_query` raises `Trilogy::Error` | `QueryRunner` closes the dead connection, opens a fresh one from cached profile, retries **once**. If retry fails, returns the error |
| **Keychain access denied** (user clicks Deny on macOS prompt, libsecret absent on Linux) | Tauri's keychain plugin returns error | Tauri shows "MySQLGenius couldn't access your keychain. Your saved connections require it." Buttons: Retry, Quit. No plaintext fallback |
| **AI provider down or unauthorized** | `AiClient` gets non-2xx from OpenAI/Anthropic | `Core::Ai::*` raises `Core::Ai::ServiceError`. Sidecar returns HTTP 502. Webview shows tab-local error banner; AI tab stays usable |
| **SQL validation rejected** (non-SELECT, blocked table, etc.) | `SqlValidator` raises `Rejected` | Sidecar returns HTTP 422 with the reason. Webview shows reason inline in the query editor |
| **Query timeout** (exceeds per-profile max duration) | MySQL returns `ER_QUERY_TIMEOUT` / `ER_STATEMENT_TIMEOUT` | Trilogy raises, sidecar returns HTTP 408. No retry |
| **Disk full / can't write profiles.json** | Tauri file write fails | Tauri shows native dialog |
| **User revokes keychain access mid-session** | Subsequent profile activations fail keychain read | Same handling as "Keychain access denied" |

### 6.6 Logging

- **Tauri log:** shell events (spawn, crash, restart, session start/end)
- **Sidecar log:** request log, query *shape* (table names, duration, row count), errors with backtraces
- **Never logged:** bind values, result rows, passwords, API keys
- **Masked-column patterns** apply to log output the same way they apply to API responses
- **Rotation:** 10 MB max size, 5-file retention, both files
- **No telemetry, no phoning home.** The only outbound network traffic is (a) the user's configured MySQL/MariaDB servers and (b) the configured AI provider if AI is enabled

## 7. Build & distribution

### 7.1 Repo layout

```
mysql_genius/                   (repo root — existing Rails adapter stays here)
├── app/
├── lib/mysql_genius/
├── mysql_genius.gemspec
│
├── gems/
│   ├── mysql_genius-core/
│   │   ├── lib/mysql_genius/core/
│   │   │   ├── connection.rb
│   │   │   ├── result.rb
│   │   │   ├── sql_validator.rb
│   │   │   ├── query_runner.rb
│   │   │   ├── analysis/
│   │   │   │   ├── table_sizes.rb
│   │   │   │   ├── duplicate_indexes.rb
│   │   │   │   ├── unused_indexes.rb
│   │   │   │   ├── query_stats.rb
│   │   │   │   ├── server_overview.rb
│   │   │   │   └── performance_schema_digest.rb
│   │   │   ├── ai/
│   │   │   │   ├── client.rb
│   │   │   │   ├── suggestion_service.rb
│   │   │   │   └── optimization_service.rb
│   │   │   └── views/
│   │   ├── spec/
│   │   └── mysql_genius-core.gemspec
│   │
│   └── mysql_genius-desktop/
│       ├── lib/mysql_genius/desktop/
│       │   ├── app.rb
│       │   ├── active_session.rb
│       │   ├── public_routes.rb
│       │   ├── admin_routes.rb
│       │   ├── launcher.rb
│       │   └── views/
│       ├── bin/mysql-genius-sidecar
│       ├── spec/
│       └── mysql_genius-desktop.gemspec
│
├── desktop/
│   ├── tauri/
│   │   ├── src/
│   │   │   ├── main.rs
│   │   │   ├── sidecar.rs
│   │   │   ├── profiles.rs
│   │   │   └── credentials.rs
│   │   ├── tauri.conf.json
│   │   ├── Cargo.toml
│   │   └── icons/
│   └── tebako/
│       ├── tebako.yml
│       └── entrypoint.rb
│
├── .github/workflows/
│   ├── ci.yml                       (existing gem tests, extended)
│   ├── desktop-ci.yml               (new: Tauri + Tebako builds)
│   └── release.yml                  (new: tag → installers)
│
└── docs/
```

### 7.2 Tebako

Recipe (`desktop/tebako/tebako.yml`):

```yaml
ruby: "3.2.6"   # pin to the current Tebako-supported Ruby at Phase 3 start
package: mysql-genius-sidecar
root: ../../
entry-point: gems/mysql_genius-desktop/bin/mysql-genius-sidecar
prefix: mysql-genius
```

The Ruby version shown above is illustrative. Tebako supports a specific set of Ruby versions that evolves over time. **Confirm the exact supported version at Phase 3 kickoff** by checking the current Tebako release notes, and pin the same version across all release builds to avoid "works on my machine" drift.

Entry point (`gems/mysql_genius-desktop/bin/mysql-genius-sidecar`):

```ruby
#!/usr/bin/env ruby
require "mysql_genius/desktop/launcher"
MysqlGenius::Desktop::Launcher.run(
  port: ENV.fetch("MYSQL_GENIUS_PORT").to_i,
  session_token: ENV.fetch("MYSQL_GENIUS_SESSION_TOKEN"),
  log_file: ENV.fetch("MYSQL_GENIUS_LOG_FILE"),
)
```

Output: one executable per target, ~40-60 MB.

**Known Tebako risk areas:**

- **Trilogy native extension on Windows** — Tebako's msys2 toolchain is the least-tested path. If Trilogy fails to build, the fallback is pre-building against Tebako's Ruby and vendoring the `.so`/`.dll`. Budget a day for first Windows build.
- **OpenSSL version skew** — Tebako bundles its own OpenSSL; TLS 1.3 handshakes against modern MySQL can fail if versions mismatch. Test early against a TLS-enabled MySQL.
- **First-launch extraction time** — 200-500ms added to first run. Document, don't fight.

### 7.3 Tauri

`desktop/tauri/tauri.conf.json` (key parts):

```json
{
  "productName": "MySQLGenius",
  "version": "0.1.0",
  "identifier": "com.mysql-genius.app",
  "bundle": {
    "active": true,
    "targets": ["app", "dmg", "msi", "nsis", "appimage", "deb"],
    "externalBin": ["../../gems/mysql_genius-desktop/bin/mysql-genius-sidecar"],
    "icon": ["icons/icon.png", "icons/icon.ico", "icons/icon.icns"]
  },
  "plugins": {
    "updater": {
      "endpoints": ["https://github.com/antarr/mysql_genius/releases/latest/download/latest.json"],
      "pubkey": "<ed25519 public key>"
    }
  }
}
```

The `externalBin` field tells Tauri to bundle the Tebako sidecar. Tauri picks up per-target binaries by triple:

- `mysql-genius-sidecar-x86_64-apple-darwin`
- `mysql-genius-sidecar-aarch64-apple-darwin`
- `mysql-genius-sidecar-x86_64-pc-windows-msvc`
- `mysql-genius-sidecar-x86_64-unknown-linux-gnu`

The Tebako build step must emit one file per target with the matching suffix.

Rust shell modules (~200 lines total):

- `main.rs` — window, menu, updater wiring
- `sidecar.rs` — spawn, health-poll, supervise (restart-once-then-error)
- `profiles.rs` — profiles.json CRUD; exposes Tauri commands `list_profiles`, `save_profile`, `delete_profile`, `activate_profile`
- `credentials.rs` — wraps the `keyring` crate; exposes `get_password`, `set_password`, `delete_password`

### 7.4 Code signing — deferred for MVP

**v1 ships unsigned.** macOS users will see Gatekeeper warnings; Windows users will see SmartScreen warnings. Documented in the installation guide with instructions for right-click → Open on macOS and "More info → Run anyway" on Windows.

The design supports signing from day one via Tauri's signing hooks. Adding signing in a later release requires only:

- **macOS:** Apple Developer Program membership ($99/yr). Developer ID Application certificate. `codesign` + `notarytool` in the release workflow. Tauri's `macOS.signingIdentity` field in `tauri.conf.json`.
- **Windows:** EV code signing certificate (SSL.com recommended for its eSigner cloud signing service, which works with GitHub Actions without a physical USB token). OV certificates work too but require SmartScreen reputation to build up over time. Tauri's Windows signing hooks.
- **Linux:** GPG-sign the `.AppImage` / `.deb` / `.rpm` artifacts; publish the public key in the README.

No architectural change is required to add signing later — only secrets in the release workflow and config flips in `tauri.conf.json`.

### 7.5 Auto-updates

Enabled from v1 regardless of code signing. Tauri's updater plugin:

- Fetches `latest.json` manifest from GitHub Releases on launch
- Downloads newer version bundles in the background, signed with an Ed25519 key
- Applies updates on next launch or with user consent

The Ed25519 keypair is generated once; the public key is committed to `tauri.conf.json`, the private key lives in a GitHub Actions secret. Every release signs the update bundle with it. This is independent of OS code signing and protects against MITM/malicious release manifests.

### 7.6 CI targets

**Gems** (extended from existing `ci.yml`):

- `mysql_genius-core`: Ruby 2.7, 3.0, 3.2, 3.4 (no Rails)
- `mysql_genius` (Rails adapter): existing matrix, unchanged
- `mysql_genius-desktop`: Ruby 3.2 (the version Tebako ships with)

**Desktop installers** (new `release.yml`, triggered on release tags only):

| Target | Runner | Output |
|---|---|---|
| macOS x86_64 | `macos-13` | `.app`, `.dmg` |
| macOS aarch64 | `macos-14` | `.app`, `.dmg` |
| Windows x86_64 | `windows-2022` | `.msi`, `.exe` (NSIS) |
| Linux x86_64 | `ubuntu-22.04` | `.AppImage`, `.deb` |

Linux arm64 and Windows arm64 are explicitly out of scope for v1.

**PR smoke test** (new job in `ci.yml`): builds the Tebako sidecar on `ubuntu-latest` only (no Tauri shell). Verifies the gemspecs compile, the native extension builds, and the sidecar can serve `/internal/health`. Full installer matrix runs only on release tags (~30 min wall time).

### 7.7 Distribution channels

| Channel | When |
|---|---|
| GitHub Releases | v1 |
| AppImage (Linux) | v1 (Tauri builds it) |
| `.deb` (Debian/Ubuntu) | v1 |
| Homebrew Cask (macOS) | v1.1 — set up a tap, low-maintenance |
| winget (Windows) | v1.1 — semi-automated via GitHub Action |
| Chocolatey | Optional — winget is the direction of travel |
| `.rpm` (Fedora/RHEL) | Optional — Tauri can build it |
| Snap / Flatpak | Deferred — high effort, low reach for this audience |

### 7.8 Release checklist

1. Bump version in all three gemspecs + `tauri.conf.json` + `Cargo.toml`
2. Update `CHANGELOG.md`
3. Tag `vX.Y.Z`, push
4. CI runs in parallel:
   - Publishes `mysql_genius-core` to RubyGems
   - Publishes `mysql_genius` to RubyGems
   - Publishes `mysql_genius-desktop` to RubyGems
   - Builds Tebako sidecar × 4 targets
   - Builds Tauri installer × 4 targets
   - Generates `latest.json` for the auto-updater, signs with Ed25519 key
   - Creates draft GitHub Release with all artifacts
5. Human reviews the draft, publishes it

## 8. Testing strategy

### 8.1 `mysql_genius-core` unit tests

- `SqlValidator` — existing tests move as-is
- `Connection` — contract tests run against `FakeAdapter`, `ActiveRecordAdapter`, and `TrilogyAdapter`
- `QueryRunner` — uses `FakeConnection` with canned results; verifies validation, limits, masking, error translation
- `Analysis::*` — each class tested with a `FakeConnection` pre-seeded with exact `information_schema` / `performance_schema` rows; asserts (a) correct SQL per MySQL/MariaDB, (b) result shape, (c) edge cases (empty, null, unicode)
- `Ai::*` — existing `instance_double(Net::HTTP)` pattern

**`FakeConnection` helper:**

```ruby
conn = MysqlGenius::Core::Connection::FakeAdapter.new
conn.stub_query(/SELECT.*FROM information_schema\.tables/i,
                columns: ["table_name", "data_length"],
                rows: [["users", 102400]])
conn.stub_query(/SELECT VERSION\(\)/,
                columns: ["VERSION()"],
                rows: [["8.0.35"]])
```

Coverage target: 95%+.

### 8.2 `mysql_genius-core` integration tests (CI)

Against live databases via GitHub Actions service containers:

- MySQL 8.0 (current stable)
- MySQL 5.7 (enterprise LTS)
- MariaDB 10.11 (current LTS)
- MariaDB 11.4 (latest)

Each cell seeds a small schema (~5 tables, some indexes, a view, some rows), runs every analysis class, asserts expected tables/indexes appear in the output. Catches cross-vendor bugs (`information_schema.statistics` differences, missing `performance_schema` columns in older versions, type overflow behavior).

Runs on main and release tags, not every PR. ~20 min parallel wall time.

### 8.3 `mysql_genius` (Rails adapter) tests

Existing pattern continues. Plus:

- `Core::Connection::ActiveRecordAdapter` — translation tests covering all column types the analysis queries return (string, bigint, datetime, decimal, null)
- Controllers shrink to thin delegation tests: "did we call the right core service with the right arguments, did we render the right JSON shape"

Coverage target: maintain existing.

### 8.4 `mysql_genius-desktop` tests

- `Desktop::App` — `Rack::Test` suite for all routes
- `Desktop::ActiveSession` — lifecycle tests (activate, query, deactivate, reconnect-on-error) with a fake Trilogy
- `Desktop::AdminRoutes` — session token enforcement (wrong → 401, missing → 401, correct → 200)
- `Desktop::Launcher` — integration test booting the full app, hitting `/internal/health`, posting to `/internal/activate` with a fake connection, hitting `/query`, shutting down cleanly

Coverage target: 85%+.

### 8.5 Tauri shell tests

- `profiles` module — load/save/delete `profiles.json`, handle corrupt files gracefully
- `credentials` module — smoke test against the OS keychain (skipped in CI if unavailable)
- `sidecar` supervisor — mock sidecar (bash script), verify restart-once-then-give-up policy

No coverage target — surface is too small to track meaningfully.

### 8.6 End-to-end smoke tests

On each release build, on the matching runner, after installer creation:

1. Install the artifact
2. Launch in automation mode
3. Seed a profile via Tauri IPC (bypassing UI clicks)
4. Activate it against a GitHub Actions service-container MySQL
5. POST `SELECT 1` to `/query`, verify response
6. Shut down, assert clean sidecar exit

This catches "Tebako produced a binary that segfaults on Windows" — worth doing from day one.

## 9. Migration plan

Five phases, each shippable and reviewable on its own. Each phase gets its own implementation plan via `writing-plans`.

### Phase 1 — Extract core, no behavior change

- Create `gems/mysql_genius-core/` with gemspec
- Move `SqlValidator`, `AiClient`, `AiSuggestionService`, `AiOptimizationService`
- Create `Core::Connection::ActiveRecordAdapter` + `Core::Result`
- Extract analysis logic from `QueriesController` into `Core::Analysis::*`
- Move shared ERB templates into `mysql_genius-core/lib/mysql_genius/core/views/`, loaded by both adapters from the installed location; audit for Rails-helper usage and replace or shim
- Rewrite `QueriesController` as thin delegation
- Run existing test suite — green, nothing observable changes
- Release `mysql_genius-core 0.1.0` + `mysql_genius 0.4.0` as a paired release
- **Ship criterion:** Rails engine public API unchanged, behavior identical

Highest-risk phase — touches the existing gem. Budget generous test time and careful CHANGELOG notes.

### Phase 2 — Build desktop sidecar standalone

- Create `gems/mysql_genius-desktop/` with gemspec
- Sinatra app, `ActiveSession`, admin routes, Connection Manager ERB views
- Profiles initially stored in a local JSON file managed by the sidecar itself (temporary; Tauri takes over in Phase 3)
- `Core::Connection::TrilogyAdapter` (location TBD in implementation plan — could live in core or desktop)
- `bin/mysql-genius-sidecar` entry point
- `gem install mysql_genius-desktop && mysql-genius-sidecar` runs from a terminal, served at `localhost:4567`
- **Ship criterion:** Sidecar works standalone, accessible via browser at an arbitrary MySQL server. This is an "Ollama-style fallback" that is independently useful even if Tauri never ships.

### Phase 3 — Tauri shell + Tebako packaging

- `desktop/tauri/` Rust project with `main.rs`, `sidecar.rs`, `profiles.rs`, `credentials.rs`
- Move profile storage out of the Sinatra app into Tauri (remove Phase 2's temporary JSON file)
- Move credential storage into Tauri's keychain wrapper
- Sidecar becomes stateless; receives profile + credentials via `/internal/activate`
- Tebako recipe + `desktop/tebako/`
- `.github/workflows/desktop-ci.yml` builds for 4 targets
- **Ship criterion:** Desktop app installs and runs end-to-end on macOS x64, macOS arm64, Windows x64, Linux x64 (unsigned). Downloadable from GitHub Release drafts

### Phase 4 — Polish and public v1.0

- Auto-updater + Ed25519 keypair
- Connection Manager UI polish (empty state, error states, form validation)
- Logging + rotation + "Open Logs" menu item
- Installation docs per platform, with screenshots of Gatekeeper/SmartScreen workarounds
- `CHANGELOG.md` for 1.0.0
- **Ship criterion:** v1.0.0 published on GitHub Releases, announced

### Phase 5 — Code signing (when demand justifies)

- Apple Developer Program enrollment
- SSL.com EV certificate + eSigner setup
- GPG key + `.sig` uploads for Linux
- Update release workflow to use signing secrets
- **Ship criterion:** No more Gatekeeper / SmartScreen warnings on install

### Backward compatibility

After Phase 1, `mysql_genius 0.4.0` depends on `mysql_genius-core ~> 0.1`. Host apps pick up the new core gem automatically via `bundle update mysql_genius`. **No code changes required in host apps** — same mountpoint, same config DSL, same auth lambda, same helpers, same JSON response shapes. The `CHANGELOG.md` must say this explicitly to prevent upgrade panic.

## 10. Open questions (for implementation planning)

- **Location of `Core::Connection::TrilogyAdapter`:** core or desktop? Core is cleaner (adapters are part of the connection abstraction) but means `mysql_genius-core` depends on `trilogy`, which the Rails adapter will pull in transitively. Desktop is cleaner for the Rails-gem user but moves the adapter out of the uniform location. Decide during Phase 2 implementation.
- **Rails helpers in the existing ERB view:** the 1569-line `index.html.erb` needs an audit for `url_for`, `asset_path`, `form_tag`, `link_to`, etc. If it's clean HTML+JS with no helpers, Option A (shared templates in core) is trivial. If it uses helpers, a thin helper shim in each adapter is needed. Audit during Phase 1 kickoff.
- **Connection Manager UI framework:** stick with vanilla JS + ERB (matches the existing dashboard), or introduce something lightweight? Default: vanilla, match existing.
- **Keychain crate for Tauri:** `keyring` on crates.io is the obvious choice but evaluate `tauri-plugin-stronghold` during Phase 3 spike if any platform quirks surface.
- **TLS to user's MySQL:** Trilogy supports TLS but the configuration API is different from `mysql2`. Confirm Trilogy's TLS modes cover the common scenarios (self-signed CA on RDS, required TLS, optional TLS) during Phase 2.

## 11. Future work (explicitly not in v1)

- Code signing (Phase 5, design-supported)
- Multi-connection tabs
- Close-to-tray / system tray integration
- Background refresh of dashboards
- Linux arm64, Windows arm64 targets
- Homebrew Cask, winget packaging (v1.1)
- Persistent query history per profile
- Export results to CSV/JSON
- Saved/named queries per profile
- Dark mode (already present in dashboard, just inherit)
