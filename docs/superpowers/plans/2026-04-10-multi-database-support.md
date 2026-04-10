# Multi-Database Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow MySQL Genius to monitor multiple MySQL/MariaDB databases from a single dashboard, with auto-detection from Rails configs and per-database settings.

**Architecture:** New `DatabaseConfig` class for per-database settings with fallback to global config. New `DatabaseRegistry` module for auto-detecting MySQL databases from Rails. Routes gain an optional `(:database)` prefix. `BaseController` resolves the current database and provides a `connection` helper that replaces all 25+ hardcoded `ActiveRecord::Base.connection` calls. YAML config files (`config/mysql_genius.yml`) provide per-database overrides.

**Tech Stack:** Ruby, Rails 5.2–8.1, RSpec

---

## File Map

### New Files

| File | Purpose |
|------|---------|
| `lib/mysql_genius/database_config.rb` | Per-database settings with fallback to global config |
| `lib/mysql_genius/database_registry.rb` | Auto-detects MySQL databases from Rails, loads YAML, builds registry |
| `lib/generators/mysql_genius/install/templates/mysql_genius.yml` | Template YAML config for the install generator |
| `spec/mysql_genius/database_config_spec.rb` | Tests for DatabaseConfig |
| `spec/mysql_genius/database_registry_spec.rb` | Tests for DatabaseRegistry |

### Modified Files

| File | Change |
|------|--------|
| `lib/mysql_genius/configuration.rb` | Add `databases` hash, `database()` DSL method, `yaml_config` hash |
| `lib/mysql_genius.rb` | Add `databases` convenience accessor, require new files |
| `lib/mysql_genius/engine.rb` | Boot-time database discovery |
| `config/routes.rb` | Wrap all routes in `scope '(:database)'` |
| `app/controllers/mysql_genius/base_controller.rb` | Add `resolve_database!`, `connection`, `current_database_config` helpers |
| `app/controllers/mysql_genius/queries_controller.rb` | Replace `ActiveRecord::Base.connection` calls with `connection` helper, use `current_database_config` for per-db settings |
| `app/controllers/concerns/mysql_genius/query_execution.rb` | Replace `ActiveRecord::Base.connection` with `connection` |
| `app/controllers/concerns/mysql_genius/database_analysis.rb` | Replace `ActiveRecord::Base.connection` with `connection` |
| `app/controllers/concerns/mysql_genius/ai_features.rb` | Replace `ActiveRecord::Base.connection` with `connection` |
| `app/services/mysql_genius/ai_suggestion_service.rb` | Accept `connection:` keyword argument |
| `app/services/mysql_genius/ai_optimization_service.rb` | Accept `connection:` keyword argument |
| `app/views/mysql_genius/queries/index.html.erb` | Add database switcher dropdown, pass `database:` to route helpers |
| `app/views/layouts/mysql_genius/application.html.erb` | Add database indicator styling |
| `lib/generators/mysql_genius/install/install_generator.rb` | Copy YAML template |
| `lib/generators/mysql_genius/install/templates/initializer.rb` | Add per-database config example |
| `spec/mysql_genius/configuration_spec.rb` | Add tests for `database()` DSL and databases hash |
| `spec/mysql_genius/ai_suggestion_service_spec.rb` | Update to pass `connection:` kwarg |
| `spec/mysql_genius/ai_optimization_service_spec.rb` | Update to pass `connection:` kwarg |

---

### Task 1: DatabaseConfig Class

**Files:**
- Create: `lib/mysql_genius/database_config.rb`
- Create: `spec/mysql_genius/database_config_spec.rb`

- [ ] **Step 1: Write the failing tests**

Create `spec/mysql_genius/database_config_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'mysql_genius/database_config'

RSpec.describe(MysqlGenius::DatabaseConfig) do
  let(:global_config) do
    MysqlGenius::Configuration.new
  end

  describe '#initialize' do
    it 'stores the key and global config' do
      db_config = described_class.new(:primary, global_config)
      expect(db_config.key).to(eq(:primary))
    end

    it 'defaults label to titleized key' do
      db_config = described_class.new(:analytics_warehouse, global_config)
      expect(db_config.label).to(eq('Analytics warehouse'))
    end
  end

  describe 'per-database overrides' do
    it 'returns its own value when set' do
      db_config = described_class.new(:primary, global_config)
      db_config.blocked_tables = ['raw_events']
      expect(db_config.blocked_tables).to(eq(['raw_events']))
    end

    it 'falls back to global config when not set' do
      global_config.blocked_tables = ['sessions', 'schema_migrations']
      db_config = described_class.new(:primary, global_config)
      expect(db_config.blocked_tables).to(eq(['sessions', 'schema_migrations']))
    end

    it 'supports all overridable settings' do
      db_config = described_class.new(:primary, global_config)
      db_config.masked_column_patterns = ['ssn']
      db_config.featured_tables = ['users']
      db_config.default_columns = { 'users' => %w[id name] }
      db_config.max_row_limit = 500
      db_config.default_row_limit = 10
      db_config.query_timeout_ms = 5000

      expect(db_config.masked_column_patterns).to(eq(['ssn']))
      expect(db_config.featured_tables).to(eq(['users']))
      expect(db_config.default_columns).to(eq({ 'users' => %w[id name] }))
      expect(db_config.max_row_limit).to(eq(500))
      expect(db_config.default_row_limit).to(eq(10))
      expect(db_config.query_timeout_ms).to(eq(5000))
    end
  end

  describe '#load_from_yaml' do
    it 'loads settings from a hash' do
      db_config = described_class.new(:primary, global_config)
      db_config.load_from_yaml(
        'label' => 'Main App',
        'blocked_tables' => ['raw_events'],
        'query_timeout_ms' => 60_000,
      )

      expect(db_config.label).to(eq('Main App'))
      expect(db_config.blocked_tables).to(eq(['raw_events']))
      expect(db_config.query_timeout_ms).to(eq(60_000))
    end

    it 'ignores unknown keys' do
      db_config = described_class.new(:primary, global_config)
      expect { db_config.load_from_yaml('unknown_key' => 'value') }.not_to(raise_error)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/mysql_genius/database_config_spec.rb`
