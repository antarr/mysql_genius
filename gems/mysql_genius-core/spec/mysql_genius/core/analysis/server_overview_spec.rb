# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Analysis::ServerOverview) do
  subject(:analysis) { described_class.new(connection) }

  let(:connection) { MysqlGenius::Core::Connection::FakeAdapter.new }

  before do
    connection.stub_query(/SELECT VERSION/, columns: ["VERSION()"], rows: [["8.0.35"]])

    connection.stub_query(
      /SHOW GLOBAL STATUS/,
      columns: ["Variable_name", "Value"],
      rows: [
        ["Uptime", "90061"],
        ["Threads_connected", "15"],
        ["Threads_running", "2"],
        ["Threads_cached", "5"],
        ["Threads_created", "120"],
        ["Aborted_connects", "3"],
        ["Aborted_clients", "1"],
        ["Max_used_connections", "42"],
        ["Innodb_buffer_pool_read_requests", "1000000"],
        ["Innodb_buffer_pool_reads", "10000"],
        ["Innodb_buffer_pool_pages_dirty", "100"],
        ["Innodb_buffer_pool_pages_free", "500"],
        ["Innodb_buffer_pool_pages_total", "8000"],
        ["Innodb_row_lock_waits", "5"],
        ["Innodb_row_lock_time", "250.5"],
        ["Created_tmp_tables", "100"],
        ["Created_tmp_disk_tables", "10"],
        ["Slow_queries", "7"],
        ["Questions", "901000"],
        ["Select_full_join", "3"],
        ["Sort_merge_passes", "0"],
      ],
    )

    connection.stub_query(
      /SHOW GLOBAL VARIABLES/,
      columns: ["Variable_name", "Value"],
      rows: [
        ["max_connections", "150"],
        ["innodb_buffer_pool_size", "134217728"],
      ],
    )
  end

  describe "#call" do
    it "returns a server block with version and uptime string" do
      result = analysis.call

      expect(result[:server][:version]).to(eq("8.0.35"))
      expect(result[:server][:uptime_seconds]).to(eq(90_061))
      expect(result[:server][:uptime]).to(eq("1d 1h 1m"))
    end

    context "with connections block" do
      it "reports connection counts and thread stats" do
        result = analysis.call

        expect(result[:connections][:max]).to(eq(150))
        expect(result[:connections][:current]).to(eq(15))
        expect(result[:connections][:threads_running]).to(eq(2))
        expect(result[:connections][:threads_cached]).to(eq(5))
        expect(result[:connections][:threads_created]).to(eq(120))
      end

      it "computes connection usage percentage and aborted stats" do
        result = analysis.call

        expect(result[:connections][:usage_pct]).to(eq(10.0))
        expect(result[:connections][:aborted_connects]).to(eq(3))
        expect(result[:connections][:aborted_clients]).to(eq(1))
        expect(result[:connections][:max_used]).to(eq(42))
      end
    end

    context "with innodb block" do
      it "computes buffer pool size in MB and hit rate" do
        result = analysis.call

        expect(result[:innodb][:buffer_pool_mb]).to(eq(128.0))
        expect(result[:innodb][:buffer_pool_hit_rate]).to(eq(99.0))
      end

      it "reports buffer pool page counts and row lock stats" do
        result = analysis.call

        expect(result[:innodb][:buffer_pool_pages_dirty]).to(eq(100))
        expect(result[:innodb][:buffer_pool_pages_free]).to(eq(500))
        expect(result[:innodb][:buffer_pool_pages_total]).to(eq(8000))
        expect(result[:innodb][:row_lock_waits]).to(eq(5))
        expect(result[:innodb][:row_lock_time_ms]).to(eq(251))
      end
    end

    context "with queries block" do
      it "computes qps from questions and uptime" do
        result = analysis.call

        expect(result[:queries][:questions]).to(eq(901_000))
        expect(result[:queries][:qps]).to(eq(10.0))
        expect(result[:queries][:slow_queries]).to(eq(7))
      end

      it "computes tmp disk percentage and full join stats" do
        result = analysis.call

        expect(result[:queries][:tmp_tables]).to(eq(100))
        expect(result[:queries][:tmp_disk_tables]).to(eq(10))
        expect(result[:queries][:tmp_disk_pct]).to(eq(10.0))
        expect(result[:queries][:select_full_join]).to(eq(3))
        expect(result[:queries][:sort_merge_passes]).to(eq(0))
      end
    end

    context "when uptime is zero" do
      let(:connection) do
        conn = MysqlGenius::Core::Connection::FakeAdapter.new
        conn.stub_query(/SELECT VERSION/, columns: ["VERSION()"], rows: [["8.0.35"]])
        conn.stub_query(
          /SHOW GLOBAL STATUS/,
          columns: ["Variable_name", "Value"],
          rows: [
            ["Uptime", "0"],
            ["Questions", "0"],
            ["Threads_connected", "0"],
            ["Max_used_connections", "0"],
            ["Created_tmp_tables", "0"],
            ["Innodb_buffer_pool_read_requests", "0"],
            ["Innodb_buffer_pool_reads", "0"],
          ],
        )
        conn.stub_query(/SHOW GLOBAL VARIABLES/, columns: ["Variable_name", "Value"], rows: [["max_connections", "150"], ["innodb_buffer_pool_size", "0"]])
        conn
      end

      it "returns qps = 0 and buffer pool hit rate = 0" do
        result = analysis.call
        expect(result[:queries][:qps]).to(eq(0))
        expect(result[:innodb][:buffer_pool_hit_rate]).to(eq(0))
      end
    end
  end
end
