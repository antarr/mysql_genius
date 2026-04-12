# frozen_string_literal: true

require "spec_helper"
require "trilogy"
require "mysql_genius/desktop/config"
require "mysql_genius/desktop/active_session"

RSpec.describe(MysqlGenius::Desktop::ActiveSession) do
  let(:config) do
    MysqlGenius::Desktop::Config.allocate.tap do |c|
      c.instance_variable_set(:@mysql,    MysqlGenius::Desktop::Config::MysqlConfig.from_hash({ "host" => "localhost", "username" => "root", "database" => "test" }))
      c.instance_variable_set(:@query,    MysqlGenius::Desktop::Config::QueryConfig.from_hash({ "timeout_seconds" => 5 }))
      c.instance_variable_set(:@security, MysqlGenius::Desktop::Config::SecurityConfig.from_hash({}))
    end
  end

  let(:adapter) { instance_double(MysqlGenius::Core::Connection::TrilogyAdapter) }

  before do
    allow(adapter).to(receive(:exec_query).with("SELECT VERSION()").and_return(instance_double(MysqlGenius::Core::Result)))
    allow(adapter).to(receive(:close))
    allow(described_class).to(receive(:open_adapter_for).with(config).and_return(adapter))
  end

  describe "#initialize" do
    it "opens the adapter and runs a health check query" do
      described_class.new(config)
      expect(adapter).to(have_received(:exec_query).with("SELECT VERSION()"))
    end

    it "raises ConnectError when open_adapter_for raises" do
      allow(described_class).to(receive(:open_adapter_for).and_raise(StandardError, "connect refused"))
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
      allow(described_class).to(receive(:open_adapter_for).with(config).and_return(adapter, new_adapter))

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
      allow(described_class).to(receive(:open_adapter_for).with(config).and_return(adapter, new_adapter))

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
      allow(described_class).to(receive(:open_adapter_for).with(config).and_return(adapter, new_adapter))

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
end
