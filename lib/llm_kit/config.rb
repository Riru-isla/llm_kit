# frozen_string_literal: true

module LlmKit
  # Which providers exist and which ones each task tries, in order. Built from
  # a hash in the llm.yml format (string or symbol keys):
  #
  #   providers:
  #     local: { adapter: openai_compatible, base_url: ..., model: ..., requires_key: false }
  #     claude: { adapter: anthropic, api_key: ..., model: ..., effort: medium }
  #   tasks:
  #     chat: { providers: "local,claude" }   # or an array
  class Config
    ADAPTERS = {
      "anthropic" => -> { Providers::Anthropic },
      "openai_compatible" => -> { Providers::OpenaiCompatible }
    }.freeze

    attr_reader :settings

    def initialize(settings)
      @settings = deep_symbolize(settings.to_h)
    end

    # Configured providers for a task, in fallback order.
    def providers_for(task)
      names = settings.dig(:tasks, task.to_sym, :providers)
      names = names.to_s.split(",") unless names.is_a?(Array)
      names.map { it.to_s.strip }.reject(&:empty?).filter_map { provider(it) }
    end

    # Every configured provider that can be picked for a task: its fallback
    # order first, then the other configured providers.
    def choices_for(task)
      chain = providers_for(task)
      others = settings.fetch(:providers, {}).keys.map(&:to_s) - chain.map(&:name)
      chain + others.filter_map { provider(it) }
    end

    # The provider called `name`, or nil when it is missing or not configured.
    def provider(name)
      options = settings.dig(:providers, name.to_sym)
      return unless options && configured?(options)

      adapter = ADAPTERS.fetch(options[:adapter].to_s) do
        raise Error, "#{name}: unknown adapter #{options[:adapter].inspect}"
      end
      adapter.call.new(name: name.to_s, **options.except(:adapter, :requires_key))
    end

    def configured?(options)
      !LlmKit.blank?(options[:model]) && (options[:requires_key] == false || !LlmKit.blank?(options[:api_key]))
    end

    private

    def deep_symbolize(value)
      case value
      when Hash then value.to_h { |key, inner| [ key.to_sym, deep_symbolize(inner) ] }
      when Array then value.map { deep_symbolize(it) }
      else value
      end
    end
  end
end