Expected: FAIL — `cannot load such file -- mysql_genius/database_config`

- [ ] **Step 3: Write the implementation**

Create `lib/mysql_genius/database_config.rb`:

```ruby
# frozen_string_literal: true

module MysqlGenius
  class DatabaseConfig
    OVERRIDABLE_SETTINGS = %i[
      blocked_tables
      masked_column_patterns
      featured_tables
      default_columns
      max_row_limit
      default_row_limit
      query_timeout_ms
    ].freeze

    attr_reader :key
    attr_accessor :label, :connection_spec

    OVERRIDABLE_SETTINGS.each do |setting|
      define_method(setting) do
        value = instance_variable_get(:"@#{setting}")
        value.nil? ? @global_config.public_send(setting) : value
      end

      define_method(:"#{setting}=") do |value|
        instance_variable_set(:"@#{setting}", value)
      end
    end

    def initialize(key, global_config)
      @key = key.to_sym
      @global_config = global_config
      @label = @key.to_s.tr('_', ' ').capitalize
    end

    def load_from_yaml(hash)
      hash.each do |k, v|
        setter = :"#{k}="
        public_send(setter, v) if respond_to?(setter)
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/mysql_genius/database_config_spec.rb`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/mysql_genius/database_config.rb spec/mysql_genius/database_config_spec.rb
git commit -m "Add DatabaseConfig class for per-database settings"
```

---

### Task 2: Configuration DSL for Databases

**Files:**
- Modify: `lib/mysql_genius/configuration.rb`
- Modify: `lib/mysql_genius.rb`
- Modify: `spec/mysql_genius/configuration_spec.rb`

- [ ] **Step 1: Write the failing tests**

Add to the bottom of `spec/mysql_genius/configuration_spec.rb`, before the final `end`:

```ruby
describe '#database' do
  it 'creates a DatabaseConfig and yields it' do
    config.database(:analytics) do |db|
      db.blocked_tables = ['raw_events']
    end

    expect(config.databases[:analytics]).to(be_a(MysqlGenius::DatabaseConfig))
    expect(config.databases[:analytics].blocked_tables).to(eq(['raw_events']))
  end

  it 'reuses existing DatabaseConfig on repeated calls' do
    config.database(:analytics) do |db|
      db.blocked_tables = ['raw_events']
    end
    config.database(:analytics) do |db|
      db.max_row_limit = 500
    end

    expect(config.databases[:analytics].blocked_tables).to(eq(['raw_events']))
    expect(config.databases[:analytics].max_row_limit).to(eq(500))
  end

  it 'falls back to global config for unset values' do
    config.max_row_limit = 2000
    config.database(:analytics) {}

    expect(config.databases[:analytics].max_row_limit).to(eq(2000))
  end
end

describe '#databases' do
  it 'defaults to an empty hash' do
    expect(config.databases).to(eq({}))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/mysql_genius/configuration_spec.rb`
Expected: FAIL — `undefined method 'database'` and `undefined method 'databases'`

- [ ] **Step 3: Implement the DSL**

In `lib/mysql_genius/configuration.rb`, add `attr_reader :databases` to the attribute list near the top of the class. Add to `initialize`:

```ruby
@databases = {}
```

Add the `database` method to the class body:

```ruby
def database(key)
  key = key.to_sym
  @databases[key] ||= DatabaseConfig.new(key, self)
  yield(@databases[key]) if block_given?
  @databases[key]
end
```

In `lib/mysql_genius.rb`, add the require after the existing `require "mysql_genius/configuration"` line:

```ruby
require "mysql_genius/database_config"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/mysql_genius/configuration_spec.rb`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add lib/mysql_genius/configuration.rb lib/mysql_genius.rb spec/mysql_genius/configuration_spec.rb
git commit -m "Add database() DSL to Configuration for per-database overrides"
```

---

### Task 3: DatabaseRegistry — YAML Loading & Auto-Detection

**Files:**
- Create: `lib/mysql_genius/database_registry.rb`
- Create: `spec/mysql_genius/database_registry_spec.rb`

- [ ] **Step 1: Write the failing tests**

