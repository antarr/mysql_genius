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
      test_db = MysqlGenius::Desktop::Database.new(File.join(tmpdir, "test.db"))
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:new).and_return(fake_session))
      allow(launcher).to(receive(:start_server))
      allow(launcher).to(receive(:register_shutdown))
      allow(launcher).to(receive(:open_database).and_return(test_db))

      launcher.call(["--config", path])

      expect(MysqlGenius::Desktop::App.settings.mysql_genius_config).to(be_a(MysqlGenius::Desktop::Config))
      expect(MysqlGenius::Desktop::App.settings.active_session).to(equal(fake_session))
      expect(MysqlGenius::Desktop::App.settings.database).to(equal(test_db))
      expect(launcher).to(have_received(:start_server).with(port: 5555, bind: "127.0.0.1"))
    end
  end
end
