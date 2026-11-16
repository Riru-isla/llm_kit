# frozen_string_literal: true

require "json"
require_relative "llm_kit/version"

# Talking to AI providers through one interface, whichever provider it is.
#
# Messages passed to providers use a provider-neutral shape:
#   { role: :user, text: "...", images: [{ media_type: "image/jpeg", data: <base64> }] (optional) }
#   { role: :assistant, text: "...", tool_calls: [{ id:, name:, input: }], native: <provider blocks> }
#   { role: :tool_results, results: [{ id:, content: "...", is_error: false }] }
# Each provider translates them to its own API format.
#
# Setup, once (e.g. in a Rails initializer):
#   LlmKit.configure do |config|
#     config.settings = Rails.application.config_for(:llm)
#     config.on_call = ->(call) { LlmCall.create!(**call) }   # optional
#   end
module LlmKit
  class Error < StandardError; end

  # The provider is down, slow, rate-limited or misconfigured: try the next one.
  class ProviderUnavailable < Error; end

  # The provider refused the request (HTTP 400/422: bad request, no credit...).
  # Also try the next one: each provider has its own format and account.
  class RequestRejected < Error; end

  # No provider is configured for the task (no keys / models set).
  class NotConfigured < Error; end

  # A provider was asked for by name but isn't one the task can use.
  class UnknownProvider < Error; end

  # Every configured provider failed.
  class AllProvidersFailed < Error; end

  # What a provider returned, in the same shape for every provider.
  #   stop: :end, :tool_use, :max_tokens or :refusal
  #   native: the provider's own assistant content, appended back unchanged
  #           during a tool loop (Anthropic needs its blocks intact)
  Response = Data.define(:text, :tool_calls, :stop, :input_tokens, :output_tokens, :model, :native)

  class << self
    def configure
      yield configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    # The configured providers: LlmKit.config.providers_for(:chat), .choices_for(:chat)...
    def config = configuration.config

    def reset_configuration!
      @configuration = nil
    end

    # nil, "" and empty collections count as blank (no ActiveSupport here).
    def blank?(value) = value.nil? || (value.respond_to?(:empty?) && value.empty?)
  end
end

require_relative "llm_kit/configuration"
require_relative "llm_kit/config"
require_relative "llm_kit/client"
require_relative "llm_kit/tool_loop"
require_relative "llm_kit/providers/openai_compatible"
require_relative "llm_kit/providers/anthropic"
