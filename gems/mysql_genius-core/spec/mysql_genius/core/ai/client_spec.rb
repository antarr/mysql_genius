# frozen_string_literal: true

require "net/http"

RSpec.describe(MysqlGenius::Core::Ai::Client) do
  subject(:client) { described_class.new(config) }

  let(:config) do
    MysqlGenius::Core::Ai::Config.new(
      client: nil,
      endpoint: "https://api.example.com/v1/chat/completions",
      api_key: "sk-test-key",
      model: "gpt-4o",
      auth_style: :bearer,
      system_context: nil,
    )
  end

  def stub_http(response: nil, &block)
    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to(receive(:new).and_return(http))
    allow(http).to(receive(:use_ssl=))
    allow(http).to(receive(:verify_mode=))
    allow(http).to(receive(:ca_file=))
    allow(http).to(receive(:open_timeout=))
    allow(http).to(receive(:read_timeout=))
    allow(http).to(receive_messages(use_ssl?: false))
    if block
      allow(http).to(receive(:request, &block))
    elsif response
      allow(http).to(receive(:request).and_return(response))
    end
    http
  end

  def stub_http_with_block(&block)
    allow(Net::HTTP).to(receive(:new)) do
      http = instance_double(Net::HTTP)
      allow(http).to(receive(:use_ssl=))
      allow(http).to(receive(:verify_mode=))
      allow(http).to(receive(:ca_file=))
      allow(http).to(receive(:open_timeout=))
      allow(http).to(receive(:read_timeout=))
      allow(http).to(receive_messages(use_ssl?: false))
      block.call(http)
      http
    end
  end

  def ok_response(content)
    body = { "choices" => [{ "message" => { "content" => content } }] }.to_json
    instance_double(Net::HTTPOK, body: body).tap do |r|
      allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(false))
    end
  end

  describe "#chat" do
    context "with a custom client callable" do
      let(:config) do
        MysqlGenius::Core::Ai::Config.new(
          client: lambda { |**_kwargs| { "sql" => "SELECT 1", "explanation" => "test" } },
          endpoint: nil,
          api_key: nil,
          model: nil,
          auth_style: :bearer,
          system_context: nil,
        )
      end

      it "delegates to the custom client" do
        result = client.chat(messages: [{ role: "user", content: "test" }])
        expect(result).to(eq({ "sql" => "SELECT 1", "explanation" => "test" }))
      end

      it "passes temperature through" do
        called_temp = nil
        callable = lambda { |temperature:, **|
          called_temp = temperature
          {}
        }
        custom_config = MysqlGenius::Core::Ai::Config.new(
          client: callable, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
        )

        described_class.new(custom_config).chat(messages: [], temperature: 0.5)
        expect(called_temp).to(eq(0.5))
      end
    end

    context "when not configured" do
      let(:config) do
        MysqlGenius::Core::Ai::Config.new(
          client: nil, endpoint: nil, api_key: nil, model: nil, auth_style: :bearer, system_context: nil,
        )
      end

      it "raises an error" do
        expect { client.chat(messages: []) }.to(
          raise_error(MysqlGenius::Core::Ai::Client::NotConfigured, /AI is not configured/),
        )
      end
    end

    context "with an HTTP endpoint" do
      let(:http_response) { ok_response('{"sql":"SELECT 1"}') }

      before { stub_http(response: http_response) }

      it "returns parsed JSON from the response content" do
        result = client.chat(messages: [{ role: "user", content: "hello" }])
        expect(result).to(eq({ "sql" => "SELECT 1" }))
      end

      it "includes the model in the request body" do
        stub_http_with_block do |http|
          allow(http).to(receive(:request)) do |req|
            body = JSON.parse(req.body)
            expect(body["model"]).to(eq("gpt-4o"))
            http_response
          end
        end

        client.chat(messages: [])
      end

      it "uses Bearer auth when auth_style is :bearer" do
        stub_http_with_block do |http|
          allow(http).to(receive(:request)) do |req|
            expect(req["Authorization"]).to(eq("Bearer sk-test-key"))
            http_response
          end
        end

        client.chat(messages: [])
      end

      it "uses api-key header when auth_style is :api_key" do
        api_key_config = MysqlGenius::Core::Ai::Config.new(
          client: nil,
          endpoint: "https://api.example.com/v1/chat/completions",
          api_key: "sk-test-key",
          model: "gpt-4o",
          auth_style: :api_key,
          system_context: nil,
        )

        stub_http_with_block do |http|
          allow(http).to(receive(:request)) do |req|
            expect(req["api-key"]).to(eq("sk-test-key"))
            http_response
          end
        end

        described_class.new(api_key_config).chat(messages: [])
      end
    end

    context "when the API returns an error" do
      before do
        body = { "error" => { "message" => "Rate limit exceeded" } }.to_json
        response = instance_double(Net::HTTPOK, body: body).tap do |r|
          allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(false))
        end
        stub_http(response: response)
      end

      it "raises an error with the API message" do
        expect { client.chat(messages: []) }.to(
          raise_error(MysqlGenius::Core::Ai::Client::ApiError, /Rate limit exceeded/),
        )
      end
    end

    context "when the response has no content" do
      before do
        body = { "choices" => [{ "message" => { "content" => nil } }] }.to_json
        response = instance_double(Net::HTTPOK, body: body).tap do |r|
          allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(false))
        end
        stub_http(response: response)
      end

      it "raises an error" do
        expect { client.chat(messages: []) }.to(
          raise_error(MysqlGenius::Core::Ai::Client::ApiError, /No content/),
        )
      end
    end
  end

  describe "JSON parsing" do
    let(:current_response) { { value: nil } }

    before do
      response_holder = current_response
      stub_http { |_| response_holder[:value] }
    end

    it "parses plain JSON" do
      current_response[:value] = ok_response('{"sql":"SELECT 1"}')
      expect(client.chat(messages: [])).to(eq({ "sql" => "SELECT 1" }))
    end

    it "strips markdown code fences" do
      current_response[:value] = ok_response("```json\n{\"sql\":\"SELECT 1\"}\n```")
      expect(client.chat(messages: [])).to(eq({ "sql" => "SELECT 1" }))
    end

    it "strips code fences without language tag" do
      current_response[:value] = ok_response("```\n{\"sql\":\"SELECT 1\"}\n```")
      expect(client.chat(messages: [])).to(eq({ "sql" => "SELECT 1" }))
    end

    it "returns raw content when JSON is unparseable" do
      current_response[:value] = ok_response("This is not JSON at all")
      expect(client.chat(messages: [])).to(eq({ "raw" => "This is not JSON at all" }))
    end
  end

  describe "redirect handling" do
    it "follows redirects up to MAX_REDIRECTS" do
      redirect_response = instance_double(Net::HTTPRedirection, :[] => "https://api2.example.com/v1/chat").tap do |r|
        allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(true))
      end
      final_response = ok_response('{"ok":true}')

      call_count = 0
      stub_http_with_block do |http|
        allow(http).to(receive(:request)) do
          call_count += 1
          call_count == 1 ? redirect_response : final_response
        end
      end

      expect(client.chat(messages: [])).to(eq({ "ok" => true }))
      expect(call_count).to(eq(2))
    end

    it "raises on too many redirects" do
      redirect_response = instance_double(Net::HTTPRedirection, :[] => "https://api.example.com/loop").tap do |r|
        allow(r).to(receive(:is_a?).with(Net::HTTPRedirection).and_return(true))
      end

      stub_http_with_block do |http|
        allow(http).to(receive(:request).and_return(redirect_response))
      end

      expect { client.chat(messages: []) }.to(
        raise_error(MysqlGenius::Core::Ai::Client::TooManyRedirects),
      )
    end
  end
end
