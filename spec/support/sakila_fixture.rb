# frozen_string_literal: true

require "open3"
require "zlib"

# Loads the Sakila sample database into the MySQL server that the current
# ActiveRecord connection points at. Used by integration specs
# (`spec/integration/`) as a realistic, read-only dataset against which the
# analysis classes can exercise real performance_schema output.
#
# Design notes:
#
#  - Idempotent: if the `sakila` schema already exists with a populated
#    `film` table, load! is a no-op. Pass SAKILA_RELOAD=1 to force a
#    fresh import.
#
#  - Shells out to the `mysql` CLI instead of running statements through
#    ActiveRecord. Sakila's schema uses DELIMITER directives for triggers
#    and stored procedures — an AR multi-statement split would choke on
#    them. The CLI is universally available wherever MySQL runs (CI images,
#    dev boxes, Homebrew's mysql-client, Docker exec), and piping a SQL
#    script through it is how Sakila is distributed anyway.
#
#  - Lives in the `sakila` schema, never in the app's test database.
#    This matches production multi-DB deployments and lets the same
#    fixture later serve as the "second database" for multi-DB integration
#    specs without a re-import.
module SakilaFixture
  SCHEMA_PATH = File.expand_path("../fixtures/sakila/schema.sql", __dir__)
  DATA_PATH_GZ = File.expand_path("../fixtures/sakila/data.sql.gz", __dir__)

  class LoadError < StandardError; end

  class << self
    # Loads Sakila into the configured MySQL server. Safe to call multiple
    # times — subsequent calls are no-ops unless force: true or SAKILA_RELOAD=1
    # is set. Returns true when a load happened, false when skipped.
    def load!(force: ENV["SAKILA_RELOAD"] == "1")
      ensure_mysql_cli_present!
      cfg = ar_config

      if !force && populated?(cfg)
        return false
      end

      run_mysql(cfg, File.read(SCHEMA_PATH))
      run_mysql(cfg, Zlib::GzipReader.open(DATA_PATH_GZ, &:read))
      true
    end

    # Reports whether the sakila schema exists and has data. A bare CREATE
    # SCHEMA without the inserts — e.g. a partial load — returns false so
    # the loader will try again.
    def populated?(cfg = ar_config)
      out, status = Open3.capture2(
        "mysql", *mysql_args(cfg), "-N", "-B",
        "-e", "SELECT COUNT(*) FROM sakila.film"
      )
      status.success? && out.to_s.strip.to_i.positive?
    rescue StandardError
      false
    end

    private

    def ensure_mysql_cli_present!
      _, status = Open3.capture2("mysql", "--version")
      return if status.success?

      raise LoadError, "sakila_fixture: `mysql` CLI not found on PATH. " \
        "Install it (brew install mysql-client) or run the integration suite in Docker — " \
        "see docs/guides/running-integration-tests.md."
    rescue Errno::ENOENT
      raise LoadError, "sakila_fixture: `mysql` CLI not found on PATH. " \
        "Install it (brew install mysql-client) or run the integration suite in Docker — " \
        "see docs/guides/running-integration-tests.md."
    end

    def run_mysql(cfg, sql)
      Open3.popen3("mysql", *mysql_args(cfg)) do |stdin, stdout, stderr, wait_thr|
        stdin.write(sql)
        stdin.close
        status = wait_thr.value
        next if status.success?

        raise LoadError,
          "sakila_fixture: mysql client exited #{status.exitstatus}: " \
            "#{stderr.read.to_s.strip} (stdout: #{stdout.read.to_s.strip})"
      end
    end

    # Pulls host/port/user/password from the current AR connection so the
    # mysql CLI targets the same server as the specs under test. Works on
    # Rails 6.1+ (configuration_hash) and falls back to .config on 6.0.
    def ar_config
      db_config = ActiveRecord::Base.connection_db_config
      if db_config.respond_to?(:configuration_hash)
        db_config.configuration_hash
      else
        db_config.config
      end
    end

    def mysql_args(cfg)
      args = []
      args << "-h#{cfg[:host] || cfg["host"] || "127.0.0.1"}"
      args << "-P#{cfg[:port] || cfg["port"] || 3306}"
      args << "-u#{cfg[:username] || cfg["username"] || "root"}"
      password = cfg[:password] || cfg["password"]
      args << "-p#{password}" if password && !password.to_s.empty?
      # Silence "Using a password on the command line is insecure" on stderr —
      # we're in a test fixture, not production.
      args << "--protocol=TCP"
      args
    end
  end
end
