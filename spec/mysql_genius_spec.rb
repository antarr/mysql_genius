# frozen_string_literal: true

require "mysql_genius/database_registry"

RSpec.describe(MysqlGenius) do
  it "has a version number" do
    expect(MysqlGenius::VERSION).not_to(be_nil)
  end

  describe ".databases" do
    before do
      allow(MysqlGenius::DatabaseRegistry).to(receive(:load_yaml_files).and_return(nil))
    end

    it "triggers DatabaseRegistry.build! on first call" do
      expect(MysqlGenius::DatabaseRegistry).to(receive(:build!).with(described_class.configuration).and_call_original)

      described_class.databases
    end

    it "does not trigger build! on subsequent calls" do
      described_class.databases

      expect(MysqlGenius::DatabaseRegistry).not_to(receive(:build!))

      described_class.databases
    end

    it "re-triggers build! after reset_configuration!" do
      described_class.databases

      described_class.reset_configuration!

      expect(MysqlGenius::DatabaseRegistry).to(receive(:build!).with(described_class.configuration).and_call_original)

      described_class.databases
    end

    it "returns the configuration databases hash" do
      result = described_class.databases

      expect(result).to(be_a(Hash))
      expect(result).to(equal(described_class.configuration.databases))
    end

    it "populates at least a primary database by default" do
      result = described_class.databases

      expect(result).to(have_key(:primary))
    end
  end
end
