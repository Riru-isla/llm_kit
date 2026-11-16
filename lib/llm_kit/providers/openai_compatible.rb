# frozen_string_literal: true

require "net/http"
require "openssl"

module LlmKit
  module Providers
    # Any provider speaking the OpenAI chat-completions API: OpenAI, DeepSeek,
    # Kimi (Moonshot), Gemini, and local models through Ollama or LM Studio. Plain
    # HTTP, so adding one is just a base URL, a key and a model name.
    class OpenaiCompatible
      MAX_TOKENS = 8_000
      TIMEOUT = 120 # seconds; local models reading photos may need more (timeout:)
      NETWORK_ERRORS = [ SocketError, Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError ].freeze

      attr_reader :name, :model

      # reasoning_effort: for models that think before answering ("none" switches
      # it off: much faster for simple look-ups); left out when not set.
      def initialize(name:, base_url:, model:, api_key: nil, reasoning_effort: nil, timeout: nil, **)
        @name = name
        @base_url = base_url.to_s.chomp("/")
        @model = model
        @api_key = api_key
        @reasoning_effort = reasoning_effort unless LlmKit.blank?(reasoning_effort)
        @timeout = LlmKit.blank?(timeout) ? TIMEOUT : timeout.to_i
      end

      def chat(system:, messages:, tools: [], allow_tools: true)
        body = {
          model: @model, max_tokens: MAX_TOKENS,
          messages: [ { role: "system", content: system } ] + messages.flat_map { native_messages(it) }
        }
        body[:reasoning_effort] = @reasoning_effort if @reasoning_effort
        if tools.any?
          body[:tools] = tools.map do |tool|
            { type: "function", function: { name: tool[:name], description: tool[:description], parameters: tool[:input_schema] } }
          end
          body[:tool_choice] = allow_tools ? "auto" : "none"
        end
        parse(post("/chat/completions", body))
      end

      private

      def native_messages(message)
        case message[:role]
        when :user
          [ { role: "user", content: user_content(message) } ]
        when :assistant
          # Tool calls go back exactly as the provider sent them when we have them:
          # some add fields that must be returned (Gemini's thought signatures).
          calls = message[:native] || message[:tool_calls].to_a.map do |call|
            { id: call[:id], type: "function", function: { name: call[:name], arguments: call[:input].to_json } }
          end
          text = message[:text] unless LlmKit.blank?(message[:text])
          [ { role: "assistant", content: text, tool_calls: (calls unless calls.empty?) }.compact ]
        else # :tool_results
          message[:results].map { { role: "tool", tool_call_id: it[:id], content: it[:content] } }
        end
      end

      # Text, or text plus images as data URLs.
      def user_content(message)
        return message[:text] if LlmKit.blank?(message[:images])

        [ { type: "text", text: message[:text] },
          *message[:images].map { { type: "image_url", image_url: { url: "data:#{it[:media_type]};base64,#{it[:data]}" } } } ]
      end

      def post(path, body)
        uri = URI("#{@base_url}#{path}")
        request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
        request["Authorization"] = "Bearer #{@api_key}" unless LlmKit.blank?(@api_key)
        request.body = body.to_json

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: 10, read_timeout: @timeout) { it.request(request) }
        case response.code.to_i
        when 200..299 then JSON.parse(response.body)
        when 400, 422 then raise RequestRejected, "#{name}: HTTP #{response.code} #{response.body.to_s[0, 200]}"
        else raise ProviderUnavailable, "#{name}: HTTP #{response.code}"
        end
      rescue *NETWORK_ERRORS, JSON::ParserError => e
        raise ProviderUnavailable, "#{name}: #{e.class}: #{e.message}"
      end

      def parse(json)
        choice = json.fetch("choices").first
        message = choice.fetch("message")
        Response.new(
          text: message["content"].to_s.strip,
          tool_calls: message["tool_calls"].to_a.map do |call|
            { id: call["id"], name: call.dig("function", "name"), input: parse_arguments(call.dig("function", "arguments")) }
          end,
          stop: { "tool_calls" => :tool_use, "length" => :max_tokens, "content_filter" => :refusal }.fetch(choice["finish_reason"], :end),
          input_tokens: json.dig("usage", "prompt_tokens"),
          output_tokens: json.dig("usage", "completion_tokens"),
          model: json["model"] || @model,
          native: message["tool_calls"]
        )
      rescue KeyError, NoMethodError => e
        raise ProviderUnavailable, "#{name}: unexpected response (#{e.message})"
      end

      # Arguments arrive as a JSON string; invalid JSON is passed on as-is so
      # the tool validation reports it back to the model.
      def parse_arguments(arguments)
        JSON.parse(arguments.to_s)
      rescue JSON::ParserError
        arguments
      end
    end
  end
end
