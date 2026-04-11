# Phase 1a — Extract mysql_genius-core Foundation + AI Services

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the new `mysql_genius-core` gem with value objects, a `Core::Connection` abstraction, and the three AI services (`Client`, `Suggestion`, `Optimization`) — all without any behavior change to the existing `mysql_genius` Rails engine.

**Architecture:** Extract Rails-agnostic code from the existing `mysql_genius` gem into a new `mysql_genius-core` gem living under `gems/mysql_genius-core/`. The Rails adapter (existing gem at the repo root) keeps its public API identical and delegates to core via a new `ActiveRecordAdapter` wrapping `ActiveRecord::Base.connection`. The existing RSpec suite continues to pass unchanged; moved specs relocate to the core gem's own spec tree.

**Tech Stack:** Ruby 2.7+, RSpec 3, vanilla `double()` / `instance_double` mocks (the project does **not** use FactoryBot or Mocha for this gem), Bundler path dependency for in-monorepo development.

---

## Scope notes (read before starting)

This plan covers **Phase 1a** from the design spec at `docs/superpowers/specs/2026-04-10-desktop-app-design.md`. Phase 1 from the spec is split into two plans:

- **Phase 1a (this plan):** gem scaffold, value objects, `Core::Connection` + adapters, move `SqlValidator`, move 3 AI services
- **Phase 1b (future plan):** extract 5 analysis classes (`TableSizes`, `DuplicateIndexes`, `QueryStats`, `UnusedIndexes`, `ServerOverview`), extract `Core::QueryRunner` and `Core::QueryExplainer`, version bumps, CHANGELOG, paired release of `mysql_genius-core 0.1.0` + `mysql_genius 0.4.0`

**Two deviations from the spec, both intentional:**

1. **Phase 1 is split into 1a and 1b.** The spec described Phase 1 as one phase, but the actual scope (after reading every file involved) is large enough that a single plan would have ~100 tasks with no natural checkpoint for review. 1a delivers the foundation and AI moves; 1b delivers the analyses and release.

2. **ERB template extraction is deferred.** The spec §4.1 said templates move to `mysql_genius-core/lib/mysql_genius/core/views/` in Phase 1. After reading `app/views/mysql_genius/queries/index.html.erb`, we found it uses Rails route helpers heavily (`<%= mysql_genius.columns_path %>` and 17 similar) plus Rails partial rendering (`<%= render "mysql_genius/queries/tab_dashboard" %>`). Moving these requires a helper shim that works in both Rails and non-Rails contexts — non-trivial design work that should be its own effort once Phase 2 (desktop sidecar) has a concrete consumer. Templates stay in the Rails adapter for now. Phase 2 or a dedicated template-extraction plan will address them.

**Zero behavior change.** The Rails engine's public API (mountpoint, routes, config DSL, auth lambda, JSON response shapes) must be byte-identical after this plan. The existing RSpec suite must continue to pass with no expected-failure adjustments. Evidence of success is: `bundle exec rspec` green, `bundle exec rubocop` green, no new warnings.

---

## File Structure

After this plan, the repo will have this shape:

```
mysql_genius/                         (repo root — Rails adapter, existing gem)
├── app/
│   ├── controllers/
│   │   ├── concerns/mysql_genius/
│   │   │   ├── query_execution.rb     (MODIFIED — uses Core::SqlValidator)
│   │   │   ├── database_analysis.rb   (unchanged — Phase 1b)
│   │   │   └── ai_features.rb         (MODIFIED — uses Core::Ai::Client/Suggestion/Optimization)
│   │   ├── base_controller.rb         (unchanged)
│   │   └── queries_controller.rb      (unchanged)
│   └── services/mysql_genius/
│       ├── ai_client.rb               (DELETED — moved to core)
│       ├── ai_suggestion_service.rb   (DELETED — moved to core)
│       └── ai_optimization_service.rb (DELETED — moved to core)
├── lib/
│   ├── mysql_genius.rb                (MODIFIED — requires mysql_genius/core)
│   └── mysql_genius/
│       ├── version.rb                 (unchanged)
│       ├── configuration.rb           (unchanged — Phase 1b may touch)
│       ├── engine.rb                  (unchanged)
│       ├── slow_query_monitor.rb      (unchanged — stays Rails-only)
│       ├── sql_validator.rb           (DELETED — moved to core)
│       └── core/
│           └── connection/
│               └── active_record_adapter.rb   (NEW — Rails-side adapter)
├── spec/
│   └── mysql_genius/
│       ├── sql_validator_spec.rb           (DELETED — moved to core)
│       ├── ai_client_spec.rb               (DELETED — moved to core)
│       ├── ai_suggestion_service_spec.rb   (DELETED — moved to core)
│       ├── ai_optimization_service_spec.rb (DELETED — moved to core)
│       └── core/
│           └── connection/
│               └── active_record_adapter_spec.rb  (NEW)
├── mysql_genius.gemspec                (unchanged until Phase 1b release)
├── Gemfile                             (MODIFIED — path dep on mysql_genius-core)
│
└── gems/
    └── mysql_genius-core/              (NEW gem)
        ├── mysql_genius-core.gemspec
        ├── Gemfile
        ├── Rakefile
        ├── .rspec
        ├── lib/
        │   ├── mysql_genius/
        │   │   └── core.rb             (entry point — requires every core file)
        │   └── mysql_genius/core/
        │       ├── version.rb
        │       ├── sql_validator.rb
        │       ├── result.rb
        │       ├── server_info.rb
        │       ├── column_definition.rb
        │       ├── index_definition.rb
        │       ├── connection.rb       (contract module)
        │       ├── connection/
        │       │   └── fake_adapter.rb (test helper)
        │       └── ai/
        │           ├── config.rb
        │           ├── client.rb
        │           ├── suggestion.rb
        │           └── optimization.rb
        └── spec/
            ├── spec_helper.rb
            └── mysql_genius/core/
                ├── sql_validator_spec.rb
                ├── result_spec.rb
                ├── server_info_spec.rb
                ├── column_definition_spec.rb
                ├── index_definition_spec.rb
                ├── connection/
                │   └── fake_adapter_spec.rb
                └── ai/
                    ├── client_spec.rb
                    ├── suggestion_spec.rb
                    └── optimization_spec.rb
```

**Design rationale for each file's responsibility:**

- `core/sql_validator.rb` — stateless SQL safety checks (SELECT-only, blocked tables, row limits, masked columns). Already stateless in the existing codebase; moving wholesale.
- `core/result.rb` — immutable value object for a query result: columns + rows + iteration. Adapter-agnostic.
- `core/server_info.rb` — vendor/version identifier (`:mysql` or `:mariadb`, version string). Used to pick timeout-hint syntax and for display.
- `core/column_definition.rb` — column metadata (name, type symbol, sql_type string, null?, default, primary_key?). Mirrors `ActiveRecord::ConnectionAdapters::Column`'s relevant fields.
- `core/index_definition.rb` — index metadata (name, columns array, unique?). Mirrors `ActiveRecord::ConnectionAdapters::IndexDefinition`.
- `core/connection.rb` — contract module documenting what every adapter must implement. Not an enforced interface (Ruby), but specs use it as a reference.
- `core/connection/fake_adapter.rb` — test helper. Lets you stub queries by regex + return canned results. Used by every core spec.
- `core/connection/active_record_adapter.rb` (in the Rails adapter gem) — wraps an `ActiveRecord::Base.connection` and implements the `Core::Connection` contract by delegating to AR.
- `core/ai/config.rb` — keyword-init Struct holding AI settings (endpoint, api_key, model, auth_style, system_context, client callable). Passed explicitly to AI services instead of reaching into globals.
- `core/ai/client.rb` — HTTP client talking to OpenAI-compatible APIs. Constructor takes `Ai::Config`.
- `core/ai/suggestion.rb` — generates a SELECT query from a natural-language prompt. Constructor takes `(connection, client, config)`.
- `core/ai/optimization.rb` — given SQL + EXPLAIN, suggests optimizations. Same constructor pattern.

Each file has one clear responsibility and can be understood without reading its neighbors.

---

## Stage A — Gem scaffold

Create the new gem's directory tree and prove it builds and the existing suite still runs.

### Task A1: Create the gems/mysql_genius-core/ directory skeleton

**Files:**
- Create: `gems/mysql_genius-core/` (and nested dirs)

- [ ] **Step 1: Create the directory tree**

```bash
mkdir -p gems/mysql_genius-core/lib/mysql_genius/core/connection
mkdir -p gems/mysql_genius-core/lib/mysql_genius/core/ai
mkdir -p gems/mysql_genius-core/spec/mysql_genius/core/connection
mkdir -p gems/mysql_genius-core/spec/mysql_genius/core/ai
```

- [ ] **Step 2: Verify the tree was created**

```bash
find gems/mysql_genius-core -type d
```

Expected output includes:
```
gems/mysql_genius-core
gems/mysql_genius-core/lib
gems/mysql_genius-core/lib/mysql_genius
gems/mysql_genius-core/lib/mysql_genius/core
gems/mysql_genius-core/lib/mysql_genius/core/connection
gems/mysql_genius-core/lib/mysql_genius/core/ai
gems/mysql_genius-core/spec
gems/mysql_genius-core/spec/mysql_genius
gems/mysql_genius-core/spec/mysql_genius/core
gems/mysql_genius-core/spec/mysql_genius/core/connection
gems/mysql_genius-core/spec/mysql_genius/core/ai
```

### Task A2: Write the mysql_genius-core gemspec

**Files:**
- Create: `gems/mysql_genius-core/mysql_genius-core.gemspec`
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/version.rb`

- [ ] **Step 1: Create `gems/mysql_genius-core/lib/mysql_genius/core/version.rb`**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    VERSION = "0.1.0.pre"
  end
end
```

Rationale: `0.1.0.pre` makes clear this is a pre-release until Phase 1b's paired release bumps it to `0.1.0`.

- [ ] **Step 2: Create `gems/mysql_genius-core/mysql_genius-core.gemspec`**

```ruby
# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "mysql_genius/core/version"

Gem::Specification.new do |spec|
  spec.name          = "mysql_genius-core"
  spec.version       = MysqlGenius::Core::VERSION
  spec.authors       = ["Antarr Byrd"]
  spec.email         = ["antarr.t.byrd@uth.tmc.edu"]

  spec.summary       = "Rails-free core library for MysqlGenius — validators, analyses, AI services."
  spec.description   = "Shared library used by the mysql_genius Rails engine and the mysql_genius-desktop " \
    "standalone app. Contains the SQL validator, query runner, database analyses, and AI services, all of " \
    "which take an explicit connection abstraction (no globals, no ActiveRecord dependency)."
  spec.homepage      = "https://github.com/antarr/mysql_genius"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    Dir.glob("lib/**/*.rb") + ["mysql_genius-core.gemspec", "README.md"].select { |f| File.exist?(File.join(__dir__, f)) }
  end
  spec.require_paths = ["lib"]

  # No runtime dependencies — core is intentionally stdlib-only.
  # (trilogy is a Phase 2 addition for the desktop adapter; the Rails adapter
  # brings its own ActiveRecord connection.)
end
```

### Task A3: Create the core library entry point

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core.rb`

- [ ] **Step 1: Write the entry point file**

```ruby
# frozen_string_literal: true

require "mysql_genius/core/version"

module MysqlGenius
  # The Rails-free core library. Consumed by both the `mysql_genius` Rails
  # adapter gem and (from Phase 2 onward) the `mysql_genius-desktop` gem.
  #
  # See `docs/superpowers/specs/2026-04-10-desktop-app-design.md` for the
  # overall design.
  module Core
    class Error < StandardError; end
  end
