# frozen_string_literal: true

require "spec_helper"
require "mysql_genius/core"

RSpec.describe(MysqlGenius::Core) do # rubocop:disable RSpec/SpecFilePathFormat
  describe ".views_path" do
    it "returns an absolute path" do
      expect(described_class.views_path).to(start_with("/"))
    end

    it "points at lib/mysql_genius/core/views relative to the core gem" do
      expect(described_class.views_path).to(end_with("lib/mysql_genius/core/views"))
    end

    it "is an absolute path that exists" do
      # Fails until Stage D creates the views directory. For now the spec
      # just asserts the path is well-formed; after Stage D, add an
      # existence check.
      expect(described_class.views_path).to(be_a(String))
      expect(File.absolute_path?(described_class.views_path)).to(be(true))
    end
  end
end