Create `spec/mysql_genius/database_registry_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'
require 'mysql_genius/database_registry'

RSpec.describe(MysqlGenius::DatabaseRegistry) do
  let(:config) { MysqlGenius.configuration }

  describe '.load_yaml' do
    it 'loads defaults from YAML hash' do
      yaml = {
        'defaults' => { 'max_row_limit' => 2000, 'blocked_tables' => ['internal'] },
        'databases' => {
          'primary' => { 'label' => 'Main App' },
          'analytics' => { 'label' => 'Analytics', 'query_timeout_ms' => 60_000 },
        },
      }

      described_class.load_yaml(yaml, config)

      expect(config.max_row_limit).to(eq(2000))
      expect(config.blocked_tables).to(eq(['internal']))
      expect(config.databases[:primary].label).to(eq('Main App'))
      expect(config.databases[:analytics].query_timeout_ms).to(eq(60_000))
    end

    it 'handles exclude list' do
      yaml = {
        'databases' => {
          'primary' => { 'label' => 'Main' },
          'cache_db' => { 'label' => 'Cache' },
        },
        'exclude' => ['cache_db'],
      }

      described_class.load_yaml(yaml, config)

      expect(config.databases).to(have_key(:primary))
      expect(config.databases).not_to(have_key(:cache_db))
    end

    it 'deep-merges environment override' do
      base = {
        'defaults' => { 'max_row_limit' => 1000 },
        'databases' => {
          'primary' => { 'label' => 'Main' },
        },
      }
      env_override = {
        'defaults' => { 'max_row_limit' => 500 },
        'databases' => {
          'primary' => { 'query_timeout_ms' => 10_000 },
          'analytics' => { 'label' => 'Analytics' },
        },
      }

      described_class.load_yaml(described_class.deep_merge(base, env_override), config)

      expect(config.max_row_limit).to(eq(500))
      expect(config.databases[:primary].label).to(eq('Main'))
      expect(config.databases[:primary].query_timeout_ms).to(eq(10_000))
      expect(config.databases[:analytics].label).to(eq('Analytics'))
    end

    it 'does nothing when yaml is nil' do
      expect { described_class.load_yaml(nil, config) }.not_to(raise_error)
      expect(config.databases).to(eq({}))
    end
  end

  describe '.deep_merge' do
    it 'merges nested hashes recursively' do
      base = { 'a' => { 'b' => 1, 'c' => 2 }, 'd' => 3 }
      override = { 'a' => { 'b' => 10, 'e' => 5 }, 'f' => 6 }
      result = described_class.deep_merge(base, override)

      expect(result).to(eq({ 'a' => { 'b' => 10, 'c' => 2, 'e' => 5 }, 'd' => 3, 'f' => 6 }))
    end
  end

  describe '.detect_databases' do
    it 'creates a default primary entry when no databases are configured' do
      described_class.detect_databases(config)

      expect(config.databases).to(have_key(:primary))
      expect(config.databases[:primary].label).to(eq('Primary'))
    end

    it 'does not overwrite databases already configured via YAML or initializer' do
      config.database(:analytics) { |db| db.label = 'My Analytics' }

      described_class.detect_databases(config)

      expect(config.databases[:analytics].label).to(eq('My Analytics'))
    end
  end

  describe '.multi_db?' do
    it 'returns false when one or zero databases exist' do
      expect(described_class.multi_db?(config)).to(be(false))

      config.database(:primary) {}
      expect(described_class.multi_db?(config)).to(be(false))
    end

    it 'returns true when multiple databases exist' do
      config.database(:primary) {}
      config.database(:analytics) {}
      expect(described_class.multi_db?(config)).to(be(true))
    end
  end

  describe '.default_key' do
    it 'returns the first database key' do
      config.database(:primary) {}
      config.database(:analytics) {}
      expect(described_class.default_key(config)).to(eq(:primary))
    end

    it 'returns :primary when no databases configured' do
      expect(described_class.default_key(config)).to(eq(:primary))
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/mysql_genius/database_registry_spec.rb`
Expected: FAIL — `cannot load such file -- mysql_genius/database_registry`

- [ ] **Step 3: Write the implementation**

Create `lib/mysql_genius/database_registry.rb`:

```ruby
# frozen_string_literal: true

require "yaml"
require "erb"

module MysqlGenius
  module DatabaseRegistry
    MYSQL_ADAPTERS = %w[mysql2 trilogy jdbcmysql].freeze
    YAML_DEFAULTS_KEYS = %w[
      blocked_tables masked_column_patterns featured_tables default_columns
      max_row_limit default_row_limit query_timeout_ms
    ].freeze

    class << self
      def build!(config)
        yaml = load_yaml_files
        load_yaml(yaml, config) if yaml
        detect_databases(config)
      end

      def load_yaml_files
        base_path = defined?(Rails) ? Rails.root.join("config", "mysql_genius.yml") : nil
        return nil unless base_path&.exist?

        base = YAML.safe_load(ERB.new(base_path.read).result, permitted_classes: [Symbol]) || {}
        env_path = Rails.root.join("config", "mysql_genius.#{Rails.env}.yml")
        if env_path.exist?
          env = YAML.safe_load(ERB.new(env_path.read).result, permitted_classes: [Symbol]) || {}
          base = deep_merge(base, env)
        end
        base
      end

      def load_yaml(yaml, config)
        return if yaml.nil?

        excludes = Array(yaml["exclude"]).map(&:to_s)

        if (defaults = yaml["defaults"])
          YAML_DEFAULTS_KEYS.each do |key|
            if defaults.key?(key)
              config.public_send(:"#{key}=", defaults[key])
            end
          end
        end

        if (databases = yaml["databases"])
          databases.each do |key, settings|
            next if excludes.include?(key.to_s)

            db_config = config.database(key)
            db_config.load_from_yaml(settings) if settings.is_a?(Hash)
          end
        end
      end

      def detect_databases(config)
        if defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:configurations)
          detect_from_rails(config)
        end

        config.database(:primary) if config.databases.empty?
      end

      def multi_db?(config)
        config.databases.size > 1
      end

      def default_key(config)
        config.databases.keys.first || :primary
      end

      def deep_merge(base, override)
        base.merge(override) do |_key, old_val, new_val|
          if old_val.is_a?(Hash) && new_val.is_a?(Hash)
            deep_merge(old_val, new_val)
          else
            new_val
          end
        end
      end

      private

      def detect_from_rails(config)
        configs = ActiveRecord::Base.configurations
        if configs.respond_to?(:configs_for)
          detect_from_rails_6_1_plus(config, configs)
        elsif configs.is_a?(Hash)
          detect_from_rails_legacy(config, configs)
        end
      end

      def detect_from_rails_6_1_plus(config, configs)
        env_configs = configs.configs_for(env_name: Rails.env)
        env_configs.each do |db_config|
          adapter = db_config.respond_to?(:adapter) ? db_config.adapter : db_config.configuration_hash[:adapter].to_s
          next unless MYSQL_ADAPTERS.include?(adapter)

          spec_name = db_config.respond_to?(:spec_name) ? db_config.spec_name : db_config.name
          key = spec_name.to_sym
          config.database(key) unless config.databases.key?(key)
          config.databases[key].connection_spec = spec_name
        end
      end

      def detect_from_rails_legacy(config, configs)
        env_configs = configs[Rails.env]
        return unless env_configs.is_a?(Hash)

        if env_configs.key?("adapter")
          if MYSQL_ADAPTERS.include?(env_configs["adapter"])
            config.database(:primary) unless config.databases.key?(:primary)
          end
        else
          env_configs.each do |key, db_hash|
            next unless db_hash.is_a?(Hash) && MYSQL_ADAPTERS.include?(db_hash["adapter"].to_s)

            sym_key = key.to_sym
            config.database(sym_key) unless config.databases.key?(sym_key)
            config.databases[sym_key].connection_spec = key
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Add require to `lib/mysql_genius.rb`**

Add after the `require "mysql_genius/database_config"` line:

```ruby
require "mysql_genius/database_registry"
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/mysql_genius/database_registry_spec.rb`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add lib/mysql_genius/database_registry.rb lib/mysql_genius.rb spec/mysql_genius/database_registry_spec.rb
git commit -m "Add DatabaseRegistry for YAML loading and auto-detection"
```

