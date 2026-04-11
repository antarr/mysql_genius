# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::ServerInfo) do
  describe ".parse" do
    it "recognises MySQL from a version string" do
      info = described_class.parse("8.0.35")
      expect(info.vendor).to(eq(:mysql))
      expect(info.version).to(eq("8.0.35"))
    end

    it "recognises MariaDB from a version string containing 'MariaDB'" do
      info = described_class.parse("10.11.5-MariaDB-1:10.11.5+maria~ubu2204")
      expect(info.vendor).to(eq(:mariadb))
      expect(info.version).to(eq("10.11.5-MariaDB-1:10.11.5+maria~ubu2204"))
    end

    it "recognises MariaDB case-insensitively" do
      info = described_class.parse("10.4.30-mariadb-log")
      expect(info.vendor).to(eq(:mariadb))
    end
  end

  describe "#mariadb?" do
    it "is true for MariaDB" do
      expect(described_class.new(vendor: :mariadb, version: "10.11").mariadb?).to(be(true))
    end

    it "is false for MySQL" do
      expect(described_class.new(vendor: :mysql, version: "8.0").mariadb?).to(be(false))
    end
  end

  describe "#mysql?" do
    it "is true for MySQL" do
      expect(described_class.new(vendor: :mysql, version: "8.0").mysql?).to(be(true))
    end

    it "is false for MariaDB" do
      expect(described_class.new(vendor: :mariadb, version: "10.11").mysql?).to(be(false))
    end
  end
end