end

# Value objects and the connection contract. New requires get added in later
# tasks in this plan.
```

This file will grow as subsequent tasks add `require` lines for new core files. For now it only establishes the namespace and the base error class.

### Task A4: Create the core gem's RSpec setup

**Files:**
- Create: `gems/mysql_genius-core/spec/spec_helper.rb`
- Create: `gems/mysql_genius-core/.rspec`
- Create: `gems/mysql_genius-core/Rakefile`
- Create: `gems/mysql_genius-core/Gemfile`

- [ ] **Step 1: Create `gems/mysql_genius-core/.rspec`**

```
--require spec_helper
--color
--format documentation
```

- [ ] **Step 2: Create `gems/mysql_genius-core/spec/spec_helper.rb`**

```ruby
# frozen_string_literal: true

require "bundler/setup"
require "mysql_genius/core"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with(:rspec) do |c|
    c.syntax = :expect
  end
end
```

Note: deliberately simpler than the parent gem's `spec_helper.rb`. No `ActiveRecord::Base` stub is needed — core has no ActiveRecord dependency, and specs use `Core::Connection::FakeAdapter` (to be added in Stage E) instead of mocking AR.

- [ ] **Step 3: Create `gems/mysql_genius-core/Gemfile`**

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake"
  gem "rspec", "~> 3.0"
  gem "rubocop"
  gem "rubocop-shopify"
  gem "rubocop-rspec"
end
```

- [ ] **Step 4: Create `gems/mysql_genius-core/Rakefile`**

```ruby
# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec
```

### Task A5: Wire the core gem into the root Gemfile

**Files:**
- Modify: `Gemfile`

- [ ] **Step 1: Read the current Gemfile**

```bash
cat Gemfile
```

- [ ] **Step 2: Add the path dependency for mysql_genius-core**

Edit `Gemfile` and add this line after the existing `gemspec` line:

```ruby
gem "mysql_genius-core", path: "gems/mysql_genius-core"
```

The resulting file should look like:

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "mysql_genius-core", path: "gems/mysql_genius-core"

if ENV["RAILS_VERSION"]
  rails_version = ENV["RAILS_VERSION"]
  gem "actionpack", "~> #{rails_version}.0"
  gem "activerecord", "~> #{rails_version}.0"
  gem "railties", "~> #{rails_version}.0"
end

group :development, :test do
  gem "rake"
  gem "rspec", "~> 3.0"
  gem "rubocop"
  gem "rubocop-shopify"
  gem "rubocop-rspec"
end
```

### Task A6: Verify the scaffold builds and existing specs still pass

- [ ] **Step 1: Run bundle install**

```bash
bundle install
```

Expected: succeeds, resolves `mysql_genius-core` from the path. No version conflicts.

- [ ] **Step 2: Run the existing (Rails adapter) test suite**

```bash
bundle exec rspec
```

Expected: all existing specs pass. The scaffold introduces no behavior and no new specs yet.

- [ ] **Step 3: Commit**

```bash
git add gems/mysql_genius-core Gemfile
git commit -m "Add mysql_genius-core gem scaffold

Empty scaffold for the new core gem that will hold Rails-free shared
code consumed by both the Rails adapter and the upcoming desktop app.
No code moved yet; the existing test suite continues to pass."
```

---

## Stage B — Move SqlValidator to Core

Move the stateless `SqlValidator` module to core as the first real code migration. The module is stateless and has no dependencies, so this is the simplest real move.

### Task B1: Write the new core spec for SqlValidator

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/sql_validator_spec.rb`

