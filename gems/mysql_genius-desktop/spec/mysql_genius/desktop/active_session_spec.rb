# frozen_string_literal: true

require "spec_helper"
require "trilogy"
require "mysql_genius/desktop/config"
require "mysql_genius/desktop/config/profile_config"
require "mysql_genius/desktop/ssh_tunnel"
require "mysql_genius/desktop/active_session"

RSpec.describe(MysqlGenius::Desktop::ActiveSession) do
  let(:config) do
    mysql = MysqlGenius::Desktop::Config::MysqlConfig.from_hash({ "host" => "localhost", "username" => "root", "database" => "test" })
    MysqlGenius::Desktop::Config.allocate.tap do |c|
      c.instance_variable_set(:@profiles,        [MysqlGenius::Desktop::Config::ProfileConfig.new(name: "default", mysql: mysql)])
      c.instance_variable_set(:@default_profile, "default")
      c.instance_variable_set(:@query,           MysqlGenius::Desktop::Config::QueryConfig.from_hash({ "timeout_seconds" => 5 }))
      c.instance_variable_set(:@security,        MysqlGenius::Desktop::Config::SecurityConfig.from_hash({}))
    end
  end

  let(:adapter) { instance_double(MysqlGenius::Core::Connection::TrilogyAdapter) }

  before do
    allow(adapter).to(receive(:exec_query).with("SELECT VERSION()").and_return(instance_double(MysqlGenius::Core::Result)))
    allow(adapter).to(receive(:close))
    allow(described_class).to(receive(:open_adapter_for).with(config, tunnel_port: nil).and_return(adapter))
  end

  describe "#initialize" do
    it "opens the adapter and runs a health check query" do
      described_class.new(config)
      expect(adapter).to(have_received(:exec_query).with("SELECT VERSION()"))
    end

    it "raises ConnectError when open_adapter_for raises" do
      allow(described_class).to(receive(:open_adapter_for).with(config, tunnel_port: nil).and_raise(StandardError, "connect refused"))
      expect { described_class.new(config) }
        .to(raise_error(MysqlGenius::Desktop::ActiveSession::ConnectError, /Failed to connect to MySQL at localhost:3306: connect refused/))
    end

    it "raises ConnectError when the health check query raises" do
      allow(adapter).to(receive(:exec_query).with("SELECT VERSION()").and_raise(StandardError, "access denied"))
      expect { described_class.new(config) }
        .to(raise_error(MysqlGenius::Desktop::ActiveSession::ConnectError, /Failed to connect to MySQL at localhost:3306: access denied/))
    end
  end

  describe "#checkout" do
    subject(:session) { described_class.new(config) }

    it "yields the adapter to the block and returns the block's value" do
      result = session.checkout { |a| a.respond_to?(:exec_query) ? "got-adapter" : "no" }
      expect(result).to(eq("got-adapter"))
    end

    it "serializes concurrent access via a mutex" do
      mutex = session.instance_variable_get(:@mutex)
      expect(mutex).to(be_a(Mutex))

      inside = false
      t = Thread.new do
        session.checkout do |_|
          inside = true
          sleep(0.05)
        end
      end
      sleep(0.01)
      expect(mutex.locked?).to(be(true))
      t.join
      expect(inside).to(be(true))
      expect(mutex.locked?).to(be(false))
    end

    it "retries exactly once on Trilogy::ConnectionResetError" do
      call_count = 0
      allow(adapter).to(receive(:close))

      new_adapter = instance_double(MysqlGenius::Core::Connection::TrilogyAdapter)
      allow(new_adapter).to(receive(:close))
      allow(described_class).to(receive(:open_adapter_for).with(config, tunnel_port: nil).and_return(adapter, new_adapter))

      result = session.checkout do |a|
        call_count += 1
        raise Trilogy::ConnectionResetError, "dead connection" if call_count == 1 && a.equal?(adapter)

        "ok-on-retry"
      end
      expect(result).to(eq("ok-on-retry"))
      expect(call_count).to(eq(2))
      expect(adapter).to(have_received(:close))
    end

    it "retries exactly once on Trilogy::ProtocolError" do
      call_count = 0
      new_adapter = instance_double(MysqlGenius::Core::Connection::TrilogyAdapter)
      allow(new_adapter).to(receive(:close))
      allow(described_class).to(receive(:open_adapter_for).with(config, tunnel_port: nil).and_return(adapter, new_adapter))

      session.checkout do |_|
        call_count += 1
        raise Trilogy::ProtocolError, "bad packet" if call_count == 1
      end
      expect(call_count).to(eq(2))
    end

    it "does not retry on other Trilogy errors (QueryError propagates)" do
      call_count = 0
      expect do
        session.checkout do |_|
          call_count += 1
          raise Trilogy::QueryError, "syntax error at line 1"
        end
      end.to(raise_error(Trilogy::QueryError, /syntax error/))
      expect(call_count).to(eq(1))
    end

    it "raises the retry error when the retry itself fails" do
      call_count = 0
      new_adapter = instance_double(MysqlGenius::Core::Connection::TrilogyAdapter)
      allow(new_adapter).to(receive(:close))
      allow(described_class).to(receive(:open_adapter_for).with(config, tunnel_port: nil).and_return(adapter, new_adapter))

      expect do
        session.checkout do |_|
          call_count += 1
          raise Trilogy::ConnectionResetError, "dead"
        end
      end.to(raise_error(Trilogy::ConnectionResetError))
      expect(call_count).to(eq(2))
    end
  end

  describe "#close" do
    it "closes the adapter and is safe to call more than once" do
      session = described_class.new(config)
      session.close
      expect(adapter).to(have_received(:close).at_least(:once))
      expect { session.close }.not_to(raise_error)
    end
  end

  describe "#tunnel_port" do
    it "returns nil when SSH is not enabled" do
      session = described_class.new(config)
      expect(session.tunnel_port).to(be_nil)
    end
  end

  context "with SSH tunnel enabled" do
    let(:ssh_config) do
      mysql = MysqlGenius::Desktop::Config::MysqlConfig.from_hash(
        "host" => "db.internal",
        "username" => "root",
        "database" => "test",
        "ssh_enabled" => 1,
        "ssh_host" => "bastion.example.com",
        "ssh_user" => "deploy",
        "ssh_port" => 22,
      )
      MysqlGenius::Desktop::Config.allocate.tap do |c|
        c.instance_variable_set(:@profiles, [MysqlGenius::Desktop::Config::ProfileConfig.new(name: "default", mysql: mysql)])
        c.instance_variable_set(:@default_profile, "default")
        c.instance_variable_set(:@query, MysqlGenius::Desktop::Config::QueryConfig.from_hash({ "timeout_seconds" => 5 }))
        c.instance_variable_set(:@security, MysqlGenius::Desktop::Config::SecurityConfig.from_hash({}))
      end
    end

    let(:tunnel) { instance_double(MysqlGenius::Desktop::SshTunnel, local_port: 13306, start: 13306, stop: nil, running?: true) }

    before do
      allow(MysqlGenius::Desktop::SshTunnel).to(receive(:new).and_return(tunnel))
      allow(described_class).to(receive(:open_adapter_for).with(ssh_config, tunnel_port: 13306).and_return(adapter))
    end

    it "starts an SSH tunnel before connecting" do
      described_class.new(ssh_config)

      expect(MysqlGenius::Desktop::SshTunnel).to(have_received(:new).with(
        ssh_host: "bastion.example.com",
        ssh_port: 22,
        ssh_user: "deploy",
        ssh_key_path: nil,
        ssh_password: nil,
        remote_host: "db.internal",
        remote_port: 3306,
      ))
      expect(tunnel).to(have_received(:start))
    end

    it "connects Trilogy through the tunnel port" do
      described_class.new(ssh_config)

      expect(described_class).to(have_received(:open_adapter_for).with(ssh_config, tunnel_port: 13306))
    end

    it "exposes the tunnel port" do
      session = described_class.new(ssh_config)
      expect(session.tunnel_port).to(eq(13306))
    end

    it "stops the tunnel on close" do
      session = described_class.new(ssh_config)
      session.close
      expect(tunnel).to(have_received(:stop))
    end

    it "raises ConnectError with SSH host when tunnel fails" do
      allow(MysqlGenius::Desktop::SshTunnel).to(receive(:new).and_return(tunnel))
      allow(tunnel).to(receive(:start).and_raise(
        MysqlGenius::Desktop::SshTunnel::ConnectionError, "auth failed"
      ))

      expect { described_class.new(ssh_config) }
        .to(raise_error(MysqlGenius::Desktop::ActiveSession::ConnectError, /Failed to open SSH tunnel to bastion\.example\.com/))
    end

    it "restarts the tunnel on connection retry" do
      allow(described_class).to(receive(:open_adapter_for).with(ssh_config, tunnel_port: 13306).and_return(adapter))
      session = described_class.new(ssh_config)

      call_count = 0
      new_adapter = instance_double(MysqlGenius::Core::Connection::TrilogyAdapter)
      allow(new_adapter).to(receive(:close))

      new_tunnel = instance_double(MysqlGenius::Desktop::SshTunnel, local_port: 14306, start: 14306, stop: nil, running?: true)
      allow(MysqlGenius::Desktop::SshTunnel).to(receive(:new).and_return(new_tunnel))
      allow(described_class).to(receive(:open_adapter_for).with(ssh_config, tunnel_port: 14306).and_return(new_adapter))

      session.checkout do |_|
        call_count += 1
        raise Trilogy::ConnectionResetError, "dead" if call_count == 1
      end

      expect(tunnel).to(have_received(:stop))
      expect(new_tunnel).to(have_received(:start))
      expect(call_count).to(eq(2))
    end
  end
end
