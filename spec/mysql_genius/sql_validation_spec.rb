require "active_record"

RSpec.describe "SQL Validation" do
  let(:controller_class) { MysqlGenius::QueriesController }

  # Test the validation logic by instantiating a minimal controller context
  let(:controller) do
    ctrl = controller_class.allocate
    ctrl
  end

  before do
    MysqlGenius.configure do |c|
      c.blocked_tables = %w[sessions authentication_tokens]
    end

    # Stub connection.tables to return a known set
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter)
    allow(connection).to receive(:tables).and_return(%w[users posts sessions authentication_tokens])
    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
  end

  describe "#validate_sql" do
    it "rejects blank queries" do
      expect(controller.send(:validate_sql, "")).to eq("Please enter a query.")
    end

    it "rejects non-SELECT queries" do
      expect(controller.send(:validate_sql, "DELETE FROM users")).to eq("Only SELECT queries are allowed.")
    end

    it "allows SELECT queries" do
      expect(controller.send(:validate_sql, "SELECT * FROM users")).to be_nil
    end

    it "allows WITH (CTE) queries" do
      expect(controller.send(:validate_sql, "WITH cte AS (SELECT 1) SELECT * FROM cte")).to be_nil
    end

    it "rejects INSERT statements" do
      expect(controller.send(:validate_sql, "SELECT * FROM users; INSERT INTO users VALUES (1)")).to include("INSERT")
    end

    it "rejects DROP statements" do
      expect(controller.send(:validate_sql, "SELECT * FROM users; DROP TABLE users")).to include("DROP")
    end

    it "rejects queries against blocked tables" do
      result = controller.send(:validate_sql, "SELECT * FROM sessions")
      expect(result).to include("sessions")
    end

    it "rejects queries accessing information_schema" do
      result = controller.send(:validate_sql, "SELECT * FROM information_schema.tables")
      expect(result).to include("system schemas")
    end

    it "rejects queries accessing mysql system schema" do
      result = controller.send(:validate_sql, "SELECT * FROM mysql.user")
      expect(result).to include("system schemas")
    end

    it "strips SQL comments before validation" do
      expect(controller.send(:validate_sql, "SELECT * FROM users -- safe query")).to be_nil
    end
  end

  describe "#extract_table_references" do
    it "extracts tables from FROM clause" do
      tables = controller.send(:extract_table_references, "SELECT * FROM users")
      expect(tables).to include("users")
    end

    it "extracts tables from JOIN clause" do
      tables = controller.send(:extract_table_references, "SELECT * FROM users JOIN posts ON users.id = posts.user_id")
      expect(tables).to include("users", "posts")
    end

    it "extracts comma-separated tables" do
      tables = controller.send(:extract_table_references, "SELECT * FROM users, posts")
      expect(tables).to include("users", "posts")
    end

    it "handles backtick-quoted table names" do
      tables = controller.send(:extract_table_references, "SELECT * FROM `users`")
      expect(tables).to include("users")
    end
  end

  describe "#apply_row_limit" do
    it "appends LIMIT when none exists" do
      result = controller.send(:apply_row_limit, "SELECT * FROM users", 25)
      expect(result).to eq("SELECT * FROM users LIMIT 25")
    end

    it "caps existing LIMIT to the configured max" do
      result = controller.send(:apply_row_limit, "SELECT * FROM users LIMIT 5000", 25)
      expect(result).to eq("SELECT * FROM users LIMIT 25")
    end

    it "preserves lower LIMIT" do
      result = controller.send(:apply_row_limit, "SELECT * FROM users LIMIT 10", 25)
      expect(result).to eq("SELECT * FROM users LIMIT 10")
    end

    it "handles LIMIT with offset" do
      result = controller.send(:apply_row_limit, "SELECT * FROM users LIMIT 100, 5000", 25)
      expect(result).to eq("SELECT * FROM users LIMIT 100, 25")
    end

    it "strips trailing semicolons" do
      result = controller.send(:apply_row_limit, "SELECT * FROM users;", 25)
      expect(result).to eq("SELECT * FROM users LIMIT 25")
    end
  end

  describe "#masked_column?" do
    it "masks columns containing 'password'" do
      expect(controller.send(:masked_column?, "encrypted_password")).to be true
    end

    it "masks columns containing 'token'" do
      expect(controller.send(:masked_column?, "reset_token")).to be true
    end

    it "masks columns containing 'secret'" do
      expect(controller.send(:masked_column?, "api_secret")).to be true
    end

    it "does not mask normal columns" do
      expect(controller.send(:masked_column?, "email")).to be false
    end

    it "is case insensitive" do
      expect(controller.send(:masked_column?, "Password_Hash")).to be true
    end
  end
end