- [ ] **Step 1: Create the spec file**

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::SqlValidator) do
  let(:blocked_tables) { ["sessions", "authentication_tokens"] }
  let(:all_tables) { ["users", "posts", "sessions", "authentication_tokens"] }
  let(:connection) do
    double("connection", tables: all_tables)
  end

  def validate(sql)
    described_class.validate(sql, blocked_tables: blocked_tables, connection: connection)
  end

  describe ".validate" do
    it "rejects blank queries" do
      expect(validate("")).to(eq("Please enter a query."))
      expect(validate(nil)).to(eq("Please enter a query."))
    end

    it "rejects non-SELECT queries" do
      expect(validate("DELETE FROM users")).to(eq("Only SELECT queries are allowed."))
    end

    it "allows SELECT queries" do
      expect(validate("SELECT * FROM users")).to(be_nil)
    end

    it "allows WITH (CTE) queries" do
      expect(validate("WITH cte AS (SELECT 1) SELECT * FROM cte")).to(be_nil)
    end

    it "rejects INSERT statements" do
      expect(validate("SELECT * FROM users; INSERT INTO users VALUES (1)")).to(include("INSERT"))
    end

    it "rejects DROP statements" do
      expect(validate("SELECT * FROM users; DROP TABLE users")).to(include("DROP"))
    end

    it "rejects queries against blocked tables" do
      result = validate("SELECT * FROM sessions")
      expect(result).to(include("sessions"))
    end

    it "rejects queries accessing information_schema" do
      result = validate("SELECT * FROM information_schema.tables")
      expect(result).to(include("system schemas"))
    end

    it "rejects queries accessing mysql system schema" do
      result = validate("SELECT * FROM mysql.user")
      expect(result).to(include("system schemas"))
    end

    it "strips SQL comments before validation" do
      expect(validate("SELECT * FROM users -- safe query")).to(be_nil)
    end
  end

  describe ".extract_table_references" do
    it "extracts tables from FROM clause" do
      tables = described_class.extract_table_references("SELECT * FROM users", connection)
      expect(tables).to(include("users"))
    end

    it "extracts tables from JOIN clause" do
      tables = described_class.extract_table_references("SELECT * FROM users JOIN posts ON users.id = posts.user_id", connection)
      expect(tables).to(include("users", "posts"))
    end

    it "extracts comma-separated tables" do
      tables = described_class.extract_table_references("SELECT * FROM users, posts", connection)
      expect(tables).to(include("users", "posts"))
    end

    it "handles backtick-quoted table names" do
      tables = described_class.extract_table_references("SELECT * FROM `users`", connection)
      expect(tables).to(include("users"))
    end
  end

  describe ".apply_row_limit" do
    it "appends LIMIT when none exists" do
      result = described_class.apply_row_limit("SELECT * FROM users", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 25"))
    end

    it "caps existing LIMIT to the configured max" do
      result = described_class.apply_row_limit("SELECT * FROM users LIMIT 5000", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 25"))
    end

    it "preserves lower LIMIT" do
      result = described_class.apply_row_limit("SELECT * FROM users LIMIT 10", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 10"))
    end

    it "handles LIMIT with offset" do
      result = described_class.apply_row_limit("SELECT * FROM users LIMIT 100, 5000", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 100, 25"))
    end

    it "strips trailing semicolons" do
      result = described_class.apply_row_limit("SELECT * FROM users;", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 25"))
    end
  end

  describe ".masked_column?" do
    let(:patterns) { ["password", "secret", "digest", "token"] }

    it "masks columns containing 'password'" do
      expect(described_class.masked_column?("encrypted_password", patterns)).to(be(true))
    end

    it "masks columns containing 'token'" do
      expect(described_class.masked_column?("reset_token", patterns)).to(be(true))
    end

    it "masks columns containing 'secret'" do
      expect(described_class.masked_column?("api_secret", patterns)).to(be(true))
    end

    it "does not mask normal columns" do
      expect(described_class.masked_column?("email", patterns)).to(be(false))
    end

    it "is case insensitive" do
      expect(described_class.masked_column?("Password_Hash", patterns)).to(be(true))
    end
  end
end
```

This is a direct copy of the existing `spec/mysql_genius/sql_validator_spec.rb`, with the constant reference changed from `MysqlGenius::SqlValidator` to `MysqlGenius::Core::SqlValidator`.

### Task B2: Run the new spec to verify it fails

- [ ] **Step 1: Run the new spec**

```bash
cd gems/mysql_genius-core && bundle install && bundle exec rspec spec/mysql_genius/core/sql_validator_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::SqlValidator` because we haven't written the implementation yet.

### Task B3: Create the moved SqlValidator in core

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/sql_validator.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    module SqlValidator
      FORBIDDEN_KEYWORDS = ["INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "CREATE", "TRUNCATE", "GRANT", "REVOKE"].freeze

      extend self

      def validate(sql, blocked_tables:, connection:)
        return "Please enter a query." if sql.nil? || sql.strip.empty?

        normalized = sql.gsub(/--.*$/, "").gsub(%r{/\*.*?\*/}m, "").strip

        unless normalized.match?(/\ASELECT\b/i) || normalized.match?(/\AWITH\b/i)
          return "Only SELECT queries are allowed."
        end

        return "Access to system schemas is not allowed." if normalized.match?(/\b(information_schema|mysql|performance_schema|sys)\b/i)

        FORBIDDEN_KEYWORDS.each do |keyword|
          return "#{keyword} statements are not allowed." if normalized.match?(/\b#{keyword}\b/i)
        end

        tables_in_query = extract_table_references(normalized, connection)
        blocked = tables_in_query & blocked_tables
        if blocked.any?
          return "Access denied for table(s): #{blocked.join(", ")}."
        end

        nil
      end

      def extract_table_references(sql, connection)
        tables = []
        sql.scan(/\bFROM\s+((?:`?\w+`?(?:\s*,\s*`?\w+`?)*)+)/i) { |m| m[0].scan(/`?(\w+)`?/) { |t| tables << t[0] } }
        sql.scan(/\bJOIN\s+`?(\w+)`?/i) { |m| tables << m[0] }
        sql.scan(/\b(?:INTO|UPDATE)\s+`?(\w+)`?/i) { |m| tables << m[0] }
        tables.uniq.map(&:downcase) & connection.tables
      end

      def apply_row_limit(sql, limit)
        if sql.match?(/\bLIMIT\s+\d+\s*,\s*\d+/i)
          sql.gsub(/\bLIMIT\s+(\d+)\s*,\s*(\d+)/i) do
            "LIMIT #{::Regexp.last_match(1).to_i}, #{[::Regexp.last_match(2).to_i, limit].min}"
          end
        elsif sql.match?(/\bLIMIT\s+\d+/i)
          sql.gsub(/\bLIMIT\s+(\d+)/i) { "LIMIT #{[::Regexp.last_match(1).to_i, limit].min}" }
        else
          "#{sql.gsub(/;\s*\z/, "")} LIMIT #{limit}"
        end
      end

      def masked_column?(column_name, patterns)
        patterns.any? { |pattern| column_name.downcase.include?(pattern) }
      end
    end
  end
end
```

This is the existing `lib/mysql_genius/sql_validator.rb` with the module wrapped in `MysqlGenius::Core` instead of `MysqlGenius`. The implementation is byte-identical.

### Task B4: Require the new file from core.rb

**Files:**
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`

- [ ] **Step 1: Add the require**

Change `gems/mysql_genius-core/lib/mysql_genius/core.rb` to:

```ruby
# frozen_string_literal: true

require "mysql_genius/core/version"

module MysqlGenius
  # The Rails-free core library. Consumed by both the `mysql_genius` Rails
  # adapter gem and (from Phase 2 onward) the `mysql_genius-desktop` gem.
  #
  # See `docs/superpowers/specs/2026-04-10-desktop-app-design.md` for the
  # overall design.
  module Core
    class Error < StandardError; end
  end
end

require "mysql_genius/core/sql_validator"
```

### Task B5: Run the core spec to verify pass

- [ ] **Step 1: Run the core spec**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/sql_validator_spec.rb
```

Expected: all 20 examples pass.

### Task B6: Update the Rails adapter to use Core::SqlValidator and delete the old one

**Files:**
- Delete: `lib/mysql_genius/sql_validator.rb`
- Delete: `spec/mysql_genius/sql_validator_spec.rb`
- Modify: `lib/mysql_genius.rb`
- Modify: `app/controllers/concerns/mysql_genius/query_execution.rb`
- Modify: `app/controllers/concerns/mysql_genius/ai_features.rb`

- [ ] **Step 1: Update `lib/mysql_genius.rb`**

Change the top of the file to require `mysql_genius/core` instead of the local `mysql_genius/sql_validator`:

```ruby
# frozen_string_literal: true

require "mysql_genius/version"
require "mysql_genius/core"
require "mysql_genius/configuration"

module MysqlGenius
  class Error < StandardError; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end

require "mysql_genius/engine" if defined?(Rails)
```

- [ ] **Step 2: Update `app/controllers/concerns/mysql_genius/query_execution.rb`**

Find these two method definitions:

```ruby
def validate_sql(sql)
  SqlValidator.validate(sql, blocked_tables: mysql_genius_config.blocked_tables, connection: ActiveRecord::Base.connection)
end
```

and

```ruby
def apply_row_limit(sql, limit)
  SqlValidator.apply_row_limit(sql, limit)
end
```

and

```ruby
def masked_column?(column_name)
  SqlValidator.masked_column?(column_name, mysql_genius_config.masked_column_patterns)
end
```

Replace each `SqlValidator` reference with `MysqlGenius::Core::SqlValidator`:

```ruby
def validate_sql(sql)
  MysqlGenius::Core::SqlValidator.validate(sql, blocked_tables: mysql_genius_config.blocked_tables, connection: ActiveRecord::Base.connection)
end

def apply_row_limit(sql, limit)
  MysqlGenius::Core::SqlValidator.apply_row_limit(sql, limit)
end

def masked_column?(column_name)
  MysqlGenius::Core::SqlValidator.masked_column?(column_name, mysql_genius_config.masked_column_patterns)
end
```

- [ ] **Step 3: Update `app/controllers/concerns/mysql_genius/ai_features.rb`**

Find these two references:

```ruby
tables_in_query = SqlValidator.extract_table_references(sql, connection)
```

```ruby
tables = SqlValidator.extract_table_references(sql, connection)
```

Replace each with `MysqlGenius::Core::SqlValidator.extract_table_references(...)`:

```ruby
tables_in_query = MysqlGenius::Core::SqlValidator.extract_table_references(sql, connection)
```

```ruby
tables = MysqlGenius::Core::SqlValidator.extract_table_references(sql, connection)
```

- [ ] **Step 4: Delete the old SqlValidator file**

```bash
rm lib/mysql_genius/sql_validator.rb
```

- [ ] **Step 5: Delete the old SqlValidator spec**

```bash
rm spec/mysql_genius/sql_validator_spec.rb
```

- [ ] **Step 6: Run the full Rails adapter spec suite**

```bash
bundle exec rspec
```

Expected: all remaining specs pass. If anything references the deleted `MysqlGenius::SqlValidator` constant, the failures will point to it — fix by updating to `MysqlGenius::Core::SqlValidator`.

- [ ] **Step 7: Run the core spec suite**

```bash
(cd gems/mysql_genius-core && bundle exec rspec)
```

Expected: all core specs pass (currently just `sql_validator_spec.rb`).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Move SqlValidator to mysql_genius-core

Extract the stateless SQL validator into the new core gem. The Rails
adapter's query_execution and ai_features concerns now delegate to
MysqlGenius::Core::SqlValidator. Specs move with the code.

No behavior change — existing suite passes unchanged."
```

---

## Stage C — Value objects

Create the immutable value objects that `Core::Connection` and its adapters return: `Result`, `ServerInfo`, `ColumnDefinition`, `IndexDefinition`. All four are simple keyword-init Structs with a light API.

### Task C1: Write specs for all four value objects

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/result_spec.rb`
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/server_info_spec.rb`
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/column_definition_spec.rb`
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/index_definition_spec.rb`

- [ ] **Step 1: Create `result_spec.rb`**

```ruby
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
```

- [ ] **Step 2: Create `server_info_spec.rb`**

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::ServerInfo) do
  describe ".parse" do
    it "recognises MySQL from a version string" do
      info = described_class.parse("8.0.35")
      expect(info.vendor).to(eq(:mysql))
      expect(info.version).to(eq("8.0.35"))
    end

    it "recognises MariaDB from a version string containing 'MariaDB'" do
      info = described_class.parse("10.11.5-MariaDB-1:10.11.5+maria~ubu2204")
      expect(info.vendor).to(eq(:mariadb))
      expect(info.version).to(eq("10.11.5-MariaDB-1:10.11.5+maria~ubu2204"))
    end

    it "recognises MariaDB case-insensitively" do
      info = described_class.parse("10.4.30-mariadb-log")
      expect(info.vendor).to(eq(:mariadb))
    end
  end

  describe "#mariadb?" do
    it "is true for MariaDB" do
      expect(described_class.new(vendor: :mariadb, version: "10.11").mariadb?).to(be(true))
    end

    it "is false for MySQL" do
      expect(described_class.new(vendor: :mysql, version: "8.0").mariadb?).to(be(false))
    end
  end

  describe "#mysql?" do
    it "is true for MySQL" do
      expect(described_class.new(vendor: :mysql, version: "8.0").mysql?).to(be(true))
    end

    it "is false for MariaDB" do
      expect(described_class.new(vendor: :mariadb, version: "10.11").mysql?).to(be(false))
    end
  end
end
```

- [ ] **Step 3: Create `column_definition_spec.rb`**

```ruby
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
```

- [ ] **Step 4: Create `index_definition_spec.rb`**

```ruby
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
```

### Task C2: Run the specs to verify they fail

- [ ] **Step 1: Run the new specs**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/result_spec.rb spec/mysql_genius/core/server_info_spec.rb spec/mysql_genius/core/column_definition_spec.rb spec/mysql_genius/core/index_definition_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Result` (and the others).

### Task C3: Implement Core::Result

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/result.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    # Immutable value object representing the result of a query.
    # Adapters translate their native result types into this shape.
    class Result
      include Enumerable

      attr_reader :columns, :rows

      def initialize(columns:, rows:)
        @columns = columns.freeze
        @rows = rows.freeze
        freeze
      end

      def each(&block)
        return @rows.each unless block

        @rows.each(&block)
      end

      def to_a
        @rows.dup
      end

      def count
        @rows.length
      end

      def empty?
        @rows.empty?
      end

      # Returns rows as an array of hashes keyed by column name. Mirrors
      # ActiveRecord::Result#to_a's hashification behavior.
      def to_hashes
        @rows.map { |row| @columns.zip(row).to_h }
      end
    end
  end
end
```

### Task C4: Implement Core::ServerInfo

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/server_info.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    # Identifies the database vendor and version. Adapters construct one
    # from the server's VERSION() output.
    class ServerInfo
      attr_reader :vendor, :version

      # vendor must be :mysql or :mariadb
      def initialize(vendor:, version:)
        @vendor = vendor
        @version = version
        freeze
      end

      def self.parse(version_string)
        vendor = version_string.to_s.downcase.include?("mariadb") ? :mariadb : :mysql
        new(vendor: vendor, version: version_string)
      end

      def mariadb?
        @vendor == :mariadb
      end

      def mysql?
        @vendor == :mysql
      end
    end
  end
end
```

### Task C5: Implement Core::ColumnDefinition

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/column_definition.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    # Column metadata as returned by Core::Connection#columns_for. Mirrors
    # the subset of ActiveRecord::ConnectionAdapters::Column that the
    # analyses and AI services rely on.
    class ColumnDefinition
      attr_reader :name, :type, :sql_type, :null, :default, :primary_key

      def initialize(name:, type:, sql_type:, null:, default:, primary_key:)
        @name = name
        @type = type
        @sql_type = sql_type
        @null = null
        @default = default
        @primary_key = primary_key
        freeze
      end

      def null?
        @null
      end

      def primary_key?
        @primary_key
      end
    end
  end
end
```

### Task C6: Implement Core::IndexDefinition

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/index_definition.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    # Index metadata as returned by Core::Connection#indexes_for. Mirrors
    # the subset of ActiveRecord::ConnectionAdapters::IndexDefinition that
    # the analyses rely on.
    class IndexDefinition
      attr_reader :name, :columns, :unique

      def initialize(name:, columns:, unique:)
        @name = name
        @columns = columns.freeze
        @unique = unique
        freeze
      end

      def unique?
        @unique
      end
    end
  end
end
```

### Task C7: Require all value objects from core.rb

**Files:**
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`

- [ ] **Step 1: Add the requires**

Update `gems/mysql_genius-core/lib/mysql_genius/core.rb` to:

```ruby
# frozen_string_literal: true

require "mysql_genius/core/version"

module MysqlGenius
  module Core
    class Error < StandardError; end
  end
end

require "mysql_genius/core/result"
require "mysql_genius/core/server_info"
require "mysql_genius/core/column_definition"
require "mysql_genius/core/index_definition"
require "mysql_genius/core/sql_validator"
```

### Task C8: Run all four specs and the full suite

- [ ] **Step 1: Run the core specs**

```bash
cd gems/mysql_genius-core && bundle exec rspec
```

Expected: all specs pass (SqlValidator from Stage B + Result + ServerInfo + ColumnDefinition + IndexDefinition from Stage C).

- [ ] **Step 2: Run the Rails adapter specs**

```bash
bundle exec rspec
```

Expected: all existing specs still pass.

- [ ] **Step 3: Commit**

```bash
git add gems/mysql_genius-core
git commit -m "Add Core value objects: Result, ServerInfo, ColumnDefinition, IndexDefinition

Immutable frozen value objects for query results, server identification,
and column/index metadata. Adapters will translate their native result
types into these shapes."
```

---

## Stage D — Core::Connection contract + FakeAdapter

Create the contract module documenting what every connection adapter must implement, and the `FakeAdapter` test helper that subsequent tests (AI services, future analyses) will use.

### Task D1: Write the spec for FakeAdapter

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/connection/fake_adapter_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Connection::FakeAdapter) do
  subject(:adapter) { described_class.new }

  describe "#exec_query" do
    it "returns stubbed results matching a regex" do
      adapter.stub_query(
        /SELECT .* FROM users/i,
        columns: ["id", "name"],
        rows: [[1, "Alice"]],
      )

      result = adapter.exec_query("SELECT id, name FROM users")

      expect(result).to(be_a(MysqlGenius::Core::Result))
      expect(result.columns).to(eq(["id", "name"]))
      expect(result.rows).to(eq([[1, "Alice"]]))
    end

    it "raises when no stub matches" do
      expect { adapter.exec_query("SELECT 1") }.to(
        raise_error(MysqlGenius::Core::Connection::FakeAdapter::NoStubError, /No stub matched/),
      )
    end

    it "matches stubs in the order they were registered" do
      adapter.stub_query(/FROM users/, columns: ["a"], rows: [[1]])
      adapter.stub_query(/FROM users/, columns: ["b"], rows: [[2]])

      # First matching stub wins
      expect(adapter.exec_query("SELECT * FROM users").rows).to(eq([[1]]))
    end

    it "allows a stub to raise an error" do
      adapter.stub_query(/FROM users/, raises: StandardError.new("boom"))

      expect { adapter.exec_query("SELECT * FROM users") }.to(raise_error(StandardError, "boom"))
    end
  end

  describe "#select_value" do
    it "returns the first value of the first row of a stubbed query" do
      adapter.stub_query(/VERSION/, columns: ["VERSION()"], rows: [["8.0.35"]])

      expect(adapter.select_value("SELECT VERSION()")).to(eq("8.0.35"))
    end

    it "returns nil when the result is empty" do
      adapter.stub_query(/SELECT/, columns: ["x"], rows: [])

      expect(adapter.select_value("SELECT x FROM empty_table")).to(be_nil)
    end
  end

  describe "#server_version" do
    it "returns a ServerInfo built from a stubbed version" do
      adapter.stub_server_version("8.0.35")

      info = adapter.server_version
      expect(info).to(be_a(MysqlGenius::Core::ServerInfo))
      expect(info.vendor).to(eq(:mysql))
      expect(info.version).to(eq("8.0.35"))
    end

    it "detects MariaDB" do
      adapter.stub_server_version("10.11.5-MariaDB")

      expect(adapter.server_version.vendor).to(eq(:mariadb))
    end
  end

  describe "#current_database" do
    it "returns the stubbed database name" do
      adapter.stub_current_database("app_production")

      expect(adapter.current_database).to(eq("app_production"))
    end
  end

  describe "#quote" do
    it "wraps strings in single quotes" do
      expect(adapter.quote("hello")).to(eq("'hello'"))
    end

    it "escapes embedded single quotes" do
      expect(adapter.quote("O'Brien")).to(eq("'O''Brien'"))
    end

    it "returns integers as their decimal representation" do
      expect(adapter.quote(42)).to(eq("42"))
    end

    it "returns NULL for nil" do
      expect(adapter.quote(nil)).to(eq("NULL"))
    end
  end

  describe "#quote_table_name" do
    it "wraps an identifier in backticks" do
      expect(adapter.quote_table_name("users")).to(eq("`users`"))
    end
  end

  describe "#tables" do
    it "returns the stubbed table list" do
      adapter.stub_tables(["users", "posts"])

      expect(adapter.tables).to(eq(["users", "posts"]))
    end

    it "returns an empty array by default" do
      expect(adapter.tables).to(eq([]))
    end
  end

  describe "#columns_for" do
    it "returns the stubbed columns for a table" do
      col = MysqlGenius::Core::ColumnDefinition.new(
        name: "id", type: :integer, sql_type: "bigint", null: false, default: nil, primary_key: true,
      )
      adapter.stub_columns_for("users", [col])

      expect(adapter.columns_for("users")).to(eq([col]))
    end

    it "returns an empty array for unknown tables" do
      expect(adapter.columns_for("unknown")).to(eq([]))
    end
  end

  describe "#indexes_for" do
    it "returns the stubbed indexes for a table" do
      idx = MysqlGenius::Core::IndexDefinition.new(name: "idx_a", columns: ["a"], unique: true)
      adapter.stub_indexes_for("users", [idx])

      expect(adapter.indexes_for("users")).to(eq([idx]))
    end

    it "returns an empty array for unknown tables" do
      expect(adapter.indexes_for("unknown")).to(eq([]))
    end
  end

  describe "#primary_key" do
    it "returns the stubbed primary key for a table" do
      adapter.stub_primary_key("users", "id")

      expect(adapter.primary_key("users")).to(eq("id"))
    end

    it "returns nil by default" do
      expect(adapter.primary_key("x")).to(be_nil)
    end
  end

  describe "#close" do
    it "is a no-op that returns nil" do
      expect(adapter.close).to(be_nil)
    end
  end
end
```

### Task D2: Run the spec to verify it fails

- [ ] **Step 1: Run the spec**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/connection/fake_adapter_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Connection`.

### Task D3: Create the Connection contract module

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/connection.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    # Connection abstraction. This module is a namespace for concrete
    # adapters plus documentation of the contract every adapter must
    # satisfy. It is NOT meant to be included as a mixin; Ruby has no
    # interface enforcement. Tests exercise the contract via duck-typing
    # against the real adapters and the FakeAdapter test helper.
    #
    # Implementing adapters:
    #   MysqlGenius::Core::Connection::FakeAdapter        — in this gem, for tests
    #   MysqlGenius::Core::Connection::ActiveRecordAdapter — in mysql_genius (Rails adapter)
    #   MysqlGenius::Core::Connection::TrilogyAdapter      — in mysql_genius-desktop (Phase 2)
    #
    # Contract (every adapter must implement):
    #
    #   #exec_query(sql)                -> Core::Result
    #   #select_value(sql)              -> Object (first column of first row, or nil)
    #   #server_version                 -> Core::ServerInfo
    #   #current_database               -> String
    #   #quote(value)                   -> String (SQL-escaped value)
    #   #quote_table_name(name)         -> String (backtick-quoted identifier)
    #   #tables                         -> Array<String>
    #   #columns_for(table)             -> Array<Core::ColumnDefinition>
    #   #indexes_for(table)             -> Array<Core::IndexDefinition>
    #   #primary_key(table)             -> String or nil
    #   #close                          -> nil
    #
    # Adapters may implement additional methods for efficiency, but any
    # core code that depends on the connection must only call methods
    # defined in this contract.
    module Connection
    end
  end
end
```

### Task D4: Implement FakeAdapter

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/connection/fake_adapter.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    module Connection
      # In-memory fake connection used by core specs. Supports stubbing
      # queries by regex and returning canned Core::Result values, plus
      # stubbing metadata methods. See spec/mysql_genius/core/connection/
      # fake_adapter_spec.rb for the full surface.
      class FakeAdapter
        class NoStubError < StandardError; end

        def initialize
          @stubs = []
          @tables = []
          @columns_for = {}
          @indexes_for = {}
          @primary_keys = {}
          @server_version = "8.0.35"
          @current_database = "test_db"
        end

        # ----- stub registration -----

        def stub_query(pattern, columns: [], rows: [], raises: nil)
          @stubs << { pattern: pattern, columns: columns, rows: rows, raises: raises }
        end

        def stub_server_version(version)
          @server_version = version
        end

        def stub_current_database(name)
          @current_database = name
        end

        def stub_tables(list)
          @tables = list
        end

        def stub_columns_for(table, columns)
          @columns_for[table] = columns
        end

        def stub_indexes_for(table, indexes)
          @indexes_for[table] = indexes
        end

        def stub_primary_key(table, name)
          @primary_keys[table] = name
        end

        # ----- contract -----

        def exec_query(sql, binds: [])
          _ = binds
          stub = @stubs.find { |s| s[:pattern] =~ sql }
          raise NoStubError, "No stub matched SQL: #{sql}" unless stub
          raise stub[:raises] if stub[:raises]

          Result.new(columns: stub[:columns], rows: stub[:rows])
        end

        def select_value(sql)
          result = exec_query(sql)
          return nil if result.empty?

          result.rows.first&.first
        end

        def server_version
          ServerInfo.parse(@server_version)
        end

        def current_database
          @current_database
        end

        def quote(value)
          case value
          when nil then "NULL"
          when Integer, Float then value.to_s
          when String then "'#{value.gsub("'", "''")}'"
          else "'#{value.to_s.gsub("'", "''")}'"
          end
        end

        def quote_table_name(name)
          "`#{name}`"
        end

        def tables
          @tables
        end

        def columns_for(table)
          @columns_for.fetch(table, [])
        end

        def indexes_for(table)
          @indexes_for.fetch(table, [])
        end

        def primary_key(table)
          @primary_keys[table]
        end

        def close
          nil
        end
      end
    end
  end
end
```

### Task D5: Require Connection files from core.rb

**Files:**
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`

- [ ] **Step 1: Add the requires**

Update `gems/mysql_genius-core/lib/mysql_genius/core.rb` to:

```ruby
# frozen_string_literal: true

require "mysql_genius/core/version"

module MysqlGenius
  module Core
    class Error < StandardError; end
  end
end

require "mysql_genius/core/result"
require "mysql_genius/core/server_info"
require "mysql_genius/core/column_definition"
require "mysql_genius/core/index_definition"
require "mysql_genius/core/sql_validator"
require "mysql_genius/core/connection"
require "mysql_genius/core/connection/fake_adapter"
```

### Task D6: Run the core specs

- [ ] **Step 1: Run the core specs**

```bash
cd gems/mysql_genius-core && bundle exec rspec
```

Expected: all specs pass (previous stages + FakeAdapter's ~20 examples).

- [ ] **Step 2: Run the Rails adapter specs**

```bash
bundle exec rspec
```

Expected: still green.

- [ ] **Step 3: Commit**

```bash
git add gems/mysql_genius-core
git commit -m "Add Core::Connection contract + FakeAdapter test helper

Core::Connection is a namespace + contract documentation (Ruby has no
interfaces; the contract is documented and exercised by tests). The
FakeAdapter is an in-memory implementation used by core specs to avoid
depending on a real database."
```

---

## Stage E — ActiveRecordAdapter in the Rails gem

The Rails adapter gem gets a `Core::Connection::ActiveRecordAdapter` class that wraps an `ActiveRecord::Base.connection` and implements the contract. This is the bridge the Rails controllers will use when delegating to core services.

### Task E1: Write the adapter spec

**Files:**
- Create: `spec/mysql_genius/core/connection/active_record_adapter_spec.rb`

- [ ] **Step 1: Create the spec directory**

```bash
mkdir -p spec/mysql_genius/core/connection
```

- [ ] **Step 2: Write the spec file**

```ruby
# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core/connection/active_record_adapter"

RSpec.describe(MysqlGenius::Core::Connection::ActiveRecordAdapter) do
  let(:ar_connection) { double("ActiveRecord::Base.connection") }
  subject(:adapter) { described_class.new(ar_connection) }

  describe "#exec_query" do
    it "wraps an ActiveRecord::Result in a Core::Result" do
      ar_result = double("ActiveRecord::Result", columns: ["id", "name"], rows: [[1, "Alice"], [2, "Bob"]])
      expect(ar_connection).to(receive(:exec_query).with("SELECT id, name FROM users").and_return(ar_result))

      result = adapter.exec_query("SELECT id, name FROM users")

      expect(result).to(be_a(MysqlGenius::Core::Result))
      expect(result.columns).to(eq(["id", "name"]))
      expect(result.rows).to(eq([[1, "Alice"], [2, "Bob"]]))
    end
  end

  describe "#select_value" do
    it "delegates to the underlying connection" do
      expect(ar_connection).to(receive(:select_value).with("SELECT VERSION()").and_return("8.0.35"))

      expect(adapter.select_value("SELECT VERSION()")).to(eq("8.0.35"))
    end
  end

  describe "#server_version" do
    it "parses the version from SELECT VERSION()" do
      expect(ar_connection).to(receive(:select_value).with("SELECT VERSION()").and_return("8.0.35"))

      info = adapter.server_version
      expect(info.vendor).to(eq(:mysql))
      expect(info.version).to(eq("8.0.35"))
    end

    it "detects MariaDB" do
      expect(ar_connection).to(receive(:select_value).with("SELECT VERSION()").and_return("10.11.5-MariaDB"))

      expect(adapter.server_version.vendor).to(eq(:mariadb))
    end
  end

  describe "#current_database" do
    it "delegates" do
      expect(ar_connection).to(receive(:current_database).and_return("app_production"))

      expect(adapter.current_database).to(eq("app_production"))
    end
  end

  describe "#quote" do
    it "delegates" do
      expect(ar_connection).to(receive(:quote).with("hello").and_return("'hello'"))

      expect(adapter.quote("hello")).to(eq("'hello'"))
    end
  end

  describe "#quote_table_name" do
    it "delegates" do
      expect(ar_connection).to(receive(:quote_table_name).with("users").and_return("`users`"))

      expect(adapter.quote_table_name("users")).to(eq("`users`"))
    end
  end

  describe "#tables" do
    it "delegates" do
      expect(ar_connection).to(receive(:tables).and_return(["users", "posts"]))

      expect(adapter.tables).to(eq(["users", "posts"]))
    end
  end

  describe "#columns_for" do
    it "maps AR::ConnectionAdapters::Column instances to Core::ColumnDefinition" do
      ar_col = double(
        "AR column",
        name: "email",
        type: :string,
        sql_type: "varchar(255)",
        null: false,
        default: nil,
      )
      expect(ar_connection).to(receive(:columns).with("users").and_return([ar_col]))
      expect(ar_connection).to(receive(:primary_key).with("users").and_return("id"))

      columns = adapter.columns_for("users")

      expect(columns.length).to(eq(1))
      expect(columns.first).to(be_a(MysqlGenius::Core::ColumnDefinition))
      expect(columns.first.name).to(eq("email"))
      expect(columns.first.type).to(eq(:string))
      expect(columns.first.sql_type).to(eq("varchar(255)"))
      expect(columns.first.null).to(eq(false))
      expect(columns.first.primary_key).to(eq(false))
    end

    it "marks the primary key column correctly" do
      pk_col = double("AR column", name: "id", type: :integer, sql_type: "bigint", null: false, default: nil)
      expect(ar_connection).to(receive(:columns).with("users").and_return([pk_col]))
      expect(ar_connection).to(receive(:primary_key).with("users").and_return("id"))

      column = adapter.columns_for("users").first
      expect(column.primary_key?).to(be(true))
    end
  end

  describe "#indexes_for" do
    it "maps AR::ConnectionAdapters::IndexDefinition to Core::IndexDefinition" do
      ar_idx = double("AR index", name: "index_users_on_email", columns: ["email"], unique: true)
      expect(ar_connection).to(receive(:indexes).with("users").and_return([ar_idx]))

      indexes = adapter.indexes_for("users")

      expect(indexes.length).to(eq(1))
      expect(indexes.first).to(be_a(MysqlGenius::Core::IndexDefinition))
      expect(indexes.first.name).to(eq("index_users_on_email"))
      expect(indexes.first.columns).to(eq(["email"]))
      expect(indexes.first.unique).to(eq(true))
    end
  end

  describe "#primary_key" do
    it "delegates" do
      expect(ar_connection).to(receive(:primary_key).with("users").and_return("id"))

      expect(adapter.primary_key("users")).to(eq("id"))
    end
  end

  describe "#close" do
    it "is a no-op (AR manages the pool)" do
      expect(adapter.close).to(be_nil)
    end
  end
end
```

Note: specs use `double()` and `expect(...).to(receive(...))` matching the existing project style.

### Task E2: Run the spec to verify it fails

- [ ] **Step 1: Run the spec**

```bash
bundle exec rspec spec/mysql_genius/core/connection/active_record_adapter_spec.rb
```

Expected: FAIL with `LoadError: cannot load such file -- mysql_genius/core/connection/active_record_adapter`.

### Task E3: Implement the ActiveRecordAdapter

**Files:**
- Create: `lib/mysql_genius/core/connection/active_record_adapter.rb`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p lib/mysql_genius/core/connection
```

- [ ] **Step 2: Write the file**

```ruby
# frozen_string_literal: true

require "mysql_genius/core"

module MysqlGenius
  module Core
    module Connection
      # Wraps an ActiveRecord::Base.connection and implements the
      # Core::Connection contract. Lives in the mysql_genius (Rails
      # adapter) gem because it depends on ActiveRecord; the contract
      # itself lives in mysql_genius-core.
      class ActiveRecordAdapter
        def initialize(ar_connection)
          @ar = ar_connection
        end

        def exec_query(sql, binds: [])
          _ = binds
          ar_result = @ar.exec_query(sql)
          Core::Result.new(columns: ar_result.columns, rows: ar_result.rows)
        end

        def select_value(sql)
          @ar.select_value(sql)
        end

        def server_version
          Core::ServerInfo.parse(@ar.select_value("SELECT VERSION()").to_s)
        end

        def current_database
          @ar.current_database
        end

        def quote(value)
          @ar.quote(value)
        end

        def quote_table_name(name)
          @ar.quote_table_name(name)
        end

        def tables
          @ar.tables
        end

        def columns_for(table)
          pk = @ar.primary_key(table)
          @ar.columns(table).map do |c|
            Core::ColumnDefinition.new(
              name: c.name,
              type: c.type,
              sql_type: c.sql_type,
              null: c.null,
              default: c.default,
              primary_key: c.name == pk,
            )
          end
        end

        def indexes_for(table)
          @ar.indexes(table).map do |idx|
            Core::IndexDefinition.new(name: idx.name, columns: idx.columns, unique: idx.unique)
          end
        end

        def primary_key(table)
          @ar.primary_key(table)
        end

        def close
          nil
        end
      end
    end
  end
end
```

### Task E4: Run the adapter spec

- [ ] **Step 1: Run the spec**

```bash
bundle exec rspec spec/mysql_genius/core/connection/active_record_adapter_spec.rb
```

Expected: all ~15 examples pass.

- [ ] **Step 2: Run the full Rails adapter suite**

```bash
bundle exec rspec
```

Expected: everything green.

- [ ] **Step 3: Run the core suite**

```bash
(cd gems/mysql_genius-core && bundle exec rspec)
```

Expected: everything green.

- [ ] **Step 4: Commit**

```bash
git add lib/mysql_genius/core spec/mysql_genius/core
git commit -m "Add Core::Connection::ActiveRecordAdapter in Rails gem

Bridges ActiveRecord::Base.connection to the Core::Connection contract.
Controllers can now construct one of these and hand it to core services
— used in the next stages by the AI services."
```

---

## Stage F — Move AiClient to Core::Ai::Client

The existing `MysqlGenius::AiClient` reads from `MysqlGenius.configuration` at construction time. The new `Core::Ai::Client` takes an explicit `Core::Ai::Config` value object instead. The Rails adapter builds the Config from `MysqlGenius.configuration` on demand.

### Task F1: Write the Core::Ai::Config spec

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/ai/config_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Ai::Config) do
  it "exposes all keyword-init fields" do
    config = described_class.new(
      client: nil,
      endpoint: "https://api.example.com/v1/chat/completions",
      api_key: "sk-test",
      model: "gpt-4o",
      auth_style: :bearer,
      system_context: "Custom context",
    )

    expect(config.client).to(be_nil)
    expect(config.endpoint).to(eq("https://api.example.com/v1/chat/completions"))
    expect(config.api_key).to(eq("sk-test"))
    expect(config.model).to(eq("gpt-4o"))
    expect(config.auth_style).to(eq(:bearer))
    expect(config.system_context).to(eq("Custom context"))
  end

  describe "#enabled?" do
    it "is true when a custom client callable is set" do
      config = described_class.new(
        client: ->(**) { {} },
        endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(true))
    end

    it "is true when both endpoint and api_key are set" do
      config = described_class.new(
        client: nil, endpoint: "https://x", api_key: "k", model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(true))
    end

    it "is false when neither client nor endpoint+api_key are set" do
      config = described_class.new(
        client: nil, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(false))
    end

    it "is false when only endpoint is set without api_key" do
      config = described_class.new(
        client: nil, endpoint: "https://x", api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(false))
    end

    it "is false when endpoint is empty string" do
      config = described_class.new(
        client: nil, endpoint: "", api_key: "k", model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(false))
    end
  end
end
```

### Task F2: Write the Core::Ai::Client spec

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/ai/client_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

require "net/http"

RSpec.describe(MysqlGenius::Core::Ai::Client) do
  let(:config) do
    MysqlGenius::Core::Ai::Config.new(
      client: nil,
      endpoint: "https://api.example.com/v1/chat/completions",
      api_key: "sk-test-key",
      model: "gpt-4o",
      auth_style: :bearer,
      system_context: nil,
    )
  end

  subject(:client) { described_class.new(config) }

  def stub_http(response: nil, &block)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to(receive(:new).and_return(http))
    allow(http).to(receive(:use_ssl=))
    allow(http).to(receive(:verify_mode=))
    allow(http).to(receive(:ca_file=))
    allow(http).to(receive(:open_timeout=))
    allow(http).to(receive(:read_timeout=))
    allow(http).to(receive_messages(use_ssl?: false))
    if block
      allow(http).to(receive(:request, &block))
    elsif response
      allow(http).to(receive(:request).and_return(response))
    end
    http
  end

  def stub_http_with_block(&block)
    allow(Net::HTTP).to(receive(:new)) do
      http = instance_double(Net::HTTP)
      allow(http).to(receive(:use_ssl=))
      allow(http).to(receive(:verify_mode=))
      allow(http).to(receive(:ca_file=))
      allow(http).to(receive(:open_timeout=))
      allow(http).to(receive(:read_timeout=))
      allow(http).to(receive_messages(use_ssl?: false))
      block.call(http)
      http
    end
  end

  def ok_response(content)
    body = { "choices" => [{ "message" => { "content" => content } }] }.to_json
    instance_double(Net::HTTPOK, body: body).tap do |r|
      allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(false))
    end
  end

  describe "#chat" do
    context "with a custom client callable" do
      let(:config) do
        MysqlGenius::Core::Ai::Config.new(
          client: lambda { |**_kwargs| { "sql" => "SELECT 1", "explanation" => "test" } },
          endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
        )
      end

      it "delegates to the custom client" do
        result = client.chat(messages: [{ role: "user", content: "test" }])
        expect(result).to(eq({ "sql" => "SELECT 1", "explanation" => "test" }))
      end

      it "passes temperature through" do
        called_temp = nil
        callable = lambda { |temperature:, **| called_temp = temperature; {} }
        custom_config = MysqlGenius::Core::Ai::Config.new(
          client: callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
        )

        described_class.new(custom_config).chat(messages: [], temperature: 0.5)
        expect(called_temp).to(eq(0.5))
      end
    end

    context "when not configured" do
      let(:config) do
        MysqlGenius::Core::Ai::Config.new(
          client: nil, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
        )
      end

      it "raises an error" do
        expect { client.chat(messages: []) }.to(
          raise_error(MysqlGenius::Core::Ai::Client::NotConfigured, /AI is not configured/),
        )
      end
    end

    context "with an HTTP endpoint" do
      let(:http_response) { ok_response('{"sql":"SELECT 1"}') }

      before { stub_http(response: http_response) }

      it "returns parsed JSON from the response content" do
        result = client.chat(messages: [{ role: "user", content: "hello" }])
        expect(result).to(eq({ "sql" => "SELECT 1" }))
      end

      it "includes the model in the request body" do
        stub_http_with_block do |http|
          allow(http).to(receive(:request)) do |req|
            body = JSON.parse(req.body)
            expect(body["model"]).to(eq("gpt-4o"))
            http_response
          end
        end

        client.chat(messages: [])
      end

      it "uses Bearer auth when auth_style is :bearer" do
        stub_http_with_block do |http|
          allow(http).to(receive(:request)) do |req|
            expect(req["Authorization"]).to(eq("Bearer sk-test-key"))
            http_response
          end
        end

        client.chat(messages: [])
      end

      it "uses api-key header when auth_style is :api_key" do
        api_key_config = MysqlGenius::Core::Ai::Config.new(
          client: nil, endpoint: "https://api.example.com/v1/chat/completions",
          api_key: "sk-test-key", model: "gpt-4o", auth_style: :api_key, system_context: nil,
        )

        stub_http_with_block do |http|
          allow(http).to(receive(:request)) do |req|
            expect(req["api-key"]).to(eq("sk-test-key"))
            http_response
          end
        end

        described_class.new(api_key_config).chat(messages: [])
      end
    end

    context "when the API returns an error" do
      before do
        body = { "error" => { "message" => "Rate limit exceeded" } }.to_json
        response = instance_double(Net::HTTPOK, body: body).tap do |r|
          allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(false))
        end
        stub_http(response: response)
      end

      it "raises an error with the API message" do
        expect { client.chat(messages: []) }.to(
          raise_error(MysqlGenius::Core::Ai::Client::ApiError, /Rate limit exceeded/),
        )
      end
    end

    context "when the response has no content" do
      before do
        body = { "choices" => [{ "message" => { "content" => nil } }] }.to_json
        response = instance_double(Net::HTTPOK, body: body).tap do |r|
          allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(false))
        end
        stub_http(response: response)
      end

      it "raises an error" do
        expect { client.chat(messages: []) }.to(
          raise_error(MysqlGenius::Core::Ai::Client::ApiError, /No content/),
        )
      end
    end
  end

  describe "JSON parsing" do
    let(:current_response) { { value: nil } }

    before do
      response_holder = current_response
      stub_http { |_| response_holder[:value] }
    end

    it "parses plain JSON" do
      current_response[:value] = ok_response('{"sql":"SELECT 1"}')
      expect(client.chat(messages: [])).to(eq({ "sql" => "SELECT 1" }))
    end

    it "strips markdown code fences" do
      current_response[:value] = ok_response("```json\n{\"sql\":\"SELECT 1\"}\n```")
      expect(client.chat(messages: [])).to(eq({ "sql" => "SELECT 1" }))
    end

    it "strips code fences without language tag" do
      current_response[:value] = ok_response("```\n{\"sql\":\"SELECT 1\"}\n```")
      expect(client.chat(messages: [])).to(eq({ "sql" => "SELECT 1" }))
    end

    it "returns raw content when JSON is unparseable" do
      current_response[:value] = ok_response("This is not JSON at all")
      expect(client.chat(messages: [])).to(eq({ "raw" => "This is not JSON at all" }))
    end
  end

  describe "redirect handling" do
    it "follows redirects up to MAX_REDIRECTS" do
      redirect_response = instance_double(Net::HTTPRedirection, :[] => "https://api2.example.com/v1/chat").tap do |r|
        allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(true))
      end
      final_response = ok_response('{"ok":true}')

      call_count = 0
      stub_http_with_block do |http|
        allow(http).to(receive(:request)) do
          call_count += 1
          call_count == 1 ? redirect_response : final_response
        end
      end

      expect(client.chat(messages: [])).to(eq({ "ok" => true }))
      expect(call_count).to(eq(2))
    end

    it "raises on too many redirects" do
      redirect_response = instance_double(Net::HTTPRedirection, :[] => "https://api.example.com/loop").tap do |r|
        allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(true))
      end

      stub_http_with_block do |http|
        allow(http).to(receive(:request).and_return(redirect_response))
      end

      expect { client.chat(messages: []) }.to(
        raise_error(MysqlGenius::Core::Ai::Client::TooManyRedirects),
      )
    end
  end