---

### Task 4: Engine Boot-Time Discovery & Top-Level Accessor

**Files:**
- Modify: `lib/mysql_genius/engine.rb`
- Modify: `lib/mysql_genius.rb`

- [ ] **Step 1: Add `databases` convenience accessor to `lib/mysql_genius.rb`**

Add inside the `class << self` block, after the `reset_configuration!` method:

```ruby
def databases
  configuration.databases
end
```

- [ ] **Step 2: Add boot-time discovery to `lib/mysql_genius/engine.rb`**

Add a new `config.after_initialize` block (before the existing one, or merge into it). The full file should be:

```ruby
# frozen_string_literal: true

module MysqlGenius
  class Engine < ::Rails::Engine
    isolate_namespace MysqlGenius

    config.after_initialize do
      MysqlGenius::DatabaseRegistry.build!(MysqlGenius.configuration)

      if MysqlGenius.configuration.redis_url.present?
        require "mysql_genius/slow_query_monitor"
        MysqlGenius::SlowQueryMonitor.subscribe!
      end
    end
  end
end
```

- [ ] **Step 3: Run existing tests to ensure nothing is broken**

Run: `bundle exec rspec`
Expected: All existing tests pass

- [ ] **Step 4: Commit**

```bash
git add lib/mysql_genius/engine.rb lib/mysql_genius.rb
git commit -m "Wire DatabaseRegistry into engine boot and add top-level accessor"
```

---

### Task 5: Routes — Optional Database Prefix

**Files:**
- Modify: `config/routes.rb`

- [ ] **Step 1: Wrap all routes in optional database scope**

Replace the entire `config/routes.rb` with:

```ruby
# frozen_string_literal: true

MysqlGenius::Engine.routes.draw do
  scope "(:database)" do
    root to: "queries#index"

    get  "columns",      to: "queries#columns"
    post "execute",      to: "queries#execute"
    post "explain",      to: "queries#explain"
    post "suggest",      to: "queries#suggest"
    post "optimize",     to: "queries#optimize"
    get  "slow_queries",      to: "queries#slow_queries"
    get  "duplicate_indexes", to: "queries#duplicate_indexes"
    get  "table_sizes",      to: "queries#table_sizes"
    get  "query_stats",      to: "queries#query_stats"
    get  "unused_indexes",   to: "queries#unused_indexes"
    get  "server_overview",  to: "queries#server_overview"

    # AI features
    post "describe_query",   to: "queries#describe_query"
    post "schema_review",    to: "queries#schema_review"
    post "rewrite_query",    to: "queries#rewrite_query"
    post "index_advisor",    to: "queries#index_advisor"
    post "anomaly_detection", to: "queries#anomaly_detection"
    post "root_cause",       to: "queries#root_cause"
    post "migration_risk",   to: "queries#migration_risk"
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add config/routes.rb
git commit -m "Add optional database prefix to all routes"
```

---

### Task 6: BaseController — Database Resolution & Connection Helper

**Files:**
- Modify: `app/controllers/mysql_genius/base_controller.rb`

- [ ] **Step 1: Add database resolution and connection helper**

Replace the entire `app/controllers/mysql_genius/base_controller.rb` with:

