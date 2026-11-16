# frozen_string_literal: true

module LlmKit
  # Runs a task on the first provider that works, falling back to the next one
  # when a provider is unavailable or rejects the request. Every call is reported
  # to the configured on_call hook (metadata only).
  #
  #   LlmKit::Client.new(task: :chat, context: account).run do |provider|
  #     provider.chat(system: "...", messages: [{ role: :user, text: "Hi" }])
  #   end
  #
  # The block may call the provider several times (a tool loop). If the
  # provider fails halfway, the whole block starts again on the next provider.
  #
  # prefer:  a configured provider to try first (in the task's order or not);
  #          the task's providers stay behind it as fallbacks.
  # context: passed through to on_call untouched (e.g. the account to log under).
  class Client
    def initialize(task:, prefer: nil, context: nil, config: LlmKit.config, on_call: LlmKit.configuration.on_call)
      @task = task
      @prefer = prefer
      @context = context
      @config = config
      @on_call = on_call
    end

    def run
      providers = ordered(@config.providers_for(@task))
      raise NotConfigured, "No AI provider is configured for #{@task}" if providers.empty?

      failures = []
      providers.each do |provider|
        return yield Logged.new(provider, task: @task, context: @context, on_call: @on_call)
      rescue ProviderUnavailable, RequestRejected => e
        failures << e.message
      end
      raise AllProvidersFailed, failures.join("; ")
    end

    private

    def ordered(providers)
      return providers unless @prefer

      chosen = providers.find { it.name == @prefer } || @config.provider(@prefer)
      raise UnknownProvider, "#{@prefer} is not available for #{@task}" unless chosen

      [ chosen, *providers.reject { it.name == @prefer } ]
    end

    # Wraps a provider to report each call's metadata (never its content).
    class Logged
      ERROR_LENGTH = 255

      def initialize(provider, task:, context:, on_call:)
        @provider = provider
        @task = task
        @context = context
        @on_call = on_call
      end

      def name = @provider.name
      def model = @provider.model

      def chat(**)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = @provider.chat(**)
        report(started, status: :success, model: response.model,
                        input_tokens: response.input_tokens, output_tokens: response.output_tokens)
        response
      rescue Error => e
        report(started, status: :error, model: @provider.model, error: e.message[0, ERROR_LENGTH])
        raise
      end

      private

      def report(started, **attributes)
        return unless @on_call

        latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        @on_call.call({ task: @task.to_s, provider: @provider.name, model: nil, status: nil, latency_ms: latency,
                        input_tokens: nil, output_tokens: nil, error: nil, context: @context, **attributes })
      end
    end
  end
end