end
```

Note: error classes are namespaced under `Core::Ai::Client::{NotConfigured, ApiError, TooManyRedirects}` instead of the generic `MysqlGenius::Error`. Clearer failure modes for callers.

### Task F3: Run the specs to verify they fail

- [ ] **Step 1: Run the specs**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/ai/
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Ai`.

### Task F4: Implement Core::Ai::Config

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/ai/config.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Keyword-init value object holding all the AI settings a Client
      # needs. Passed explicitly to every AI service constructor — no
      # module-level globals.
      #
      # Fields:
      #   client         - optional callable; when set, bypasses HTTP.
      #                    Signature: #call(messages:, temperature:) -> Hash
      #   endpoint       - HTTPS URL of the chat completions endpoint
      #   api_key        - API key (used as Bearer or api-key header)
      #   model          - model name passed in the request body
      #   auth_style     - :bearer or :api_key
      #   system_context - optional domain context string that services
      #                    append to their system prompts
      Config = Struct.new(
        :client,
        :endpoint,
        :api_key,
        :model,
        :auth_style,
        :system_context,
        keyword_init: true,
      ) do
        def enabled?
          return true if client
          return false if endpoint.nil? || endpoint.to_s.empty?
          return false if api_key.nil? || api_key.to_s.empty?

          true
        end
      end
    end
  end
