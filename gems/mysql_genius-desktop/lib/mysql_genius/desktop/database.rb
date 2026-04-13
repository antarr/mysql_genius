# frozen_string_literal: true

require "sqlite3"

module MysqlGenius
  module Desktop
    class Database
      class DuplicateProfileError < StandardError; end
      class ProfileNotFoundError < StandardError; end

      def initialize(path)
        @db = SQLite3::Database.new(path)
        @db.execute("PRAGMA journal_mode=WAL")
        @db.results_as_hash = true
        create_schema
      end

      # --- Profiles ---

      def list_profiles
        @db.execute("SELECT * FROM profiles ORDER BY name")
      end

      def find_profile(name)
        rows = @db.execute("SELECT * FROM profiles WHERE name = ?", [name])
        rows.first
      end

      def add_profile(attrs)
        raise DuplicateProfileError, "Profile '#{attrs["name"]}' already exists" if find_profile(attrs["name"])

        now = Time.now.utc.iso8601
        @db.execute(
          <<~SQL.tr("\n", " ").strip,
            INSERT INTO profiles
            (name, host, port, username, password, database_name, tls_mode,
             ssh_enabled, ssh_host, ssh_port, ssh_user, ssh_key_path, ssh_password, remote_host, remote_port,
             created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            attrs["name"],
            attrs["host"],
            attrs.fetch("port", 3306),
            attrs["username"],
            attrs.fetch("password", ""),
            attrs["database_name"] || attrs["database"],
            attrs.fetch("tls_mode", "preferred"),
            attrs.fetch("ssh_enabled", 0).to_i,
            attrs["ssh_host"],
            attrs.fetch("ssh_port", 22),
            attrs["ssh_user"],
            attrs["ssh_key_path"],
            attrs["ssh_password"],
            attrs["remote_host"],
            attrs.fetch("remote_port", 3306),
            now,
            now,
          ],
        )
      end

      def update_profile(name, attrs)
        raise ProfileNotFoundError, "Profile '#{name}' not found" unless find_profile(name)

        now = Time.now.utc.iso8601
        @db.execute(
          <<~SQL.tr("\n", " ").strip,
            UPDATE profiles SET
              host = ?, port = ?, username = ?, password = ?, database_name = ?, tls_mode = ?,
              ssh_enabled = ?, ssh_host = ?, ssh_port = ?, ssh_user = ?, ssh_key_path = ?, ssh_password = ?,
              remote_host = ?, remote_port = ?,
              updated_at = ?
            WHERE name = ?
          SQL
          [
            attrs["host"],
            attrs.fetch("port", 3306),
            attrs["username"],
            attrs.fetch("password", ""),
            attrs["database_name"] || attrs["database"],
            attrs.fetch("tls_mode", "preferred"),
            attrs.fetch("ssh_enabled", 0).to_i,
            attrs["ssh_host"],
            attrs.fetch("ssh_port", 22),
            attrs["ssh_user"],
            attrs["ssh_key_path"],
            attrs["ssh_password"],
            attrs["remote_host"],
            attrs.fetch("remote_port", 3306),
            now,
            name,
          ],
        )
      end

      def delete_profile(name)
        raise ProfileNotFoundError, "Profile '#{name}' not found" unless find_profile(name)

        @db.execute("DELETE FROM profiles WHERE name = ?", [name])
      end

      # --- Settings ---

      def get_setting(key)
        rows = @db.execute("SELECT value FROM settings WHERE key = ?", [key])
        rows.first&.fetch("value")
      end

      def set_setting(key, value)
        @db.execute(
          "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          [key, value],
        )
      end

      def get_ai_config # rubocop:disable Naming/AccessorMethodName
        rows = @db.execute("SELECT key, value FROM settings WHERE key LIKE 'ai.%'")
        rows.each_with_object({}) do |row, hash|
          stripped_key = row["key"].sub(/\Aai\./, "")
          hash[stripped_key] = row["value"]
        end
      end

      def set_ai_config(hash) # rubocop:disable Naming/AccessorMethodName
        hash.each do |key, value|
          set_setting("ai.#{key}", value)
        end
      end

      # --- Stats ---

      def record_snapshot(digest_text, snapshot)
        now = snapshot["timestamp"] || snapshot[:timestamp] || Time.now.utc.iso8601
        @db.execute(
          "INSERT INTO stats_snapshots (digest_text, timestamp, delta_calls, delta_total_time_ms, delta_avg_time_ms) VALUES (?, ?, ?, ?, ?)",
          [
            digest_text,
            now,
            snapshot["delta_calls"] || snapshot[:delta_calls] || 0,
            snapshot["delta_total_time_ms"] || snapshot[:delta_total_time_ms] || 0.0,
            snapshot["delta_avg_time_ms"] || snapshot[:delta_avg_time_ms] || 0.0,
          ],
        )
        prune_old_snapshots
      end

      def series_for(digest_text)
        cutoff = (Time.now.utc - 86_400).iso8601
        @db.execute(
          "SELECT timestamp, delta_calls, delta_total_time_ms, delta_avg_time_ms FROM stats_snapshots WHERE digest_text = ? AND timestamp >= ? ORDER BY timestamp",
          [digest_text, cutoff],
        ).map do |row|
          {
            timestamp: row["timestamp"],
            calls: row["delta_calls"],
            total_time_ms: row["delta_total_time_ms"],
            avg_time_ms: row["delta_avg_time_ms"],
          }
        end
      end

      def digests
        @db.execute("SELECT DISTINCT digest_text FROM stats_snapshots").map { |r| r["digest_text"] }
      end

      def clear
        @db.execute("DELETE FROM stats_snapshots")
      end

      private

      def create_schema
        @db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS profiles (
            name TEXT PRIMARY KEY,
            host TEXT NOT NULL,
            port INTEGER DEFAULT 3306,
            username TEXT NOT NULL,
            password TEXT DEFAULT '',
            database_name TEXT NOT NULL,
            tls_mode TEXT DEFAULT 'preferred',
            ssh_enabled INTEGER DEFAULT 0,
            ssh_host TEXT,
            ssh_port INTEGER DEFAULT 22,
            ssh_user TEXT,
            ssh_key_path TEXT,
            ssh_password TEXT,
            remote_host TEXT,
            remote_port INTEGER DEFAULT 3306,
            created_at TEXT,
            updated_at TEXT
          );

          CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT
          );

          CREATE TABLE IF NOT EXISTS stats_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            digest_text TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            delta_calls INTEGER DEFAULT 0,
            delta_total_time_ms REAL DEFAULT 0,
            delta_avg_time_ms REAL DEFAULT 0
          );

          CREATE INDEX IF NOT EXISTS idx_stats_digest_ts ON stats_snapshots(digest_text, timestamp);
        SQL

        migrate_ssh_columns
      end

      def migrate_ssh_columns
        existing = @db.execute("PRAGMA table_info(profiles)").map { |col| col["name"] }
        ssh_columns = {
          "ssh_enabled" => "INTEGER DEFAULT 0",
          "ssh_host" => "TEXT",
          "ssh_port" => "INTEGER DEFAULT 22",
          "ssh_user" => "TEXT",
          "ssh_key_path" => "TEXT",
          "ssh_password" => "TEXT",
          "remote_host" => "TEXT",
          "remote_port" => "INTEGER DEFAULT 3306",
        }
        ssh_columns.each do |name, type|
          next if existing.include?(name)

          @db.execute("ALTER TABLE profiles ADD COLUMN #{name} #{type}")
        end
      end

      def prune_old_snapshots
        cutoff = (Time.now.utc - 86_400).iso8601
        @db.execute("DELETE FROM stats_snapshots WHERE timestamp < ?", [cutoff])
      end
    end
  end
end
