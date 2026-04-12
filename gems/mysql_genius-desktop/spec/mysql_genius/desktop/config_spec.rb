# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "mysql_genius/desktop/config"

RSpec.describe(MysqlGenius::Desktop::Config) do
  let(:tmpdir) { @tmpdir } # rubocop:disable RSpec/InstanceVariable

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  def write_config(body)
    path = File.join(tmpdir, "mg.yml")
    File.write(path, body)
    path
  end

  describe ".load" do
    it "parses a minimal config with only required fields" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: localhost
          username: readonly
          database: app_development
      YAML

      config = described_class.load(path: path)
      expect(config.mysql.host).to(eq("localhost"))
      expect(config.mysql.port).to(eq(3306))
      expect(config.server.port).to(eq(4567))
      expect(config.security.blocked_tables).to(eq([]))
      expect(config.query.timeout_seconds).to(eq(10))
      expect(config.ai.enabled?).to(be(false))
      expect(config.source_path).to(eq(path))
    end

    it "parses a full config — mysql and server sections" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: db.example.com
          port: 3307
          username: readonly
          password: s3cret
          database: app_production
          tls_mode: required
        server:
          port: 8080
          bind: 127.0.0.1
      YAML

      config = described_class.load(path: path)
      expect(config.mysql.port).to(eq(3307))
      expect(config.mysql.tls_mode).to(eq("required"))
      expect(config.server.port).to(eq(8080))
    end

    it "parses a full config — security, query, and ai sections" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: db.example.com
          username: readonly
          database: app_production
        security:
          blocked_tables:
            - schema_migrations
        query:
          timeout_seconds: 30
        ai:
          endpoint: https://api.example.com/v1/chat/completions
          api_key: test-key
          model: gpt-4o-mini
          auth_style: bearer
      YAML

      config = described_class.load(path: path)
      expect(config.security.blocked_tables).to(eq(["schema_migrations"]))
      expect(config.query.query_timeout_ms).to(eq(30_000))
      expect(config.ai.enabled?).to(be(true))
      expect(config.ai.model).to(eq("gpt-4o-mini"))
    end

    it "interpolates ${ENV_VAR} references from ENV" do
      ENV["MG_TEST_HOST"] = "secret-host.internal"
      ENV["MG_TEST_PASS"] = "env-password"
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: ${MG_TEST_HOST}
          username: readonly
          password: ${MG_TEST_PASS}
          database: app_production
      YAML

      config = described_class.load(path: path)
      expect(config.mysql.host).to(eq("secret-host.internal"))
      expect(config.mysql.password).to(eq("env-password"))
    ensure
      ENV.delete("MG_TEST_HOST")
      ENV.delete("MG_TEST_PASS")
    end

    it "raises when ${ENV_VAR} references an unset variable" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: ${MG_MISSING_HOST}
          username: u
          database: d
      YAML

      expect { described_class.load(path: path) }
        .to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /references \$\{MG_MISSING_HOST\} but MG_MISSING_HOST is not set/))
    end

    it "raises when the config file does not exist and no lookup path matches" do
      missing = File.join(tmpdir, "nope.yml")
      expect { described_class.load(path: missing) }
        .to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /no config file found/))
    end

    it "raises when version: is missing" do
      path = write_config(<<~YAML)
        mysql:
          host: h
          username: u
          database: d
      YAML

      expect { described_class.load(path: path) }
        .to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /missing top-level version:/))
    end

    it "raises when version: is not 1" do
      path = write_config(<<~YAML)
        version: 2
        mysql:
          host: h
          username: u
          database: d
      YAML

      expect { described_class.load(path: path) }
        .to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /unsupported version 2 \(expected 1\)/))
    end

    it "raises when the mysql: section is missing entirely" do
      path = write_config(<<~YAML)
        version: 1
      YAML

      expect { described_class.load(path: path) }
        .to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /mysql: section is required/))
    end

    it "surfaces required-field errors from MysqlConfig" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: h
      YAML

      expect { described_class.load(path: path) }
        .to(raise_error(MysqlGenius::Desktop::Config::InvalidConfigError, /mysql: required fields missing: username, database/))
    end

    it "forwards override_port and override_bind to the ServerConfig" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: h
          username: u
          database: d
        server:
          port: 4567
          bind: 0.0.0.0
      YAML

      config = described_class.load(path: path, override_port: 9999, override_bind: "127.0.0.1")
      expect(config.server.port).to(eq(9999))
      expect(config.server.bind).to(eq("127.0.0.1"))
    end

    it "falls back to $MYSQL_GENIUS_CONFIG when path is nil" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: h
          username: u
          database: d
      YAML
      ENV["MYSQL_GENIUS_CONFIG"] = path

      config = described_class.load(path: nil)
      expect(config.source_path).to(eq(path))
    ensure
      ENV.delete("MYSQL_GENIUS_CONFIG")
    end
  end
end