end
```

### Task F5: Implement Core::Ai::Client

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/ai/client.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module MysqlGenius
  module Core
    module Ai
      # HTTP client for OpenAI-compatible chat completion APIs.
      # Construct with a Core::Ai::Config; call #chat with a messages array.
      class Client
        class NotConfigured < Core::Error; end
        class ApiError < Core::Error; end
        class TooManyRedirects < Core::Error; end

        MAX_REDIRECTS = 3

        def initialize(config)
          @config = config
        end

        def chat(messages:, temperature: 0)
          if @config.client
            return @config.client.call(messages: messages, temperature: temperature)
          end

          raise NotConfigured, "AI is not configured" unless @config.endpoint && @config.api_key

          body = {
            messages: messages,
            response_format: { type: "json_object" },
            temperature: temperature,
          }
          body[:model] = @config.model if @config.model && !@config.model.empty?

          response = post_with_redirects(URI(@config.endpoint), body.to_json)
          parsed = JSON.parse(response.body)

          if parsed["error"]
            raise ApiError, "AI API error: #{parsed["error"]["message"] || parsed["error"]}"
          end

          content = parsed.dig("choices", 0, "message", "content")
          raise ApiError, "No content in AI response" if content.nil?

          parse_json_content(content)
        end

        private

        def parse_json_content(content)
          JSON.parse(content)
        rescue JSON::ParserError
          stripped = content.to_s
            .gsub(/\A\s*```(?:json)?\s*/i, "")
            .gsub(/\s*```\s*\z/, "")
            .strip
          begin
            JSON.parse(stripped)
          rescue JSON::ParserError
            { "raw" => content.to_s }
          end
        end

        def post_with_redirects(uri, body, redirects = 0)
          raise TooManyRedirects, "Too many redirects" if redirects > MAX_REDIRECTS

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          if http.use_ssl?
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
            cert_file = ENV["SSL_CERT_FILE"] || OpenSSL::X509::DEFAULT_CERT_FILE
            http.ca_file = cert_file if File.exist?(cert_file)
          end
          http.open_timeout = 10
          http.read_timeout = 60

          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          if @config.auth_style == :bearer
            request["Authorization"] = "Bearer #{@config.api_key}"
          else
            request["api-key"] = @config.api_key
          end
          request.body = body

          response = http.request(request)

          if response.is_a?(Net::HTTPRedirection)
            post_with_redirects(URI(response["location"]), body, redirects + 1)
          else
            response
          end
        end
      end
    end
  end
end
```

### Task F6: Require the AI files from core.rb

**Files:**
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`

- [ ] **Step 1: Add the requires**

Update `gems/mysql_genius-core/lib/mysql_genius/core.rb` to:

```ruby
# frozen_string_literal: true

require "mysql_genius/core/version"

module MysqlGenius
  module Core
    class Error < StandardError; end
  end
end

require "mysql_genius/core/result"
require "mysql_genius/core/server_info"
require "mysql_genius/core/column_definition"
require "mysql_genius/core/index_definition"
require "mysql_genius/core/sql_validator"
require "mysql_genius/core/connection"
require "mysql_genius/core/connection/fake_adapter"
require "mysql_genius/core/ai/config"
require "mysql_genius/core/ai/client"
```

### Task F7: Run the core specs

- [ ] **Step 1: Run the core spec suite**

```bash
cd gems/mysql_genius-core && bundle exec rspec
```

Expected: all specs pass, including the new `Core::Ai::Config` and `Core::Ai::Client` specs.

### Task F8: Update the Rails adapter's 7 inline AI features to use Core::Ai::Client

Note on ordering: this stage **adds** `Core::Ai::Client` and wires the 7 inline AI features in the concern to use it, but does **not** delete the old `app/services/mysql_genius/ai_client.rb` yet. The old file still has two internal callers (`ai_suggestion_service.rb` and `ai_optimization_service.rb`) which get removed in Stages G and H. The old `AiClient.rb` is deleted at the very end of Stage H once nothing references it.

**Files:**
- Modify: `app/controllers/concerns/mysql_genius/ai_features.rb`

- [ ] **Step 1: Add two helpers to `app/controllers/concerns/mysql_genius/ai_features.rb`**

Find the `private` section near the bottom (around line 375, where `ai_not_configured`, `ai_domain_context`, and `build_schema_for_query` live) and add these two new helpers:

```ruby
def ai_client
  MysqlGenius::Core::Ai::Client.new(ai_config_for_core)
end

def ai_config_for_core
  cfg = mysql_genius_config
  MysqlGenius::Core::Ai::Config.new(
    client: cfg.ai_client,
    endpoint: cfg.ai_endpoint,
    api_key: cfg.ai_api_key,
    model: cfg.ai_model,
    auth_style: cfg.ai_auth_style,
    system_context: cfg.ai_system_context,
  )
end
```

- [ ] **Step 2: Replace every `AiClient.new.chat` call in the concern with `ai_client.chat`**

In `app/controllers/concerns/mysql_genius/ai_features.rb`, there are 7 lines reading:

```ruby
result = AiClient.new.chat(messages: messages)
```

These appear in: `describe_query`, `schema_review`, `rewrite_query`, `index_advisor`, `anomaly_detection`, `root_cause`, and `migration_risk`. Verify by running:

```bash
grep -n "AiClient.new.chat" app/controllers/concerns/mysql_genius/ai_features.rb
```

Expected: 7 matches.

Replace each one with:

```ruby
result = ai_client.chat(messages: messages)
```

After the replacements, re-run the grep:

```bash
grep -n "AiClient.new.chat" app/controllers/concerns/mysql_genius/ai_features.rb
```

Expected: 0 matches.

Note: We are NOT touching the `suggest` or `optimize` actions in this task. Those still call `AiSuggestionService.new.call(...)` and `AiOptimizationService.new.call(...)` respectively; those get updated in Stages G and H.

- [ ] **Step 3: Run the Rails adapter suite**

```bash
bundle exec rspec
```

Expected: all specs pass. The old `ai_client_spec.rb`, `ai_suggestion_service_spec.rb`, and `ai_optimization_service_spec.rb` still exist and still pass — we haven't deleted them yet. The old `AiClient.rb`, `AiSuggestionService.rb`, and `AiOptimizationService.rb` still exist and still work — the concern's 7 inline features now use `Core::Ai::Client` via the new helper, but the 2 services still use the old `AiClient` internally.

- [ ] **Step 4: Run the core gem's suite**

```bash
(cd gems/mysql_genius-core && bundle exec rspec)
```

Expected: all core specs pass.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Wire Core::Ai::Client into 7 inline AI features

The ai_features concern now uses Core::Ai::Client (via a helper) for
describe_query, schema_review, rewrite_query, index_advisor,
anomaly_detection, root_cause, and migration_risk. The 'suggest' and
'optimize' actions still use the old services; those move to core in
Stages G and H. The old AiClient class still exists because the two
un-moved services depend on it internally; it gets deleted at the end
of Stage H."
```

---

## Stage G — Move AiSuggestionService to Core::Ai::Suggestion

### Task G1: Write the Core::Ai::Suggestion spec

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/ai/suggestion_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Ai::Suggestion) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:ai_config) do
    MysqlGenius::Core::Ai::Config.new(
      client: lambda { |**_kwargs| { "sql" => "SELECT id FROM users", "explanation" => "returns all user ids" } },
      endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
    )
  end
  let(:client) { MysqlGenius::Core::Ai::Client.new(ai_config) }

  subject(:service) { described_class.new(connection, client, ai_config) }

  before do
    connection.stub_tables(["users", "posts"])
    connection.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", type: :integer, sql_type: "bigint", null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email", type: :string, sql_type: "varchar(255)", null: false, default: nil, primary_key: false),
    ])
  end

  describe "#call" do
    it "returns the AI result for an allowed table" do
      result = service.call("Show me all users", ["users"])
      expect(result).to(eq({ "sql" => "SELECT id FROM users", "explanation" => "returns all user ids" }))
    end

    it "builds a schema description from the connection" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "sql" => "", "explanation" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call("prompt", ["users"])

      system_message = captured_messages.find { |m| m[:role] == "system" }
      expect(system_message[:content]).to(include("users: id (integer), email (string)"))
    end

    it "skips tables that aren't in connection.tables" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "sql" => "", "explanation" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call("prompt", ["users", "not_a_real_table"])

      system_message = captured_messages.find { |m| m[:role] == "system" }
      expect(system_message[:content]).not_to(include("not_a_real_table"))
    end

    it "includes the system context when provided" do
      context_config = MysqlGenius::Core::Ai::Config.new(
        client: lambda { |**_kwargs| { "sql" => "", "explanation" => "" } },
        endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: "Healthcare app with HIPAA constraints",
      )
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "sql" => "", "explanation" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: "Healthcare app with HIPAA constraints",
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call("prompt", ["users"])

      system_message = captured_messages.find { |m| m[:role] == "system" }
      expect(system_message[:content]).to(include("Healthcare app with HIPAA constraints"))
    end
  end
