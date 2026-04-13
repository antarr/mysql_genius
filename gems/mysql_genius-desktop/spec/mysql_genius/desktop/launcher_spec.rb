# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "mysql_genius/desktop/launcher"
require "mysql_genius/desktop/database"

RSpec.describe(MysqlGenius::Desktop::Launcher) do
  let(:launcher) { described_class.new }

  describe "#parse" do
    it "parses --config, --port, --bind, --version, --help" do
      options = launcher.send(:parse, ["--config", "/tmp/mg.yml", "--port", "8080", "--bind", "0.0.0.0"])
      expect(options[:config]).to(eq("/tmp/mg.yml"))
      expect(options[:port]).to(eq(8080))
      expect(options[:bind]).to(eq("0.0.0.0"))
      expect(options[:version]).to(be_nil)
      expect(options[:help]).to(be_nil)
    end

    it "flags --version" do
      options = launcher.send(:parse, ["--version"])
      expect(options[:version]).to(be(true))
    end

    it "flags --help" do
      options = launcher.send(:parse, ["-h"])
      expect(options[:help]).to(be(true))
    end

    it "coerces --port to an Integer" do
      options = launcher.send(:parse, ["--port", "9999"])
      expect(options[:port]).to(eq(9999))
      expect(options[:port]).to(be_a(Integer))
    end
  end

  describe "#call" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.rm_rf(tmpdir) }

    def write_config(body)
      path = File.join(tmpdir, "mg.yml")
      File.write(path, body)
      path
    end

    def stub_boot(session:, db_name: "test.db")
      test_db = MysqlGenius::Desktop::Database.new(File.join(tmpdir, db_name))
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:new).and_return(session))
      allow(launcher).to(receive(:start_server))
      allow(launcher).to(receive(:register_shutdown))
      allow(launcher).to(receive(:open_database).and_return(test_db))
      test_db
    end

    it "prints the version for --version and exits zero" do
      expect { launcher.call(["--version"]) }.to(output(/mysql-genius-sidecar #{MysqlGenius::Desktop::VERSION}/).to_stdout)
    end

    it "prints usage for --help and exits zero" do
      expect { launcher.call(["--help"]) }.to(output(/Usage: mysql-genius-sidecar/).to_stdout)
    end

    it "prints a helpful error and exits 1 when the config file is missing" do
      exit_status = nil
      expect do
        launcher.call(["--config", File.join(tmpdir, "nope.yml")])
      rescue SystemExit => e
        exit_status = e.status
      end.to(output(/mysql-genius-sidecar: .*no config file/).to_stderr)
      expect(exit_status).to(eq(1))
    end

    it "prints a helpful error and exits 1 when MySQL is unreachable" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: 127.0.0.1
          port: 1
          username: u
          database: d
      YAML
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:new).and_raise(MysqlGenius::Desktop::ActiveSession::ConnectError, "Failed to connect"))

      exit_status = nil
      expect do
        launcher.call(["--config", path])
      rescue SystemExit => e
        exit_status = e.status
      end.to(output(/mysql-genius-sidecar: Failed to connect/).to_stderr)
      expect(exit_status).to(eq(1))
    end

    it "wires Config → ActiveSession → App and starts the server on the configured port and bind" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: 127.0.0.1
          username: u
          database: d
        server:
          port: 5555
          bind: 127.0.0.1
      YAML

      fake_session = instance_double(MysqlGenius::Desktop::ActiveSession, close: nil, tunnel_port: nil)
      test_db = stub_boot(session: fake_session)

      launcher.call(["--config", path])

      expect(MysqlGenius::Desktop::App.settings.mysql_genius_config).to(be_a(MysqlGenius::Desktop::Config))
      expect(MysqlGenius::Desktop::App.settings.active_session).to(equal(fake_session))
      expect(MysqlGenius::Desktop::App.settings.database).to(equal(test_db))
      expect(launcher).to(have_received(:start_server).with(port: 5555, bind: "127.0.0.1"))
    end

    it "imports SSH fields when seeding profiles from YAML config" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: db.internal
          username: admin
          database: app
          ssh_enabled: 1
          ssh_host: bastion.example.com
          ssh_port: 22
          ssh_user: deploy
          ssh_key_path: ~/.ssh/id_rsa
        server:
          port: 5556
          bind: 127.0.0.1
      YAML

      fake_session = instance_double(MysqlGenius::Desktop::ActiveSession, close: nil, tunnel_port: 13306)
      test_db = stub_boot(session: fake_session, db_name: "test_ssh.db")
      launcher.call(["--config", path])

      profile = test_db.list_profiles.first
      expect(profile["ssh_enabled"]).to(eq(1))
      expect(profile["ssh_host"]).to(eq("bastion.example.com"))
      expect(profile["ssh_user"]).to(eq("deploy"))
      expect(profile["ssh_key_path"]).to(eq("~/.ssh/id_rsa"))
    end

    it "captures tunnel_port from the session for the stats collector conn_proc" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: db.internal
          username: admin
          database: app
        server:
          port: 5557
          bind: 127.0.0.1
      YAML

      fake_session = instance_double(MysqlGenius::Desktop::ActiveSession, close: nil, tunnel_port: 13306)
      stub_boot(session: fake_session, db_name: "test_tp.db")
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:open_adapter_for))
      captured_proc = nil
      allow(MysqlGenius::Core::Analysis::StatsCollector).to(receive(:new)) do |**kwargs|
        captured_proc = kwargs[:connection_provider]
        instance_double(MysqlGenius::Core::Analysis::StatsCollector, start: nil, stop: nil)
      end

      launcher.call(["--config", path])
      captured_proc.call

      expect(MysqlGenius::Desktop::ActiveSession).to(have_received(:open_adapter_for).with(anything, tunnel_port: 13306))
    end

    it "registers shutdown that closes both the session and collector" do
      path = write_config(<<~YAML)
        version: 1
        mysql:
          host: 127.0.0.1
          username: u
          database: d
        server:
          port: 5558
          bind: 127.0.0.1
      YAML

      fake_session = instance_double(MysqlGenius::Desktop::ActiveSession, close: nil, tunnel_port: nil)
      stub_boot(session: fake_session, db_name: "test_sd.db")
      captured_session = nil
      captured_collector = nil
      allow(launcher).to(receive(:register_shutdown)) do |session, collector|
        captured_session = session
        captured_collector = collector
      end

      launcher.call(["--config", path])

      expect(captured_session).to(equal(fake_session))
      expect(captured_collector).to(be_a(MysqlGenius::Core::Analysis::StatsCollector))
    end
  end
end
