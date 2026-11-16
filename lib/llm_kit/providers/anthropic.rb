# frozen_string_literal: true

module LlmKit
  module Providers
    # Claude through the official Anthropic Ruby SDK. The `anthropic` gem is
    # optional: it is loaded only when a Claude provider is actually built, so
    # an app with local models only never needs it.
    #
    # Thinking is left at the model's default (adaptive) and its depth set with
    # `effort` when given (left out, the model uses its own default). Refusal
    # fallbacks ("default") let Anthropic retry a declined request on another
    # model server-side; our own fallback chain handles outages.
    class Anthropic
      BETAS = [ "server-side-fallback-2026-07-01" ].freeze
      MAX_TOKENS = 16_000

      attr_reader :name, :model

      def self.load_sdk!
        require "anthropic"
      rescue LoadError
        raise NotConfigured, 'Claude providers need the anthropic gem: add `gem "anthropic"` to your Gemfile'
      end

      def initialize(name:, api_key:, model:, effort: nil, **)
        self.class.load_sdk!
        @name = name
        @model = model
        @effort = effort unless LlmKit.blank?(effort)
        @client = ::Anthropic::Client.new(api_key: api_key, max_retries: 1, timeout: 120)
      end

      # tools: [{ name:, description:, input_schema: }]
      # allow_tools: false keeps the tools defined (the history may use them) but forbids new calls.
      def chat(system:, messages:, tools: [], allow_tools: true)
        params = {
          model: @model, max_tokens: MAX_TOKENS, system_: system, messages: messages.map { native_message(it) },
          betas: BETAS, fallbacks: :default
        }
        params[:output_config] = { effort: @effort } if @effort
        if tools.any?
          params[:tools] = tools
          params[:tool_choice] = { type: allow_tools ? :auto : :none }
        end
        parse(@client.beta.messages.create(**params))
      rescue ::Anthropic::Errors::BadRequestError, ::Anthropic::Errors::UnprocessableEntityError => e
        raise RequestRejected, "#{name}: #{e.message}"
      rescue ::Anthropic::Errors::APIError => e
        raise ProviderUnavailable, "#{name}: #{e.message}"
      end

      private

      def native_message(message)
        case message[:role]
        when :user
          { role: "user", content: user_content(message) }
        when :assistant
          { role: "assistant", content: message[:native] || message[:text] }
        else # :tool_results
          { role: "user", content: message[:results].map do |result|
            { type: "tool_result", tool_use_id: result[:id], content: result[:content], is_error: result[:is_error] }
          end }
        end
      end

      # Text, or the images followed by the text.
      def user_content(message)
        return message[:text] if LlmKit.blank?(message[:images])

        [ *message[:images].map { { type: "image", source: { type: "base64", media_type: it[:media_type], data: it[:data] } } },
          { type: "text", text: message[:text] } ]
      end

      def parse(message)
        blocks = message.content
        Response.new(
          text: blocks.select { it.type == :text }.map(&:text).join("\n").strip,
          tool_calls: blocks.select { it.type == :tool_use }.map { { id: it.id, name: it.name, input: it.input } },
          stop: { tool_use: :tool_use, max_tokens: :max_tokens, refusal: :refusal }.fetch(message.stop_reason, :end),
          input_tokens: message.usage.input_tokens,
          output_tokens: message.usage.output_tokens,
          model: message.model.to_s,
          native: blocks.map(&:to_h)
        )
      end
    end
  end
end
