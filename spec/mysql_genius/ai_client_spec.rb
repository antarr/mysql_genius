require "spec_helper"
require "mysql_genius/ai_client"

RSpec.describe MysqlGenius::AiClient do
  subject(:client) { described_class.new }

  before do
    MysqlGenius.configure do |c|
      c.ai_endpoint = "https://api.example.com/v1/chat/completions"
      c.ai_api_key = "sk-test-key"
      c.ai_model = "gpt-4o"
      c.ai_auth_style = :bearer
    end
  end

  describe "#chat" do
    context "with a custom ai_client callable" do
      before do
        MysqlGenius.configuration.ai_client = lambda { |messages:, temperature:|
          { "sql" => "SELECT 1", "explanation" => "test" }
        }
      end

      it "delegates to the custom client" do
        result = client.chat(messages: [{ role: "user", content: "test" }])
        expect(result).to eq({ "sql" => "SELECT 1", "explanation" => "test" })
      end

      it "passes temperature through" do
        called_temp = nil
        MysqlGenius.configuration.ai_client = lambda { |messages:, temperature:|
          called_temp = temperature
          {}
        }

        client.chat(messages: [], temperature: 0.5)
        expect(called_temp).to eq(0.5)
      end
    end

    context "without ai_endpoint or ai_api_key" do
      before do
        MysqlGenius.configuration.ai_endpoint = nil
        MysqlGenius.configuration.ai_api_key = nil
        MysqlGenius.configuration.ai_client = nil
      end

      it "raises an error" do
        expect {
          client.chat(messages: [])
        }.to raise_error(MysqlGenius::Error, /AI is not configured/)
      end
    end

    context "with an HTTP endpoint" do
      let(:response_body) do
        {
          "choices" => [
            { "message" => { "content" => '{"sql":"SELECT 1"}' } }
          ]
        }.to_json
      end

      let(:http_response) do
        instance_double(Net::HTTPOK, body: response_body, :is_a? => false).tap do |r|
          allow(r).to receive(:is_a?).with(Net::HTTPRedirection).and_return(false)
        end
      end

      before do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(http_response)
      end

      it "returns parsed JSON from the response content" do
        result = client.chat(messages: [{ role: "user", content: "hello" }])
        expect(result).to eq({ "sql" => "SELECT 1" })
      end

      it "includes the model in the request body" do
        allow(Net::HTTP).to receive(:new) do |host, port|
          http = instance_double(Net::HTTP)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request) do |req|
            body = JSON.parse(req.body)
            expect(body["model"]).to eq("gpt-4o")
            http_response
          end
          http
        end

        client.chat(messages: [])
      end

      it "uses Bearer auth when ai_auth_style is :bearer" do
        allow(Net::HTTP).to receive(:new) do |host, port|
          http = instance_double(Net::HTTP)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request) do |req|
            expect(req["Authorization"]).to eq("Bearer sk-test-key")
            http_response
          end
          http
        end

        client.chat(messages: [])
      end

      it "uses api-key header when ai_auth_style is :api_key" do
        MysqlGenius.configuration.ai_auth_style = :api_key

        allow(Net::HTTP).to receive(:new) do |host, port|
          http = instance_double(Net::HTTP)
          allow(http).to receive(:use_ssl=)
          allow(http).to receive(:open_timeout=)
          allow(http).to receive(:read_timeout=)
          allow(http).to receive(:request) do |req|
            expect(req["api-key"]).to eq("sk-test-key")
            http_response
          end
          http
        end

        client.chat(messages: [])
      end
    end

    context "when the API returns an error" do
      let(:error_body) { { "error" => { "message" => "Rate limit exceeded" } }.to_json }
      let(:http_response) do
        instance_double(Net::HTTPOK, body: error_body).tap do |r|
          allow(r).to receive(:is_a?).with(Net::HTTPRedirection).and_return(false)
        end
      end

      before do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(http_response)
      end

      it "raises an error with the API message" do
        expect {
          client.chat(messages: [])
        }.to raise_error(MysqlGenius::Error, /Rate limit exceeded/)
      end
    end

    context "when the response has no content" do
      let(:empty_body) { { "choices" => [{ "message" => { "content" => nil } }] }.to_json }
      let(:http_response) do
        instance_double(Net::HTTPOK, body: empty_body).tap do |r|
          allow(r).to receive(:is_a?).with(Net::HTTPRedirection).and_return(false)
        end
      end

      before do
        http = instance_double(Net::HTTP)
        allow(Net::HTTP).to receive(:new).and_return(http)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(http_response)
      end

      it "raises an error" do
        expect {
          client.chat(messages: [])
        }.to raise_error(MysqlGenius::Error, /No content/)
      end
    end
  end

  describe "#parse_json_content (via chat)" do
    let(:make_response) do
      ->(content) do
        body = { "choices" => [{ "message" => { "content" => content } }] }.to_json
        instance_double(Net::HTTPOK, body: body).tap do |r|
          allow(r).to receive(:is_a?).with(Net::HTTPRedirection).and_return(false)
        end
      end
    end

    before do
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      allow(http).to receive(:use_ssl=)
      allow(http).to receive(:open_timeout=)
      allow(http).to receive(:read_timeout=)
      allow(http).to receive(:request) { |_| @current_response }
    end

    it "parses plain JSON" do
      @current_response = make_response.call('{"sql":"SELECT 1"}')
      result = client.chat(messages: [])
      expect(result).to eq({ "sql" => "SELECT 1" })
    end

    it "strips markdown code fences" do
      @current_response = make_response.call("```json\n{\"sql\":\"SELECT 1\"}\n```")
      result = client.chat(messages: [])
      expect(result).to eq({ "sql" => "SELECT 1" })
    end

    it "strips code fences without language tag" do
      @current_response = make_response.call("```\n{\"sql\":\"SELECT 1\"}\n```")
      result = client.chat(messages: [])
      expect(result).to eq({ "sql" => "SELECT 1" })
    end

    it "returns raw content when JSON is unparseable" do
      @current_response = make_response.call("This is not JSON at all")
      result = client.chat(messages: [])
      expect(result).to eq({ "raw" => "This is not JSON at all" })
    end
  end

  describe "redirect handling" do
    it "follows redirects up to MAX_REDIRECTS" do
      redirect_response = instance_double(Net::HTTPRedirection, :[] => "https://api2.example.com/v1/chat").tap do |r|
        allow(r).to receive(:is_a?).with(Net::HTTPRedirection).and_return(true)
      end

      final_body = { "choices" => [{ "message" => { "content" => '{"ok":true}' } }] }.to_json
      final_response = instance_double(Net::HTTPOK, body: final_body).tap do |r|
        allow(r).to receive(:is_a?).with(Net::HTTPRedirection).and_return(false)
      end

      call_count = 0
      allow(Net::HTTP).to receive(:new) do
        http = instance_double(Net::HTTP)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request) do
          call_count += 1
          call_count == 1 ? redirect_response : final_response
        end
        http
      end

      result = client.chat(messages: [])
      expect(result).to eq({ "ok" => true })
      expect(call_count).to eq(2)
    end

    it "raises on too many redirects" do
      redirect_response = instance_double(Net::HTTPRedirection, :[] => "https://api.example.com/loop").tap do |r|
        allow(r).to receive(:is_a?).with(Net::HTTPRedirection).and_return(true)
      end

      allow(Net::HTTP).to receive(:new) do
        http = instance_double(Net::HTTP)
        allow(http).to receive(:use_ssl=)
        allow(http).to receive(:open_timeout=)
        allow(http).to receive(:read_timeout=)
        allow(http).to receive(:request).and_return(redirect_response)
        http
      end

      expect {
        client.chat(messages: [])
      }.to raise_error(MysqlGenius::Error, /Too many redirects/)
    end
  end
end