```ruby
# frozen_string_literal: true

module MysqlGenius
  class BaseController < MysqlGenius.configuration.base_controller.constantize
    layout "mysql_genius/application"
    before_action :authenticate_mysql_genius!
    before_action :resolve_database!

    helper_method :current_database_key, :current_database_config, :multi_db?, :available_databases

    private

    def authenticate_mysql_genius!
      unless MysqlGenius.configuration.authenticate.call(self)
        render(plain: "Not authorized", status: :unauthorized)
      end
    end

    def resolve_database!
      databases = MysqlGenius.databases
      registry = MysqlGenius::DatabaseRegistry

      if params[:database].present?
        key = params[:database].to_sym
        unless databases.key?(key)
          render(plain: "Database not found", status: :not_found)
          return
        end
        @current_database_key = key
      elsif registry.multi_db?(mysql_genius_config)
        redirect_to(mysql_genius.root_path(database: registry.default_key(mysql_genius_config)))
        return
      else
        @current_database_key = registry.default_key(mysql_genius_config)
      end

      @current_database_config = databases[@current_database_key] || mysql_genius_config.database(@current_database_key)
    end

    def current_database_key
      @current_database_key
    end

    def current_database_config
      @current_database_config
    end

    def connection
      @connection ||= resolve_connection
    end

    def multi_db?
      MysqlGenius::DatabaseRegistry.multi_db?(mysql_genius_config)
    end

    def available_databases
      MysqlGenius.databases
    end

    def mysql_genius_config
      MysqlGenius.configuration
    end

    def resolve_connection
      spec = @current_database_config&.connection_spec
      if spec && defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:connected_to)
        pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(spec)
        pool ? pool.connection : ActiveRecord::Base.connection
      else
        ActiveRecord::Base.connection
      end
    end
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add app/controllers/mysql_genius/base_controller.rb
git commit -m "Add database resolution and connection helper to BaseController"
```

---

### Task 7: Replace ActiveRecord::Base.connection in QueriesController

**Files:**
- Modify: `app/controllers/mysql_genius/queries_controller.rb`

- [ ] **Step 1: Update QueriesController to use connection helper and per-db config**

Replace the entire file with:

```ruby
# frozen_string_literal: true

module MysqlGenius
  class QueriesController < BaseController
    include QueryExecution
    include DatabaseAnalysis
    include AiFeatures

    def index
      db_config = current_database_config
      @featured_tables = if db_config.featured_tables.any?
        db_config.featured_tables.sort
      else
        queryable_tables.sort
      end
      @all_tables = queryable_tables.sort
      @ai_enabled = mysql_genius_config.ai_enabled?
      @multi_db = multi_db?
      @current_database_key = current_database_key
      @available_databases = available_databases
    end

    def columns
      table = params[:table]
      if current_database_config.blocked_tables.include?(table)
        return render(json: { error: "Table '#{table}' is not available for querying." }, status: :forbidden)
      end

      unless connection.tables.include?(table)
        return render(json: { error: "Table '#{table}' does not exist." }, status: :not_found)
      end

      defaults = current_database_config.default_columns[table] || []
      cols = connection.columns(table).reject { |c| masked_column?(c.name) }.map do |c|
        { name: c.name, type: c.type.to_s, default: defaults.empty? || defaults.include?(c.name) }
      end
      render(json: cols)
    end

    def slow_queries
      unless mysql_genius_config.redis_url.present?
        return render(json: [], status: :ok)
      end

      require "redis"
      redis = Redis.new(url: mysql_genius_config.redis_url)
      key = SlowQueryMonitor.redis_key
      raw = redis.lrange(key, 0, 199)
      queries = raw.map do |entry|
        JSON.parse(entry)
      rescue JSON::ParserError
        nil
      end.compact
      render(json: queries)
    rescue StandardError => e
      render(json: { error: "Slow query error: #{e.message}" }, status: :unprocessable_entity)
    end

    private

    def queryable_tables
      connection.tables - current_database_config.blocked_tables
    end
  end
end
```

- [ ] **Step 2: Run existing tests to check for regressions**

Run: `bundle exec rspec`
Expected: All pass

- [ ] **Step 3: Commit**

```bash
git add app/controllers/mysql_genius/queries_controller.rb
git commit -m "Use connection helper and per-db config in QueriesController"
```

---

### Task 8: Replace ActiveRecord::Base.connection in QueryExecution Concern

**Files:**
- Modify: `app/controllers/concerns/mysql_genius/query_execution.rb`

- [ ] **Step 1: Replace all ActiveRecord::Base.connection calls**

Replace the entire file with:

