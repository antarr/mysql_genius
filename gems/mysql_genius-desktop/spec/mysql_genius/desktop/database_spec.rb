# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "mysql_genius/desktop/database"

RSpec.describe(MysqlGenius::Desktop::Database) do
  let(:tmpdir) { Dir.mktmpdir }
  let(:db_path) { File.join(tmpdir, "test.db") }
  let(:db) { described_class.new(db_path) }

  after { FileUtils.remove_entry(tmpdir) }

  def create_legacy_database(path)
    raw = SQLite3::Database.new(path)
    raw.execute_batch(<<~SQL)
      CREATE TABLE profiles (
        name TEXT PRIMARY KEY, host TEXT NOT NULL, port INTEGER DEFAULT 3306,
        username TEXT NOT NULL, password TEXT DEFAULT '', database_name TEXT NOT NULL,
        tls_mode TEXT DEFAULT 'preferred', created_at TEXT, updated_at TEXT
      );
      CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE stats_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT, digest_text TEXT NOT NULL,
        timestamp TEXT NOT NULL, delta_calls INTEGER DEFAULT 0,
        delta_total_time_ms REAL DEFAULT 0, delta_avg_time_ms REAL DEFAULT 0
      );
    SQL
    raw.execute("INSERT INTO profiles (name, host, username, database_name) VALUES ('old', 'h', 'u', 'd')")
    raw.close
  end

  describe "initialization" do
    it "creates the SQLite file if missing" do
      db
      expect(File.exist?(db_path)).to(be(true))
    end

    it "creates the profiles, settings, and stats_snapshots tables" do
      db
      raw = SQLite3::Database.new(db_path)
      tables = raw.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        .map(&:first)
        .reject { |t| t.start_with?("sqlite_") }
      expect(tables).to(contain_exactly("profiles", "settings", "stats_snapshots"))
    end
  end

  describe "Profile CRUD" do
    let(:profile_attrs) do
      {
        "name" => "prod",
        "host" => "db.prod.com",
        "port" => 3306,
        "username" => "readonly",
        "password" => "secret",
        "database_name" => "app_production",
        "tls_mode" => "preferred",
      }
    end

    describe "#list_profiles" do
      it "returns an empty array when no profiles exist" do
        expect(db.list_profiles).to(eq([]))
      end

      it "returns all profiles as hashes" do
        db.add_profile(profile_attrs)
        db.add_profile(profile_attrs.merge("name" => "staging", "host" => "db.staging.com"))
        profiles = db.list_profiles
        expect(profiles.length).to(eq(2))
        expect(profiles.first["name"]).to(eq("prod"))
        expect(profiles.last["name"]).to(eq("staging"))
      end
    end

    describe "#find_profile" do
      it "returns a hash for an existing profile" do
        db.add_profile(profile_attrs)
        profile = db.find_profile("prod")
        expect(profile["name"]).to(eq("prod"))
        expect(profile["host"]).to(eq("db.prod.com"))
        expect(profile["username"]).to(eq("readonly"))
        expect(profile["database_name"]).to(eq("app_production"))
      end

      it "returns nil for a non-existent profile" do
        expect(db.find_profile("nonexistent")).to(be_nil)
      end
    end

    describe "#add_profile" do
      it "inserts a new profile" do
        db.add_profile(profile_attrs)
        expect(db.list_profiles.length).to(eq(1))
      end

      it "sets created_at and updated_at timestamps" do
        db.add_profile(profile_attrs)
        profile = db.find_profile("prod")
        expect(profile["created_at"]).not_to(be_nil)
        expect(profile["updated_at"]).not_to(be_nil)
      end

      it "uses default port when not specified" do
        db.add_profile(profile_attrs.reject { |k, _| k == "port" })
        profile = db.find_profile("prod")
        expect(profile["port"]).to(eq(3306))
      end

      it "accepts database as an alias for database_name" do
        attrs = profile_attrs.reject { |k, _| k == "database_name" }
        attrs["database"] = "my_db"
        db.add_profile(attrs)
        profile = db.find_profile("prod")
        expect(profile["database_name"]).to(eq("my_db"))
      end

      it "raises DuplicateProfileError for duplicate names" do
        db.add_profile(profile_attrs)
        expect { db.add_profile(profile_attrs) }
          .to(raise_error(MysqlGenius::Desktop::Database::DuplicateProfileError))
      end
    end

    describe "#update_profile" do
      it "updates an existing profile" do
        db.add_profile(profile_attrs)
        db.update_profile("prod", profile_attrs.merge("host" => "new-host.com"))
        profile = db.find_profile("prod")
        expect(profile["host"]).to(eq("new-host.com"))
      end

      it "updates the updated_at timestamp" do
        db.add_profile(profile_attrs)
        original = db.find_profile("prod")["updated_at"]
        sleep(1.1)
        db.update_profile("prod", profile_attrs.merge("host" => "new-host.com"))
        updated = db.find_profile("prod")["updated_at"]
        expect(updated).not_to(eq(original))
      end

      it "raises ProfileNotFoundError for unknown profile" do
        expect { db.update_profile("unknown", profile_attrs) }
          .to(raise_error(MysqlGenius::Desktop::Database::ProfileNotFoundError))
      end
    end

    describe "#delete_profile" do
      it "removes an existing profile" do
        db.add_profile(profile_attrs)
        db.delete_profile("prod")
        expect(db.list_profiles).to(be_empty)
      end

      it "raises ProfileNotFoundError for unknown profile" do
        expect { db.delete_profile("unknown") }
          .to(raise_error(MysqlGenius::Desktop::Database::ProfileNotFoundError))
      end
    end

    describe "SSH fields" do
      let(:ssh_attrs) do
        profile_attrs.merge(
          "ssh_enabled" => 1,
          "ssh_host" => "bastion.prod.com",
          "ssh_port" => 2222,
          "ssh_user" => "deploy",
          "ssh_key_path" => "~/.ssh/id_rsa",
          "ssh_password" => "tunnel-pass",
          "remote_host" => "10.0.0.5",
          "remote_port" => 3307,
        )
      end

      it "stores and retrieves SSH fields on add_profile" do
        db.add_profile(ssh_attrs)
        profile = db.find_profile("prod")
        expect(profile["ssh_enabled"]).to(eq(1))
        expect(profile["ssh_host"]).to(eq("bastion.prod.com"))
        expect(profile["ssh_port"]).to(eq(2222))
        expect(profile["ssh_user"]).to(eq("deploy"))
        expect(profile["ssh_key_path"]).to(eq("~/.ssh/id_rsa"))
        expect(profile["ssh_password"]).to(eq("tunnel-pass"))
        expect(profile["remote_host"]).to(eq("10.0.0.5"))
        expect(profile["remote_port"]).to(eq(3307))
      end

      it "defaults ssh_enabled to 0 when not provided" do
        db.add_profile(profile_attrs)
        profile = db.find_profile("prod")
        expect(profile["ssh_enabled"]).to(eq(0))
      end

      it "defaults ssh_port to 22 and remote_port to 3306" do
        attrs = profile_attrs.merge("ssh_enabled" => 1, "ssh_host" => "bastion.prod.com")
        db.add_profile(attrs)
        profile = db.find_profile("prod")
        expect(profile["ssh_port"]).to(eq(22))
        expect(profile["remote_port"]).to(eq(3306))
      end

      it "round-trips SSH fields through update_profile" do
        db.add_profile(profile_attrs)
        db.update_profile("prod", ssh_attrs)
        profile = db.find_profile("prod")
        expect(profile["ssh_enabled"]).to(eq(1))
        expect(profile["ssh_host"]).to(eq("bastion.prod.com"))
        expect(profile["ssh_port"]).to(eq(2222))
        expect(profile["ssh_user"]).to(eq("deploy"))
        expect(profile["ssh_key_path"]).to(eq("~/.ssh/id_rsa"))
        expect(profile["ssh_password"]).to(eq("tunnel-pass"))
        expect(profile["remote_host"]).to(eq("10.0.0.5"))
        expect(profile["remote_port"]).to(eq(3307))
      end

      it "lists profiles with SSH fields" do
        db.add_profile(ssh_attrs)
        profiles = db.list_profiles
        expect(profiles.first["ssh_enabled"]).to(eq(1))
        expect(profiles.first["ssh_host"]).to(eq("bastion.prod.com"))
      end

      it "migrates SSH columns into a pre-existing database" do
        legacy_path = File.join(tmpdir, "legacy.db")
        create_legacy_database(legacy_path)
        legacy_db = described_class.new(legacy_path)
        profile = legacy_db.find_profile("old")
        expect(profile["ssh_enabled"]).to(eq(0))
        expect(profile["ssh_port"]).to(eq(22))
        expect(profile["remote_port"]).to(eq(3306))
      end
    end
  end

  describe "Settings" do
    describe "#get_setting / #set_setting" do
      it "returns nil for an unset key" do
        expect(db.get_setting("foo")).to(be_nil)
      end

      it "stores and retrieves a value" do
        db.set_setting("foo", "bar")
        expect(db.get_setting("foo")).to(eq("bar"))
      end

      it "upserts on conflict" do
        db.set_setting("foo", "bar")
        db.set_setting("foo", "baz")
        expect(db.get_setting("foo")).to(eq("baz"))
      end
    end

    describe "#get_ai_config / #set_ai_config" do
      it "returns an empty hash when no ai settings exist" do
        expect(db.get_ai_config).to(eq({}))
      end

      it "stores and retrieves AI config with prefix stripping" do
        db.set_ai_config("endpoint" => "https://api.openai.com", "model" => "gpt-4")
        config = db.get_ai_config
        expect(config["endpoint"]).to(eq("https://api.openai.com"))
        expect(config["model"]).to(eq("gpt-4"))
      end

      it "does not return non-ai settings" do
        db.set_setting("other.key", "value")
        db.set_ai_config("model" => "gpt-4")
        config = db.get_ai_config
        expect(config.keys).to(eq(["model"]))
      end
    end
  end

  describe "Stats" do
    let(:snapshot) do
      {
        "timestamp" => Time.now.utc.iso8601,
        "delta_calls" => 5,
        "delta_total_time_ms" => 123.4,
        "delta_avg_time_ms" => 24.68,
      }
    end

    describe "#record_snapshot" do
      it "inserts a snapshot row" do
        db.record_snapshot("SELECT 1", snapshot)
        series = db.series_for("SELECT 1")
        expect(series.length).to(eq(1))
        expect(series.first[:calls]).to(eq(5))
        expect(series.first[:total_time_ms]).to(eq(123.4))
      end

      it "accepts symbol keys" do
        sym_snapshot = {
          timestamp: Time.now.utc.iso8601,
          delta_calls: 3,
          delta_total_time_ms: 50.0,
          delta_avg_time_ms: 16.7,
        }
        db.record_snapshot("SELECT 1", sym_snapshot)
        series = db.series_for("SELECT 1")
        expect(series.first[:calls]).to(eq(3))
      end
    end

    describe "#series_for" do
      it "returns data ordered by timestamp" do
        db.record_snapshot("SELECT 1", snapshot.merge("timestamp" => Time.now.utc.iso8601))
        db.record_snapshot("SELECT 1", snapshot.merge("timestamp" => (Time.now.utc - 3600).iso8601))
        series = db.series_for("SELECT 1")
        expect(series.length).to(eq(2))
        expect(series.first[:timestamp] <= series.last[:timestamp]).to(be(true))
      end

      it "excludes data older than 24 hours" do
        db.record_snapshot("SELECT 1", snapshot.merge("timestamp" => Time.now.utc.iso8601))
        # Insert old data directly to bypass pruning
        raw = SQLite3::Database.new(db_path)
        raw.execute(
          "INSERT INTO stats_snapshots (digest_text, timestamp, delta_calls, delta_total_time_ms, delta_avg_time_ms) VALUES (?, ?, ?, ?, ?)",
          ["SELECT 1", (Time.now.utc - 100_000).iso8601, 1, 1.0, 1.0],
        )
        series = db.series_for("SELECT 1")
        expect(series.length).to(eq(1))
      end

      it "returns an empty array for unknown digest" do
        expect(db.series_for("SELECT unknown")).to(eq([]))
      end
    end

    describe "#digests" do
      it "returns distinct digest texts" do
        db.record_snapshot("SELECT 1", snapshot.merge("timestamp" => Time.now.utc.iso8601))
        db.record_snapshot("SELECT 2", snapshot.merge("timestamp" => Time.now.utc.iso8601))
        db.record_snapshot("SELECT 1", snapshot.merge("timestamp" => (Time.now.utc - 60).iso8601))
        expect(db.digests).to(contain_exactly("SELECT 1", "SELECT 2"))
      end
    end

    describe "#clear" do
      it "deletes all snapshot rows" do
        db.record_snapshot("SELECT 1", snapshot.merge("timestamp" => Time.now.utc.iso8601))
        db.clear
        expect(db.digests).to(be_empty)
      end
    end
  end
end