end
```

### Task G2: Run the spec to verify it fails

- [ ] **Step 1: Run**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/ai/suggestion_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Ai::Suggestion`.

### Task G3: Implement Core::Ai::Suggestion

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/ai/suggestion.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Turns a natural-language prompt + a list of allowed tables into
      # a SELECT query via the AI client.
      #
      # Construct with:
      #   connection - a Core::Connection implementation
      #   client     - a Core::Ai::Client (pre-built with the same config)
      #   config     - the Core::Ai::Config (used for system_context)
      #
      # Call:
      #   .call(user_prompt, allowed_tables)  -> Hash with "sql" and "explanation"
      class Suggestion
        def initialize(connection, client, config)
          @connection = connection
          @client = client
          @config = config
        end

        def call(user_prompt, allowed_tables)
          schema = build_schema_description(allowed_tables)
          messages = [
            { role: "system", content: system_prompt(schema) },
            { role: "user", content: user_prompt },
          ]

          @client.chat(messages: messages)
        end

        private

        def system_prompt(schema_description)
          prompt = <<~PROMPT
            You are a SQL query assistant for a MySQL database.
          PROMPT

          if @config.system_context && !@config.system_context.empty?
            prompt += <<~PROMPT

              Domain context:
              #{@config.system_context}
            PROMPT
          end

          prompt += <<~PROMPT

            Rules:
            - Only generate SELECT statements. Never generate INSERT, UPDATE, DELETE, or any other mutation.
            - Only reference the tables and columns listed in the schema below. Do not guess or invent column names.
            - Use backticks for table and column names.
            - Include a LIMIT 100 unless the user specifies otherwise.

            Available schema:
            #{schema_description}

            Respond with JSON: {"sql": "the SQL query", "explanation": "brief explanation of what the query does"}
          PROMPT

          prompt
        end

        def build_schema_description(allowed_tables)
          allowed_tables.map do |table|
            next unless @connection.tables.include?(table)

            columns = @connection.columns_for(table).map { |c| "#{c.name} (#{c.type})" }
            "#{table}: #{columns.join(", ")}"
          end.compact.join("\n")
        end
      end
    end
  end