```ruby
# frozen_string_literal: true

module MysqlGenius
  module QueryExecution
    extend ActiveSupport::Concern

    def execute
      sql = params[:sql].to_s.strip
      db_config = current_database_config
      row_limit = if params[:row_limit].present?
        params[:row_limit].to_i.clamp(1, db_config.max_row_limit)
      else
        db_config.default_row_limit
      end

      error = validate_sql(sql)
      if error
        audit(:rejection, sql: sql, reason: error)
        return render(json: { error: error }, status: :unprocessable_entity)
      end

      limited_sql = apply_row_limit(sql, row_limit)
      timed_sql = apply_timeout_hint(limited_sql)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        results = connection.exec_query(timed_sql)
        execution_time_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(1)

        columns = results.columns
        rows = results.rows.map do |row|
          row.each_with_index.map do |value, i|
            masked_column?(columns[i]) ? "[REDACTED]" : value
          end
        end

        truncated = rows.length >= row_limit

        audit(:query, sql: sql, execution_time_ms: execution_time_ms, row_count: rows.length)

        render(json: {
          columns: columns,
          rows: rows,
          row_count: rows.length,
          execution_time_ms: execution_time_ms,
          truncated: truncated,
        })
      rescue ActiveRecord::StatementInvalid => e
        if timeout_error?(e)
          audit(:error, sql: sql, error: "Query timeout")
          render(json: { error: "Query exceeded the #{db_config.query_timeout_ms / 1000} second timeout limit.", timeout: true }, status: :unprocessable_entity)
        else
          audit(:error, sql: sql, error: e.message)
          render(json: { error: "Query error: #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
        end
      end
    end

    def explain
      sql = params[:sql].to_s.strip
      skip_validation = params[:from_slow_query] == "true"

      unless skip_validation
        error = validate_sql(sql)
        return render(json: { error: error }, status: :unprocessable_entity) if error
      end

      unless sql.match?(/\)\s*$/) || sql.match?(/\w\s*$/) || sql.match?(/['"`]\s*$/) || sql.match?(/\d\s*$/)
        return render(json: { error: "This query appears to be truncated and cannot be explained." }, status: :unprocessable_entity)
      end

      explain_sql = "EXPLAIN #{sql.gsub(/;\s*\z/, "")}"
      results = connection.exec_query(explain_sql)

      render(json: { columns: results.columns, rows: results.rows })
    rescue ActiveRecord::StatementInvalid => e
      render(json: { error: "Explain error: #{e.message.split(":").last.strip}" }, status: :unprocessable_entity)
    end

    private

    def validate_sql(sql)
      SqlValidator.validate(sql, blocked_tables: current_database_config.blocked_tables, connection: connection)
    end

    def apply_timeout_hint(sql)
      if mariadb?
        timeout_seconds = current_database_config.query_timeout_ms / 1000
        "SET STATEMENT max_statement_time=#{timeout_seconds} FOR #{sql}"
      else
        sql.sub(/\bSELECT\b/i, "SELECT /*+ MAX_EXECUTION_TIME(#{current_database_config.query_timeout_ms}) */")
      end
    end

    def mariadb?
      @mariadb ||= connection.select_value("SELECT VERSION()").to_s.include?("MariaDB")
    end

    def apply_row_limit(sql, limit)
      SqlValidator.apply_row_limit(sql, limit)
    end

    def timeout_error?(exception)
      msg = exception.message
      msg.include?("max_statement_time") || msg.include?("max_execution_time") || msg.include?("Query execution was interrupted")
    end

    def masked_column?(column_name)
      SqlValidator.masked_column?(column_name, current_database_config.masked_column_patterns)
    end

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
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add app/controllers/concerns/mysql_genius/query_execution.rb
git commit -m "Use connection helper and per-db config in QueryExecution concern"
```

---

### Task 9: Replace ActiveRecord::Base.connection in DatabaseAnalysis Concern

**Files:**
- Modify: `app/controllers/concerns/mysql_genius/database_analysis.rb`

- [ ] **Step 1: Replace all ActiveRecord::Base.connection calls**

In `app/controllers/concerns/mysql_genius/database_analysis.rb`, replace every occurrence of:

```ruby
connection = ActiveRecord::Base.connection
```

with nothing — just delete the line. The `connection` method from `BaseController` is already available. There are 5 such lines in this file (lines 8, 52, 84, 144, 185).

- [ ] **Step 2: Run existing tests**

Run: `bundle exec rspec`
Expected: All pass

- [ ] **Step 3: Commit**

```bash
git add app/controllers/concerns/mysql_genius/database_analysis.rb
git commit -m "Use connection helper in DatabaseAnalysis concern"
```

---

### Task 10: Replace ActiveRecord::Base.connection in AiFeatures Concern

**Files:**
- Modify: `app/controllers/concerns/mysql_genius/ai_features.rb`

- [ ] **Step 1: Replace all ActiveRecord::Base.connection calls**

In `app/controllers/concerns/mysql_genius/ai_features.rb`, delete every line that reads:

```ruby
connection = ActiveRecord::Base.connection
```

There are 6 such lines (lines 69, 152, 187, 247, 322, 390). The `connection` method from `BaseController` is already available.

Also update the `build_schema_for_query` private method at the bottom (line 389-395) to remove the local variable assignment:

Before:
```ruby
def build_schema_for_query(sql)
  connection = ActiveRecord::Base.connection
  tables = SqlValidator.extract_table_references(sql, connection)
```

After:
```ruby
def build_schema_for_query(sql)
  tables = SqlValidator.extract_table_references(sql, connection)
```

- [ ] **Step 2: Commit**

```bash
git add app/controllers/concerns/mysql_genius/ai_features.rb
git commit -m "Use connection helper in AiFeatures concern"
```

---

### Task 11: Update AI Services to Accept Connection Parameter

**Files:**
- Modify: `app/services/mysql_genius/ai_suggestion_service.rb`
- Modify: `app/services/mysql_genius/ai_optimization_service.rb`
- Modify: `app/controllers/concerns/mysql_genius/ai_features.rb` (call sites)
- Modify: `spec/mysql_genius/ai_suggestion_service_spec.rb`
- Modify: `spec/mysql_genius/ai_optimization_service_spec.rb`

- [ ] **Step 1: Update AiSuggestionService spec**

In `spec/mysql_genius/ai_suggestion_service_spec.rb`, update the `#call` test calls. Change every `service.call("...", [...])` to pass connection:

```ruby
# Before
service.call("show me all users", ["users", "posts"])
# After
service.call("show me all users", ["users", "posts"], connection: connection)
```

There are 5 call sites in the spec. Update all of them.

Also remove the `before` block that stubs `ActiveRecord::Base.connection`:

```ruby
# Remove this line from the outer before block:
allow(ActiveRecord::Base).to(receive(:connection).and_return(connection))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/mysql_genius/ai_suggestion_service_spec.rb`
Expected: FAIL — wrong number of arguments

- [ ] **Step 3: Update AiSuggestionService**

In `app/services/mysql_genius/ai_suggestion_service.rb`, change the `call` method signature and `build_schema_description`:

```ruby
def call(user_prompt, allowed_tables, connection:)
  schema = build_schema_description(allowed_tables, connection)
  messages = [
    { role: "system", content: system_prompt(schema) },
    { role: "user", content: user_prompt },
  ]

  AiClient.new.chat(messages: messages)
end
```

And update `build_schema_description`:

