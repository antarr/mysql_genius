# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "yaml"
require "mysql_genius/desktop/profile_manager"

RSpec.describe(MysqlGenius::Desktop::ProfileManager) do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmpdir) }

  def write_config(body)
    path = File.join(tmpdir, "mg.yml")
    File.write(path, body)
    path
  end

  def manager_for(yaml_body)
    path = write_config(yaml_body)
    described_class.new(path)
  end

  describe "#list" do
    it "returns all profiles with name and mysql hash" do
      mgr = manager_for(<<~YAML)
        version: 2
        profiles:
          - name: prod
            mysql:
              host: db.prod.com
              username: readonly
              database: app_production
          - name: staging
            mysql:
              host: db.staging.com
              username: readonly
              database: app_staging
      YAML

      profiles = mgr.list
      expect(profiles.length).to(eq(2))
      expect(profiles.first[:name]).to(eq("prod"))
      expect(profiles.first[:mysql]["host"]).to(eq("db.prod.com"))
    end
  end

  describe "#add" do
    it "appends a new profile and persists to the YAML file" do
      mgr = manager_for(<<~YAML)
        version: 2
        profiles:
          - name: prod
            mysql:
              host: db.prod.com
              username: readonly
              database: app_production
      YAML

      mgr.add(name: "staging", mysql: { "host" => "db.staging.com", "username" => "readonly", "database" => "app_staging" })

      reloaded = YAML.safe_load_file(mgr.instance_variable_get(:@source_path), permitted_classes: [], aliases: false)
      expect(reloaded["profiles"].length).to(eq(2))
      expect(reloaded["profiles"].last["name"]).to(eq("staging"))
      expect(reloaded["version"]).to(eq(2))
    end

    it "raises DuplicateProfileError when the name already exists" do
      mgr = manager_for(<<~YAML)
        version: 2
        profiles:
          - name: prod
            mysql:
              host: h
              username: u
              database: d
      YAML

      expect { mgr.add(name: "prod", mysql: { "host" => "h", "username" => "u", "database" => "d" }) }
        .to(raise_error(MysqlGenius::Desktop::ProfileManager::DuplicateProfileError))
    end
  end

  describe "#update" do
    it "updates an existing profile's mysql section" do
      mgr = manager_for(<<~YAML)
        version: 2
        profiles:
          - name: prod
            mysql:
              host: old-host.com
              username: readonly
              database: app_production
      YAML

      mgr.update(name: "prod", mysql: { "host" => "new-host.com", "username" => "readonly", "database" => "app_production" })

      reloaded = YAML.safe_load_file(mgr.instance_variable_get(:@source_path), permitted_classes: [], aliases: false)
      expect(reloaded["profiles"].first["mysql"]["host"]).to(eq("new-host.com"))
    end

    it "raises ProfileNotFoundError for unknown profile name" do
      mgr = manager_for(<<~YAML)
        version: 2
        profiles:
          - name: prod
            mysql:
              host: h
              username: u
              database: d
      YAML

      expect { mgr.update(name: "unknown", mysql: {}) }
        .to(raise_error(MysqlGenius::Desktop::ProfileManager::ProfileNotFoundError))
    end
  end

  describe "#delete" do
    it "removes a profile and persists" do
      mgr = manager_for(<<~YAML)
        version: 2
        profiles:
          - name: prod
            mysql:
              host: h
              username: u
              database: d
          - name: staging
            mysql:
              host: h2
              username: u
              database: d2
      YAML

      mgr.delete(name: "staging", current_profile: "prod")

      reloaded = YAML.safe_load_file(mgr.instance_variable_get(:@source_path), permitted_classes: [], aliases: false)
      expect(reloaded["profiles"].length).to(eq(1))
      expect(reloaded["profiles"].first["name"]).to(eq("prod"))
    end

    it "raises ActiveProfileError when deleting the current profile" do
      mgr = manager_for(<<~YAML)
        version: 2
        profiles:
          - name: prod
            mysql:
              host: h
              username: u
              database: d
      YAML

      expect { mgr.delete(name: "prod", current_profile: "prod") }
        .to(raise_error(MysqlGenius::Desktop::ProfileManager::ActiveProfileError))
    end

    it "raises ProfileNotFoundError for unknown profile" do
      mgr = manager_for(<<~YAML)
        version: 2
        profiles:
          - name: prod
            mysql:
              host: h
              username: u
              database: d
      YAML

      expect { mgr.delete(name: "unknown", current_profile: "prod") }
        .to(raise_error(MysqlGenius::Desktop::ProfileManager::ProfileNotFoundError))
    end
  end

  describe "#test_connection" do
    it "returns success with version when the connection works" do
      adapter = instance_double(MysqlGenius::Core::Connection::TrilogyAdapter)
      allow(adapter).to(receive(:exec_query).with("SELECT VERSION()").and_return(
        instance_double(MysqlGenius::Core::Result, rows: [["8.0.35"]]),
      ))
      allow(adapter).to(receive(:close))
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:open_adapter_for).and_return(adapter))

      mgr = manager_for("version: 2\nprofiles: []")
      result = mgr.test_connection(mysql: { "host" => "localhost", "username" => "root", "database" => "test" })
      expect(result[:success]).to(be(true))
      expect(result[:version]).to(eq("8.0.35"))
    end

    it "returns failure with error message when the connection fails" do
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:open_adapter_for).and_raise(StandardError, "connection refused"))

      mgr = manager_for("version: 2\nprofiles: []")
      result = mgr.test_connection(mysql: { "host" => "localhost", "username" => "root", "database" => "test" })
      expect(result[:success]).to(be(false))
      expect(result[:error]).to(include("connection refused"))
    end
  end
end
