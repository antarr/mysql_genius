# frozen_string_literal: true

RSpec.describe(MysqlGenius::Core::Ai::Config) do
  it "exposes all keyword-init fields" do
    config = described_class.new(
      client: nil,
      endpoint: "https://api.example.com/v1/chat/completions",
      api_key: "sk-test",
      model: "gpt-4o",
      auth_style: :bearer,
      system_context: "Custom context",
    )

    expect(config.client).to(be_nil)
    expect(config.endpoint).to(eq("https://api.example.com/v1/chat/completions"))
    expect(config.api_key).to(eq("sk-test"))
    expect(config.model).to(eq("gpt-4o"))
    expect(config.auth_style).to(eq(:bearer))
    expect(config.system_context).to(eq("Custom context"))
  end

  describe "#enabled?" do
    it "is true when a custom client callable is set" do
      config = described_class.new(
        client: ->(**) { {} },
        endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(true))
    end

    it "is true when both endpoint and api_key are set" do
      config = described_class.new(
        client: nil, endpoint: "https://x", api_key: "k", model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(true))
    end

    it "is false when neither client nor endpoint+api_key are set" do
      config = described_class.new(
        client: nil, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(false))
    end

    it "is false when only endpoint is set without api_key" do
      config = described_class.new(
        client: nil, endpoint: "https://x", api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(false))
    end

    it "is false when endpoint is empty string" do
      config = described_class.new(
        client: nil, endpoint: "", api_key: "k", model: nil, auth_style: :bearer, system_context: nil,
      )
      expect(config.enabled?).to(be(false))
    end
  end
end