```ruby
def build_schema_description(allowed_tables, connection)
  allowed_tables.map do |table|
    next unless connection.tables.include?(table)

    columns = connection.columns(table).map { |c| "#{c.name} (#{c.type})" }
    "#{table}: #{columns.join(", ")}"
  end.compact.join("\n")
end
```

- [ ] **Step 4: Run suggestion service test to verify it passes**

Run: `bundle exec rspec spec/mysql_genius/ai_suggestion_service_spec.rb`
Expected: All pass

- [ ] **Step 5: Update AiOptimizationService spec**

In `spec/mysql_genius/ai_optimization_service_spec.rb`, update every `service.call(...)` to pass `connection:`:

```ruby
# Before
service.call("SELECT * FROM users", explain_rows, ["users"])
# After
service.call("SELECT * FROM users", explain_rows, ["users"], connection: connection)
```

There are 4 call sites. Update all. Also remove the `ActiveRecord::Base.connection` stub line from the outer `before` block.

- [ ] **Step 6: Run optimization service test to verify it fails**

Run: `bundle exec rspec spec/mysql_genius/ai_optimization_service_spec.rb`
Expected: FAIL — wrong number of arguments

- [ ] **Step 7: Update AiOptimizationService**

In `app/services/mysql_genius/ai_optimization_service.rb`, change the `call` method signature and `build_schema_description`:

```ruby
def call(sql, explain_rows, allowed_tables, connection:)
  schema = build_schema_description(allowed_tables, connection)
  messages = [
    { role: "system", content: system_prompt(schema) },
    { role: "user", content: user_prompt(sql, explain_rows) },
  ]

  AiClient.new.chat(messages: messages)
end
```

And update `build_schema_description`:

```ruby
def build_schema_description(allowed_tables, connection)
  allowed_tables.map do |table|
    next unless connection.tables.include?(table)

    columns = connection.columns(table).map { |c| "#{c.name} (#{c.type})" }
    indexes = connection.indexes(table).map { |idx| "#{idx.name}: [#{idx.columns.join(", ")}]#{" UNIQUE" if idx.unique}" }
    desc = "#{table}: #{columns.join(", ")}"
    desc += "\n  Indexes: #{indexes.join("; ")}" if indexes.any?
    desc
  end.compact.join("\n")
end
```

- [ ] **Step 8: Run optimization service test to verify it passes**

Run: `bundle exec rspec spec/mysql_genius/ai_optimization_service_spec.rb`
Expected: All pass

- [ ] **Step 9: Update call sites in AiFeatures concern**

In `app/controllers/concerns/mysql_genius/ai_features.rb`, update the two call sites:

The `suggest` method (around line 15):
```ruby
# Before
result = AiSuggestionService.new.call(prompt, queryable_tables)
# After
result = AiSuggestionService.new.call(prompt, queryable_tables, connection: connection)
```

The `optimize` method (around line 34):
```ruby
# Before
result = AiOptimizationService.new.call(sql, explain_rows, queryable_tables)
# After
result = AiOptimizationService.new.call(sql, explain_rows, queryable_tables, connection: connection)
```

- [ ] **Step 10: Run full test suite**

Run: `bundle exec rspec`
Expected: All pass

- [ ] **Step 11: Commit**

```bash
git add app/services/mysql_genius/ai_suggestion_service.rb app/services/mysql_genius/ai_optimization_service.rb app/controllers/concerns/mysql_genius/ai_features.rb spec/mysql_genius/ai_suggestion_service_spec.rb spec/mysql_genius/ai_optimization_service_spec.rb
git commit -m "Pass connection explicitly to AI services"
```

---

### Task 12: UI — Database Switcher Dropdown

**Files:**
- Modify: `app/views/mysql_genius/queries/index.html.erb`
- Modify: `app/views/layouts/mysql_genius/application.html.erb`

- [ ] **Step 1: Add database switcher styles to layout**

In `app/views/layouts/mysql_genius/application.html.erb`, add the following CSS rules inside the `<style>` tag, before the closing `</style>`:

```css
/* Database switcher */
.mg-header { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; }
.mg-header h4 { margin: 0; }
.mg-db-switcher { position: relative; }
.mg-db-switcher select { padding: 4px 24px 4px 8px; font-size: 13px; border: 1px solid #ced4da; border-radius: 4px; background: #fff; cursor: pointer; }
.mg-db-badge { display: inline-block; padding: 2px 10px; border-radius: 10px; font-size: 12px; font-weight: 500; background: #d1ecf1; color: #0c5460; }
```

- [ ] **Step 2: Add database switcher to the index view**

In `app/views/mysql_genius/queries/index.html.erb`, replace the first line:

```erb
<h4>&#128024; MySQLGenius</h4>
```

with:

```erb
<div class="mg-header">
  <h4>&#128024; MySQLGenius</h4>
  <% if @multi_db %>
    <div class="mg-db-switcher">
      <select id="mg-db-select" onchange="window.location.href = this.value;">
        <% @available_databases.each do |key, db| %>
          <option value="<%= mysql_genius.root_path(database: key) %>" <%= 'selected' if key == @current_database_key %>>
            <%= db.label %>
          </option>
        <% end %>
      </select>
    </div>
  <% else %>
    <span class="mg-db-badge"><%= @available_databases.values.first&.label || 'Primary' %></span>
  <% end %>
</div>
```

- [ ] **Step 3: Update ROUTES object to include database parameter**

The `ROUTES` object in the `<script>` tag already uses ERB path helpers like `mysql_genius.columns_path`. These need to include the `database:` parameter. Update each path helper call:

