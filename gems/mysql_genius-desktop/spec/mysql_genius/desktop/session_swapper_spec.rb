# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "mysql_genius/desktop"

RSpec.describe(MysqlGenius::Desktop::SessionSwapper) do
  subject(:swapper) { described_class.new(app_class, config, database) }

  let(:database) { MysqlGenius::Desktop::Database.new(File.join(Dir.mktmpdir, "test.db")) }

  let(:config) do
    MysqlGenius::Desktop::Config.allocate.tap do |c|
      c.instance_variable_set(:@profiles, [])
      c.instance_variable_set(:@default_profile, "prod")
      c.instance_variable_set(:@query, MysqlGenius::Desktop::Config::QueryConfig.from_hash({}))
      c.instance_variable_set(:@security, MysqlGenius::Desktop::Config::SecurityConfig.from_hash({}))
      c.instance_variable_set(:@ai, MysqlGenius::Desktop::Config::AiConfig.from_hash({}))
      c.instance_variable_set(:@server, MysqlGenius::Desktop::Config::ServerConfig.from_hash({}))
      c.instance_variable_set(:@source_path, "(spec)")
    end
  end

  let(:old_session) { instance_double(MysqlGenius::Desktop::ActiveSession, close: nil) }
  let(:new_session) { instance_double(MysqlGenius::Desktop::ActiveSession, tunnel_port: nil) }

  let(:app_class) do
    Class.new do
      class << self
        attr_accessor :active_session_value,
          :current_profile_name_value,
          :stats_history_value,
          :stats_collector_value

        def settings
          self
        end

        def active_session
          active_session_value
        end

        def stats_history
          stats_history_value
        end

        def stats_collector
          stats_collector_value
        end

        def set(key, value)
          case key
          when :active_session       then self.active_session_value = value
          when :current_profile_name then self.current_profile_name_value = value
          when :stats_history        then self.stats_history_value        = value
          when :stats_collector      then self.stats_collector_value      = value
          end
        end
      end
    end
  end

  before do
    database.add_profile("name" => "prod", "host" => "db.prod.com", "username" => "u", "database_name" => "d")
    database.add_profile("name" => "staging", "host" => "db.staging.com", "username" => "u", "database_name" => "d")

    app_class.set(:active_session, old_session)
    app_class.set(:current_profile_name, "prod")
    app_class.set(:stats_history, nil)
    app_class.set(:stats_collector, nil)
    allow(MysqlGenius::Desktop::ActiveSession).to(receive(:new).and_return(new_session))
    allow(MysqlGenius::Core::Analysis::StatsCollector).to(receive(:new).and_return(
      instance_double(MysqlGenius::Core::Analysis::StatsCollector, start: nil),
    ))
  end

  describe "#switch_to" do
    it "opens a new session, swaps the app setting, and closes the old one" do
      swapper.switch_to("staging")

      expect(app_class.active_session_value).to(equal(new_session))
      expect(app_class.current_profile_name_value).to(eq("staging"))
      expect(old_session).to(have_received(:close))
    end

    it "sets a SqliteStatsHistory as the new stats_history" do
      swapper.switch_to("staging")

      expect(app_class.stats_history_value).to(be_a(MysqlGenius::Desktop::SqliteStatsHistory))
    end

    it "raises ConnectError when the profile name is not found" do
      expect { swapper.switch_to("nonexistent") }
        .to(raise_error(MysqlGenius::Desktop::ActiveSession::ConnectError, /Profile 'nonexistent' not found/))
    end

    it "does not close the old session if the new one fails to connect" do
      allow(MysqlGenius::Desktop::ActiveSession).to(receive(:new).and_raise(
        MysqlGenius::Desktop::ActiveSession::ConnectError, "connection refused"
      ))

      expect { swapper.switch_to("staging") }
        .to(raise_error(MysqlGenius::Desktop::ActiveSession::ConnectError))
      expect(app_class.active_session_value).to(equal(old_session))
      expect(old_session).not_to(have_received(:close))
    end
  end
end
