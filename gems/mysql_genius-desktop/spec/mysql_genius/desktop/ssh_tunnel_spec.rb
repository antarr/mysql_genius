# frozen_string_literal: true

require "spec_helper"
require "net/ssh"
require "mysql_genius/desktop/ssh_tunnel"

RSpec.describe(MysqlGenius::Desktop::SshTunnel) do
  let(:ssh_host)    { "bastion.example.com" }
  let(:ssh_user)    { "deploy" }
  let(:remote_host) { "db.internal" }

  let(:forward_handler) { instance_double(Net::SSH::Service::Forward) }
  let(:ssh_session) do
    instance_double(Net::SSH::Connection::Session, forward: forward_handler, closed?: false).tap do |s|
      allow(s).to(receive(:loop))
      allow(s).to(receive(:close))
    end
  end

  before do
    allow(Net::SSH).to(receive(:start).and_return(ssh_session))
    allow(forward_handler).to(receive(:local))
  end

  describe "#initialize" do
    it "accepts required and optional keyword arguments" do
      tunnel = described_class.new(
        ssh_host: ssh_host,
        ssh_user: ssh_user,
        ssh_port: 2222,
        ssh_key_path: "~/.ssh/id_rsa",
        remote_host: remote_host,
        remote_port: 3307,
        local_port: 13306,
      )
      expect(tunnel).not_to(be_running)
    end

    it "defaults ssh_port to 22, remote_port to 3306, local_port to 0" do
      tunnel = described_class.new(ssh_host: ssh_host, ssh_user: ssh_user, remote_host: remote_host)
      expect(tunnel.local_port).to(eq(0))
    end
  end

  describe "#start" do
    subject(:tunnel) do
      described_class.new(ssh_host: ssh_host, ssh_user: ssh_user, remote_host: remote_host)
    end

    it "opens an SSH session and sets up port forwarding" do
      tunnel.start
      expect(Net::SSH).to(have_received(:start).with(ssh_host, ssh_user, hash_including(port: 22)))
      expect(forward_handler).to(have_received(:local).with(anything, remote_host, 3306))
      tunnel.stop
    end

    it "returns the allocated local port" do
      port = tunnel.start
      expect(port).to(be_a(Integer))
      expect(port).to(be > 0)
      tunnel.stop
    end

    it "uses key-based auth when ssh_key_path is provided" do
      tunnel = described_class.new(
        ssh_host: ssh_host,
        ssh_user: ssh_user,
        ssh_key_path: "~/.ssh/id_rsa",
        remote_host: remote_host,
      )
      tunnel.start
      expect(Net::SSH).to(have_received(:start).with(
        ssh_host,
        ssh_user,
        hash_including(keys: [File.expand_path("~/.ssh/id_rsa")], keys_only: true),
      ))
      tunnel.stop
    end

    it "uses password auth when ssh_password is provided" do
      tunnel = described_class.new(
        ssh_host: ssh_host,
        ssh_user: ssh_user,
        ssh_password: "s3cret",
        remote_host: remote_host,
      )
      tunnel.start
      expect(Net::SSH).to(have_received(:start).with(
        ssh_host,
        ssh_user,
        hash_including(password: "s3cret", auth_methods: ["password"]),
      ))
      tunnel.stop
    end

    it "falls back to ssh-agent when neither key nor password is provided" do
      tunnel.start
      expect(Net::SSH).to(have_received(:start).with(
        ssh_host,
        ssh_user,
        hash_excluding(:keys, :keys_only, :password, :auth_methods),
      ))
      tunnel.stop
    end

    it "enables keepalive on the SSH session" do
      tunnel.start
      expect(Net::SSH).to(have_received(:start).with(
        ssh_host,
        ssh_user,
        hash_including(keepalive: true, keepalive_interval: 30),
      ))
      tunnel.stop
    end

    it "starts a background thread for the event loop" do
      tunnel.start
      thread = tunnel.instance_variable_get(:@thread)
      expect(thread).to(be_a(Thread))
      expect(thread).to(be_alive)
      tunnel.stop
    end

    it "raises ConnectionError when already running" do
      tunnel.start
      expect { tunnel.start }
        .to(raise_error(MysqlGenius::Desktop::SshTunnel::ConnectionError, /already running/))
      tunnel.stop
    end

    it "raises ConnectionError on authentication failure" do
      allow(Net::SSH).to(receive(:start).and_raise(Net::SSH::AuthenticationFailed.new("bad key")))
      expect { tunnel.start }
        .to(raise_error(MysqlGenius::Desktop::SshTunnel::ConnectionError, /SSH authentication failed/))
    end

    it "raises ConnectionError when SSH host is unreachable" do
      allow(Net::SSH).to(receive(:start).and_raise(SocketError.new("getaddrinfo: nodename nor servname")))
      expect { tunnel.start }
        .to(raise_error(MysqlGenius::Desktop::SshTunnel::ConnectionError, /Cannot reach SSH host/))
    end

    it "raises ConnectionError on connection refused" do
      allow(Net::SSH).to(receive(:start).and_raise(Errno::ECONNREFUSED.new("Connection refused")))
      expect { tunnel.start }
        .to(raise_error(MysqlGenius::Desktop::SshTunnel::ConnectionError, /Cannot reach SSH host/))
    end

    it "raises ConnectionError on generic Net::SSH error" do
      allow(Net::SSH).to(receive(:start).and_raise(Net::SSH::Exception.new("handshake failed")))
      expect { tunnel.start }
        .to(raise_error(MysqlGenius::Desktop::SshTunnel::ConnectionError, /SSH connection to.*failed/))
    end

    it "uses a specific local port when provided" do
      tunnel = described_class.new(
        ssh_host: ssh_host,
        ssh_user: ssh_user,
        remote_host: remote_host,
        local_port: 13306,
      )
      port = tunnel.start
      expect(port).to(eq(13306))
      expect(forward_handler).to(have_received(:local).with(13306, remote_host, 3306))
      tunnel.stop
    end
  end

  describe "#stop" do
    subject(:tunnel) do
      described_class.new(ssh_host: ssh_host, ssh_user: ssh_user, remote_host: remote_host)
    end

    it "closes the SSH session and stops the background thread" do
      tunnel.start
      tunnel.stop
      expect(ssh_session).to(have_received(:close))
      expect(tunnel).not_to(be_running)
    end

    it "is safe to call when not running" do
      expect { tunnel.stop }.not_to(raise_error)
    end

    it "is safe to call more than once" do
      tunnel.start
      tunnel.stop
      expect { tunnel.stop }.not_to(raise_error)
    end
  end

  describe "#running?" do
    subject(:tunnel) do
      described_class.new(ssh_host: ssh_host, ssh_user: ssh_user, remote_host: remote_host)
    end

    it "returns false before start" do
      expect(tunnel).not_to(be_running)
    end

    it "returns true after start" do
      tunnel.start
      expect(tunnel).to(be_running)
      tunnel.stop
    end

    it "returns false after stop" do
      tunnel.start
      tunnel.stop
      expect(tunnel).not_to(be_running)
    end

    it "returns false if the SSH session is closed" do
      tunnel.start
      allow(ssh_session).to(receive(:closed?).and_return(true))
      expect(tunnel).not_to(be_running)
      tunnel.stop
    end
  end
end