```erb
var ROUTES = {
  columns:      '<%= mysql_genius.columns_path(database: @current_database_key) %>',
  execute:      '<%= mysql_genius.execute_path(database: @current_database_key) %>',
  explain:      '<%= mysql_genius.explain_path(database: @current_database_key) %>',
  suggest:      '<%= mysql_genius.suggest_path(database: @current_database_key) %>',
  optimize:     '<%= mysql_genius.optimize_path(database: @current_database_key) %>',
  slow_queries: '<%= mysql_genius.slow_queries_path(database: @current_database_key) %>',
  duplicate_indexes: '<%= mysql_genius.duplicate_indexes_path(database: @current_database_key) %>',
  table_sizes: '<%= mysql_genius.table_sizes_path(database: @current_database_key) %>',
  query_stats: '<%= mysql_genius.query_stats_path(database: @current_database_key) %>',
  unused_indexes: '<%= mysql_genius.unused_indexes_path(database: @current_database_key) %>',
  server_overview: '<%= mysql_genius.server_overview_path(database: @current_database_key) %>',
  describe_query: '<%= mysql_genius.describe_query_path(database: @current_database_key) %>',
  schema_review: '<%= mysql_genius.schema_review_path(database: @current_database_key) %>',
  rewrite_query: '<%= mysql_genius.rewrite_query_path(database: @current_database_key) %>',
  index_advisor: '<%= mysql_genius.index_advisor_path(database: @current_database_key) %>',
  anomaly_detection: '<%= mysql_genius.anomaly_detection_path(database: @current_database_key) %>',
  root_cause: '<%= mysql_genius.root_cause_path(database: @current_database_key) %>',
  migration_risk: '<%= mysql_genius.migration_risk_path(database: @current_database_key) %>'
};
```

- [ ] **Step 4: Commit**

```bash
git add app/views/mysql_genius/queries/index.html.erb app/views/layouts/mysql_genius/application.html.erb
git commit -m "Add database switcher dropdown to dashboard UI"
```

---

### Task 13: Install Generator — YAML Template

**Files:**
- Create: `lib/generators/mysql_genius/install/templates/mysql_genius.yml`
- Modify: `lib/generators/mysql_genius/install/install_generator.rb`
- Modify: `lib/generators/mysql_genius/install/templates/initializer.rb`

- [ ] **Step 1: Create the YAML template**

Create `lib/generators/mysql_genius/install/templates/mysql_genius.yml`:

```yaml
# MySQL Genius configuration
# Per-database settings override global defaults.
# Environment-specific overrides: config/mysql_genius.<environment>.yml

# defaults:
#   blocked_tables:
#     - sessions
#     - schema_migrations
#     - ar_internal_metadata
#   masked_column_patterns:
#     - password
#     - secret
#     - digest
#     - token
#   max_row_limit: 1000
#   default_row_limit: 25
#   query_timeout_ms: 30000

# databases:
#   primary:
#     label: "Main App"
#   analytics:
#     label: "Analytics Warehouse"
#     blocked_tables:
#       - raw_events
#       - etl_staging
#     query_timeout_ms: 60000

# exclude:
#   - internal_cache_db
```

- [ ] **Step 2: Update the install generator to copy the YAML template**

In `lib/generators/mysql_genius/install/install_generator.rb`, add a new method after `copy_initializer`:

```ruby
def copy_yaml_config
  template("mysql_genius.yml", "config/mysql_genius.yml")
end
```

- [ ] **Step 3: Add per-database example to the initializer template**

In `lib/generators/mysql_genius/install/templates/initializer.rb`, add before the final `end`:

```ruby

  # --- Multi-Database ---
  # Per-database overrides (YAML config in config/mysql_genius.yml is preferred).
  # config.database(:analytics) do |db|
  #   db.blocked_tables = %w[raw_events etl_staging]
  #   db.query_timeout_ms = 60_000
  # end
```

- [ ] **Step 4: Commit**

```bash
git add lib/generators/mysql_genius/install/templates/mysql_genius.yml lib/generators/mysql_genius/install/install_generator.rb lib/generators/mysql_genius/install/templates/initializer.rb
git commit -m "Add YAML config template and per-database example to install generator"
```

---

### Task 14: Full Test Suite & RuboCop

- [ ] **Step 1: Run full test suite**

Run: `bundle exec rspec`
Expected: All pass

- [ ] **Step 2: Run RuboCop**

Run: `bundle exec rubocop`
Expected: No new offenses. If there are, fix them.

- [ ] **Step 3: Auto-correct any offenses if needed**

Run: `bundle exec rubocop -A`

- [ ] **Step 4: Run tests again after any RuboCop fixes**

Run: `bundle exec rspec`
Expected: All pass

- [ ] **Step 5: Commit any RuboCop fixes**

```bash
git add -A
git commit -m "Fix RuboCop offenses from multi-database changes"
```

---

### Task 15: Update Changelog

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add multi-database entry to changelog**

Add a new entry at the top of the changelog under the Unreleased or next version section:

```markdown
### Added
- Multi-database support: monitor multiple MySQL/MariaDB databases from a single dashboard
- Auto-detection of MySQL databases from Rails `database.yml`
- Per-database configuration via `config/mysql_genius.yml` (with environment-specific overrides)
- Per-database settings: `blocked_tables`, `masked_column_patterns`, `featured_tables`, `default_columns`, `max_row_limit`, `default_row_limit`, `query_timeout_ms`
- Database switcher dropdown in the dashboard header
- URL-scoped database routing (`/mysql_genius/analytics/`, etc.)
- `config.database(:name)` DSL in the Ruby initializer for per-database overrides
- Full backward compatibility: single-database setups work without any configuration changes
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "Update changelog with multi-database support"
```