end
```

### Task G4: Require the new file from core.rb

**Files:**
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`

- [ ] **Step 1: Add the require**

Append this line at the end of `gems/mysql_genius-core/lib/mysql_genius/core.rb`:

```ruby
require "mysql_genius/core/ai/suggestion"
```

### Task G5: Run the core spec to verify pass

- [ ] **Step 1: Run**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/ai/suggestion_spec.rb
```

Expected: all 4 examples pass.

### Task G6: Update the Rails adapter to use Core::Ai::Suggestion and delete the old service

**Files:**
- Modify: `app/controllers/concerns/mysql_genius/ai_features.rb`
- Delete: `app/services/mysql_genius/ai_suggestion_service.rb`
- Delete: `spec/mysql_genius/ai_suggestion_service_spec.rb`

- [ ] **Step 1: Update the `suggest` action in `ai_features.rb`**

Find the `suggest` method (around line 7 of the concern):

```ruby
def suggest
  unless mysql_genius_config.ai_enabled?
    return render(json: { error: "AI features are not configured." }, status: :not_found)
  end

  prompt = params[:prompt].to_s.strip
  return render(json: { error: "Please describe what you want to query." }, status: :unprocessable_entity) if prompt.blank?

  result = AiSuggestionService.new.call(prompt, queryable_tables)
  sql = sanitize_ai_sql(result["sql"].to_s)
  render(json: { sql: sql, explanation: result["explanation"] })
rescue StandardError => e
  render(json: { error: "AI suggestion failed: #{e.message}" }, status: :unprocessable_entity)
end
```

Replace the `result = AiSuggestionService.new.call(...)` line with:

```ruby
connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
service = MysqlGenius::Core::Ai::Suggestion.new(connection, ai_client, ai_config_for_core)
result = service.call(prompt, queryable_tables)
```

- [ ] **Step 2: Delete the old service file**

```bash
rm app/services/mysql_genius/ai_suggestion_service.rb
```

- [ ] **Step 3: Delete the old service spec**

```bash
rm spec/mysql_genius/ai_suggestion_service_spec.rb
```

- [ ] **Step 4: Run the Rails adapter suite**

```bash
bundle exec rspec
```

Expected: all remaining specs pass. If the `ai_optimization_service_spec.rb` or any other code still references the deleted `AiSuggestionService`, fix those references.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Move AiSuggestionService to Core::Ai::Suggestion

Takes connection + client + config explicitly. The 'suggest' controller
action builds an ActiveRecordAdapter + Core::Ai::Client + config and
hands them to the core service."
```

---

## Stage H — Move AiOptimizationService to Core::Ai::Optimization

### Task H1: Write the Core::Ai::Optimization spec

**Files:**
- Create: `gems/mysql_genius-core/spec/mysql_genius/core/ai/optimization_spec.rb`

- [ ] **Step 1: Write the spec**

```ruby
# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Ai::Optimization) do
  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }
  let(:ai_config) do
    MysqlGenius::Core::Ai::Config.new(
      client: lambda { |**_kwargs| { "suggestions" => "Add an index on `users.email`" } },
      endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
    )
  end
  let(:client) { MysqlGenius::Core::Ai::Client.new(ai_config) }

  subject(:service) { described_class.new(connection, client, ai_config) }

  before do
    connection.stub_tables(["users"])
    connection.stub_columns_for("users", [
      MysqlGenius::Core::ColumnDefinition.new(name: "id", type: :integer, sql_type: "bigint", null: false, default: nil, primary_key: true),
      MysqlGenius::Core::ColumnDefinition.new(name: "email", type: :string, sql_type: "varchar(255)", null: false, default: nil, primary_key: false),
    ])
    connection.stub_indexes_for("users", [
      MysqlGenius::Core::IndexDefinition.new(name: "users_pkey", columns: ["id"], unique: true),
    ])
  end

  describe "#call" do
    it "returns the AI result" do
      result = service.call("SELECT * FROM users WHERE email = 'x'", [["1", "SIMPLE", "users", "ALL"]], ["users"])
      expect(result).to(eq({ "suggestions" => "Add an index on `users.email`" }))
    end

    it "includes both columns and indexes in the schema description" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "suggestions" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call("SELECT * FROM users", [], ["users"])

      system_message = captured_messages.find { |m| m[:role] == "system" }
      expect(system_message[:content]).to(include("users: id (integer), email (string)"))
      expect(system_message[:content]).to(include("users_pkey: [id] UNIQUE"))
    end

    it "formats EXPLAIN rows from an array" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "suggestions" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call(
        "SELECT * FROM users",
        [["1", "SIMPLE", "users", "ALL", "10"]],
        ["users"],
      )

      user_message = captured_messages.find { |m| m[:role] == "user" }
      expect(user_message[:content]).to(include("1 | SIMPLE | users | ALL | 10"))
    end

    it "passes through EXPLAIN output already formatted as a string" do
      captured_messages = nil
      capturing_callable = lambda { |messages:, **|
        captured_messages = messages
        { "suggestions" => "" }
      }
      capturing_config = MysqlGenius::Core::Ai::Config.new(
        client: capturing_callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      capturing_client = MysqlGenius::Core::Ai::Client.new(capturing_config)
      described_class.new(connection, capturing_client, capturing_config).call(
        "SELECT * FROM users",
        "pre-formatted explain output",
        ["users"],
      )

      user_message = captured_messages.find { |m| m[:role] == "user" }
      expect(user_message[:content]).to(include("pre-formatted explain output"))
    end
  end
end
```

### Task H2: Run the spec to verify it fails

- [ ] **Step 1: Run**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/ai/optimization_spec.rb
```

Expected: FAIL with `NameError: uninitialized constant MysqlGenius::Core::Ai::Optimization`.

### Task H3: Implement Core::Ai::Optimization

**Files:**
- Create: `gems/mysql_genius-core/lib/mysql_genius/core/ai/optimization.rb`

- [ ] **Step 1: Write the file**

```ruby
# frozen_string_literal: true

