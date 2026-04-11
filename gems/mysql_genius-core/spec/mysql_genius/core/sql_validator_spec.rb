# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::SqlValidator) do
  let(:blocked_tables) { ["sessions", "authentication_tokens"] }
  let(:all_tables) { ["users", "posts", "sessions", "authentication_tokens"] }
  let(:connection) do
    double("connection", tables: all_tables)
  end

  def validate(sql)
    described_class.validate(sql, blocked_tables: blocked_tables, connection: connection)
  end

  describe ".validate" do
    it "rejects blank queries" do
      expect(validate("")).to(eq("Please enter a query."))
      expect(validate(nil)).to(eq("Please enter a query."))
    end

    it "rejects non-SELECT queries" do
      expect(validate("DELETE FROM users")).to(eq("Only SELECT queries are allowed."))
    end

    it "allows SELECT queries" do
      expect(validate("SELECT * FROM users")).to(be_nil)
    end

    it "allows WITH (CTE) queries" do
      expect(validate("WITH cte AS (SELECT 1) SELECT * FROM cte")).to(be_nil)
    end

    it "rejects INSERT statements" do
      expect(validate("SELECT * FROM users; INSERT INTO users VALUES (1)")).to(include("INSERT"))
    end

    it "rejects DROP statements" do
      expect(validate("SELECT * FROM users; DROP TABLE users")).to(include("DROP"))
    end

    it "rejects queries against blocked tables" do
      result = validate("SELECT * FROM sessions")
      expect(result).to(include("sessions"))
    end

    it "rejects queries accessing information_schema" do
      result = validate("SELECT * FROM information_schema.tables")
      expect(result).to(include("system schemas"))
    end

    it "rejects queries accessing mysql system schema" do
      result = validate("SELECT * FROM mysql.user")
      expect(result).to(include("system schemas"))
    end

    it "strips SQL comments before validation" do
      expect(validate("SELECT * FROM users -- safe query")).to(be_nil)
    end
  end

  describe ".extract_table_references" do
    it "extracts tables from FROM clause" do
      tables = described_class.extract_table_references("SELECT * FROM users", connection)
      expect(tables).to(include("users"))
    end

    it "extracts tables from JOIN clause" do
      tables = described_class.extract_table_references("SELECT * FROM users JOIN posts ON users.id = posts.user_id", connection)
      expect(tables).to(include("users", "posts"))
    end

    it "extracts comma-separated tables" do
      tables = described_class.extract_table_references("SELECT * FROM users, posts", connection)
      expect(tables).to(include("users", "posts"))
    end

    it "handles backtick-quoted table names" do
      tables = described_class.extract_table_references("SELECT * FROM `users`", connection)
      expect(tables).to(include("users"))
    end
  end

  describe ".apply_row_limit" do
    it "appends LIMIT when none exists" do
      result = described_class.apply_row_limit("SELECT * FROM users", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 25"))
    end

    it "caps existing LIMIT to the configured max" do
      result = described_class.apply_row_limit("SELECT * FROM users LIMIT 5000", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 25"))
    end

    it "preserves lower LIMIT" do
      result = described_class.apply_row_limit("SELECT * FROM users LIMIT 10", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 10"))
    end

    it "handles LIMIT with offset" do
      result = described_class.apply_row_limit("SELECT * FROM users LIMIT 100, 5000", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 100, 25"))
    end

    it "strips trailing semicolons" do
      result = described_class.apply_row_limit("SELECT * FROM users;", 25)
      expect(result).to(eq("SELECT * FROM users LIMIT 25"))
    end
  end

  describe ".masked_column?" do
    let(:patterns) { ["password", "secret", "digest", "token"] }

    it "masks columns containing 'password'" do
      expect(described_class.masked_column?("encrypted_password", patterns)).to(be(true))
    end

    it "masks columns containing 'token'" do
      expect(described_class.masked_column?("reset_token", patterns)).to(be(true))
    end

    it "masks columns containing 'secret'" do
      expect(described_class.masked_column?("api_secret", patterns)).to(be(true))
    end

    it "does not mask normal columns" do
      expect(described_class.masked_column?("email", patterns)).to(be(false))
    end

    it "is case insensitive" do
      expect(described_class.masked_column?("Password_Hash", patterns)).to(be(true))
    end
  end
end
