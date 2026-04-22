# frozen_string_literal: true

# Helper loaded by every file under spec/integration/. Brings up a real
# ActiveRecord connection to the MySQL server specified by DATABASE_URL,
# loads the Sakila fixture, and primes performance_schema with
# WorkloadGenerator's query mix — then pins the connection to the `sakila`
# schema so Core::Analysis classes (which filter by current_database)
# see the seeded digests.
#
# Gated by REAL_MYSQL=1 via spec_helper's filter_run_excluding. When not
# set, we intentionally no-op so spec files still *load* (rubocop / LSPs
# don't flag them as broken) while the examples inside are filtered out
# at run time.

require "spec_helper"

if ENV["REAL_MYSQL"] == "1"
  require "active_record"
  require "mysql_genius"

  require_relative "../support/sakila_fixture"
  require_relative "../support/workload_generator"

  unless defined?(DATABASE_URL)
    DATABASE_URL = ENV["DATABASE_URL"] || "mysql2://root:root@127.0.0.1:3306/mysql_genius_test"
  end

  # Establish the connection the integration suite will use. We intentionally
  # start against whatever DB is in DATABASE_URL (e.g. mysql_genius_test in
  # CI) — Sakila is loaded into its own schema, so this first connection just
  # needs CREATE DATABASE privileges.
  ActiveRecord::Base.establish_connection(DATABASE_URL)

  RSpec.configure do |config|
    # Runs once for the first integration example, then short-circuits via
    # SakilaFixture's idempotency check on subsequent runs.
    config.before(:suite) do
      next unless RSpec.configuration.files_to_run.any? { |f| f.include?("/spec/integration/") }

      SakilaFixture.load!
      ActiveRecord::Base.connection.execute("USE sakila")

      # MySQL 8.4 ships with events_statements_history_long disabled by
      # default. Enable it for the test suite so SlowQueries has rows to
      # observe — mirrors what we tell production users to do when they
      # hit the setup page's consumer-off reason text.
      ActiveRecord::Base.connection.execute(
        "UPDATE performance_schema.setup_consumers " \
          "SET ENABLED = 'YES' WHERE NAME = 'events_statements_history_long'",
      )
      # Truncate the history ring buffer so the suite starts from a
      # predictable state (nothing from an earlier run of the workload
      # still sitting in the buffer).
      ActiveRecord::Base.connection.execute(
        "TRUNCATE performance_schema.events_statements_history_long",
      )
      # Same for the per-digest summary — tests assert on counts.
      ActiveRecord::Base.connection.execute(
        "TRUNCATE performance_schema.events_statements_summary_by_digest",
      )

      WorkloadGenerator.run!(ActiveRecord::Base.connection)
    end

    # Every integration example opens against sakila — idempotent USE, safe
    # to repeat, and guarantees the current_database is known regardless of
    # whatever schema a previous test might have switched to.
    config.before(:each, integration: true) do
      ActiveRecord::Base.connection.execute("USE sakila")
    end
  end
end

# Shorthand for integration specs that need the Core adapter shape.
# Defined unconditionally so spec files parse cleanly even when
# REAL_MYSQL isn't set (filter_run_excluding keeps them from running).
def ar_core_adapter
  MysqlGenius::Core::Connection::ActiveRecordAdapter.new(ActiveRecord::Base.connection)
end