module MysqlGenius
  module Core
    module Ai
      # Analyses a SQL query + its EXPLAIN output and asks the AI client
      # for optimization suggestions.
      #
      # Construct with:
      #   connection - a Core::Connection implementation
      #   client     - a Core::Ai::Client
      #   config     - the Core::Ai::Config
      #
      # Call:
      #   .call(sql, explain_rows, allowed_tables)
      #     explain_rows - Array of arrays OR a pre-formatted String
      #     -> Hash with "suggestions" key
      class Optimization
        def initialize(connection, client, config)
          @connection = connection
          @client = client
          @config = config
        end

        def call(sql, explain_rows, allowed_tables)
          schema = build_schema_description(allowed_tables)
          messages = [
            { role: "system", content: system_prompt(schema) },
            { role: "user", content: user_prompt(sql, explain_rows) },
          ]

          @client.chat(messages: messages)
        end

        private

        def system_prompt(schema_description)
          <<~PROMPT
            You are a MySQL query optimization expert. Given a SQL query and its EXPLAIN output, analyze the query execution plan and provide actionable optimization suggestions.

            Available schema:
            #{schema_description}

            Respond with JSON:
            {
              "suggestions": "Markdown-formatted analysis and suggestions. Include: 1) Summary of current execution plan (scan types, rows examined). 2) Specific recommendations such as indexes to add (provide exact CREATE INDEX statements), query rewrites, or structural changes. 3) Expected impact of each suggestion."
            }
          PROMPT
        end

        def user_prompt(sql, explain_rows)
          <<~PROMPT
            SQL Query:
            #{sql}

            EXPLAIN Output:
            #{format_explain(explain_rows)}
          PROMPT
        end

        def format_explain(explain_rows)
          return explain_rows if explain_rows.is_a?(String)

          explain_rows.map { |row| row.join(" | ") }.join("\n")
        end

        def build_schema_description(allowed_tables)
          allowed_tables.map do |table|
            next unless @connection.tables.include?(table)

            columns = @connection.columns_for(table).map { |c| "#{c.name} (#{c.type})" }
            indexes = @connection.indexes_for(table).map { |idx| "#{idx.name}: [#{idx.columns.join(", ")}]#{" UNIQUE" if idx.unique}" }
            desc = "#{table}: #{columns.join(", ")}"
            desc += "\n  Indexes: #{indexes.join("; ")}" if indexes.any?
            desc
          end.compact.join("\n")
        end
      end
    end
  end
end
```

### Task H4: Require the new file from core.rb

**Files:**
- Modify: `gems/mysql_genius-core/lib/mysql_genius/core.rb`

- [ ] **Step 1: Add the require**

Append this line at the end of `gems/mysql_genius-core/lib/mysql_genius/core.rb`:

```ruby
require "mysql_genius/core/ai/optimization"
```

### Task H5: Run the core spec to verify pass

- [ ] **Step 1: Run**

```bash
cd gems/mysql_genius-core && bundle exec rspec spec/mysql_genius/core/ai/optimization_spec.rb
```

Expected: all 4 examples pass.

### Task H6: Update the Rails adapter to use Core::Ai::Optimization and delete the old service

**Files:**
- Modify: `app/controllers/concerns/mysql_genius/ai_features.rb`
- Delete: `app/services/mysql_genius/ai_optimization_service.rb`
- Delete: `spec/mysql_genius/ai_optimization_service_spec.rb`

- [ ] **Step 1: Update the `optimize` action in `ai_features.rb`**

Find the `optimize` method:

```ruby
def optimize
  unless mysql_genius_config.ai_enabled?
    return render(json: { error: "AI features are not configured." }, status: :not_found)
  end

  sql = params[:sql].to_s.strip
  explain_rows = Array(params[:explain_rows]).map { |row| row.respond_to?(:values) ? row.values : Array(row) }

  if sql.blank? || explain_rows.blank?
    return render(json: { error: "SQL and EXPLAIN output are required." }, status: :unprocessable_entity)
  end

  result = AiOptimizationService.new.call(sql, explain_rows, queryable_tables)
  render(json: result)
rescue StandardError => e
  render(json: { error: "Optimization failed: #{e.message}" }, status: :unprocessable_entity)
end
```

Replace the `result = AiOptimizationService.new.call(...)` line with:

```ruby
connection = MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
service = MysqlGenius::Core::Ai::Optimization.new(connection, ai_client, ai_config_for_core)
result = service.call(sql, explain_rows, queryable_tables)
```

- [ ] **Step 2: Delete the old service file**

```bash
rm app/services/mysql_genius/ai_optimization_service.rb
```

- [ ] **Step 3: Delete the old service spec**

```bash
rm spec/mysql_genius/ai_optimization_service_spec.rb
```

- [ ] **Step 4: Run the Rails adapter suite**

```bash
bundle exec rspec
```

Expected: all remaining specs pass.

- [ ] **Step 5: Run the core suite**

```bash
(cd gems/mysql_genius-core && bundle exec rspec)
```

Expected: all core specs pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Move AiOptimizationService to Core::Ai::Optimization

The 'optimize' controller action now builds an ActiveRecordAdapter +
Core::Ai::Client and hands them to the core service along with config."
```

### Task H7: Delete the now-orphaned MysqlGenius::AiClient

With both old services gone, the last remaining reference to `MysqlGenius::AiClient` is the file itself and its spec. Verify and delete.

**Files:**
- Delete: `app/services/mysql_genius/ai_client.rb`
- Delete: `spec/mysql_genius/ai_client_spec.rb`

- [ ] **Step 1: Verify no Ruby code still references `MysqlGenius::AiClient`**

```bash
grep -rn "AiClient" --include="*.rb" app/ lib/ spec/
```

Expected: only matches in `app/services/mysql_genius/ai_client.rb` (the file itself) and `spec/mysql_genius/ai_client_spec.rb` (the spec). Nothing else.

If any other file still references `AiClient`, **stop and fix that reference before deleting**. It's probably in a test helper or another corner of the concern we missed.

- [ ] **Step 2: Delete the old files**

```bash
rm app/services/mysql_genius/ai_client.rb
rm spec/mysql_genius/ai_client_spec.rb
```

- [ ] **Step 3: Run the Rails adapter suite**

```bash
bundle exec rspec
```

Expected: all specs pass. No references to the deleted class should remain.

- [ ] **Step 4: Run the core suite**

```bash
(cd gems/mysql_genius-core && bundle exec rspec)
```

Expected: all core specs pass (unaffected by this cleanup, but confirm).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Delete orphaned MysqlGenius::AiClient

Nothing references the old AiClient anymore — the ai_features concern
uses Core::Ai::Client via a helper, Core::Ai::Suggestion and
Core::Ai::Optimization have replaced the old services, and the old
services are gone. Safe to remove."
```

---

## Stage I — Verify and wrap up Phase 1a

Final verification that the Rails engine behaves identically and the foundations for Phase 1b are in place.

### Task I1: Run the full test suite

- [ ] **Step 1: Run the core gem's specs**

```bash
(cd gems/mysql_genius-core && bundle exec rspec)
```

Expected: everything green. The core gem now has tests for:
- `Core::SqlValidator`
- `Core::Result`
- `Core::ServerInfo`
- `Core::ColumnDefinition`
- `Core::IndexDefinition`
- `Core::Connection::FakeAdapter`
- `Core::Ai::Config`
- `Core::Ai::Client`
- `Core::Ai::Suggestion`
- `Core::Ai::Optimization`

- [ ] **Step 2: Run the Rails adapter's specs**

```bash
bundle exec rspec
```

Expected: everything green. The Rails adapter's suite now contains:
- `configuration_spec.rb` — unchanged
- `slow_query_monitor_spec.rb` — unchanged
- `mysql_genius_spec.rb` — unchanged
- `core/connection/active_record_adapter_spec.rb` — new, for the AR bridge

- [ ] **Step 3: Run rubocop on both**

```bash
bundle exec rubocop
(cd gems/mysql_genius-core && bundle exec rubocop)
```

Expected: no offenses. If there are, auto-correct with `-A` and re-run tests to confirm nothing broke.

### Task I2: Smoke-test the Rails engine behavior manually

- [ ] **Step 1: Verify no file references stale constants**

```bash
grep -rn "MysqlGenius::AiClient\|MysqlGenius::AiSuggestionService\|MysqlGenius::AiOptimizationService\|MysqlGenius::SqlValidator" --include="*.rb" .
```

Expected: zero matches. (There may be matches in `gems/mysql_genius-core/lib/mysql_genius/core/sql_validator.rb` if the inner module references the old name — verify by opening the file and confirming it uses `MysqlGenius::Core::SqlValidator`.)

- [ ] **Step 2: Verify the file structure matches the design**

```bash
find lib/mysql_genius/core -type f -name "*.rb"
```

Expected:
```
lib/mysql_genius/core/connection/active_record_adapter.rb
```

```bash
find gems/mysql_genius-core/lib -type f -name "*.rb" | sort
```

Expected (order may vary):
```
gems/mysql_genius-core/lib/mysql_genius/core.rb
gems/mysql_genius-core/lib/mysql_genius/core/ai/client.rb
gems/mysql_genius-core/lib/mysql_genius/core/ai/config.rb
gems/mysql_genius-core/lib/mysql_genius/core/ai/optimization.rb
gems/mysql_genius-core/lib/mysql_genius/core/ai/suggestion.rb
gems/mysql_genius-core/lib/mysql_genius/core/column_definition.rb
gems/mysql_genius-core/lib/mysql_genius/core/connection.rb
gems/mysql_genius-core/lib/mysql_genius/core/connection/fake_adapter.rb
gems/mysql_genius-core/lib/mysql_genius/core/index_definition.rb
gems/mysql_genius-core/lib/mysql_genius/core/result.rb
gems/mysql_genius-core/lib/mysql_genius/core/server_info.rb
gems/mysql_genius-core/lib/mysql_genius/core/sql_validator.rb
gems/mysql_genius-core/lib/mysql_genius/core/version.rb
```

```bash
find app/services/mysql_genius -type f -name "*.rb"
```

Expected: **empty** (or only files we didn't touch; AI service files all deleted).

### Task I3: Final commit for Phase 1a checkpoint

- [ ] **Step 1: Verify git status is clean**

```bash
git status
```

Expected: nothing to commit.

- [ ] **Step 2: Tag the Phase 1a completion (optional but recommended)**

```bash
git tag phase-1a-complete
```

This provides a rollback anchor before Phase 1b's analysis extraction begins.

- [ ] **Step 3: Print a summary for the reviewer**

Run:

```bash
git log --oneline --since="1 day ago"
```

Expected output shows the stage commits (9 total):
1. Add mysql_genius-core gem scaffold (Stage A)
2. Move SqlValidator to mysql_genius-core (Stage B)
3. Add Core value objects (Stage C)
4. Add Core::Connection contract + FakeAdapter test helper (Stage D)
5. Add Core::Connection::ActiveRecordAdapter in Rails gem (Stage E)
6. Wire Core::Ai::Client into 7 inline AI features (Stage F)
7. Move AiSuggestionService to Core::Ai::Suggestion (Stage G)
8. Move AiOptimizationService to Core::Ai::Optimization (Stage H1)
9. Delete orphaned MysqlGenius::AiClient (Stage H2)

---

## Phase 1a ship criterion

- [ ] `gems/mysql_genius-core/` exists with gemspec, lib, spec, and Rakefile
- [ ] `bundle exec rspec` in repo root passes all existing Rails adapter specs
- [ ] `(cd gems/mysql_genius-core && bundle exec rspec)` passes all core specs
- [ ] `bundle exec rubocop` passes in both repo root and core gem
- [ ] `app/services/mysql_genius/ai_client.rb` is deleted
- [ ] `app/services/mysql_genius/ai_suggestion_service.rb` is deleted
- [ ] `app/services/mysql_genius/ai_optimization_service.rb` is deleted
- [ ] `lib/mysql_genius/sql_validator.rb` is deleted
- [ ] `lib/mysql_genius/core/connection/active_record_adapter.rb` exists in the Rails adapter gem
- [ ] The Rails engine's mountpoint, routes, JSON responses, and config DSL are identical (no public API changes)
- [ ] No Git-staged `git status` differences after Task I3

**Next:** Phase 1b plan extracts the 5 analysis classes + `QueryRunner` + `QueryExplainer` and does the paired release bump to `mysql_genius-core 0.1.0` + `mysql_genius 0.4.0`.
