# frozen_string_literal: true

module LlmKit
  # What the app sets up once (LlmKit.configure):
  #   settings: providers and tasks, in the llm.yml format (see Config)
  #   on_call:  called after every provider call with its metadata, never its
  #             content: { task:, provider:, model:, status: :success | :error,
  #             latency_ms:, input_tokens:, output_tokens:, error:, context: }
  #             (context: whatever the app passed to Client.new, e.g. an account)
  class Configuration
    attr_accessor :on_call
    attr_reader :settings

    def initialize
      self.settings = {}
    end

    def settings=(settings)
      @settings = settings
      @config = nil
    end

    def config
      @config ||= Config.new(settings)
    end
  end
end
