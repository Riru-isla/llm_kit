# frozen_string_literal: true

RSpec.describe LlmKit::Config do
  subject(:config) { described_class.new(settings) }

  # The same shape as an llm.yml read by Rails' config_for, plus string keys
  # and an array order to show both are accepted.
  let(:settings) do
    {
      providers: {
        claude: { adapter: "anthropic", api_key: "test-claude-key", model: "claude-opus-5-5", effort: "medium" },
        claude_haiku: { adapter: "anthropic", api_key: "test-claude-key", model: "claude-haiku-5-5" },
        "kimi" => { "adapter" => "openai_compatible", "base_url" => "https://kimi.example.test/v1",
                    "api_key" => "test-kimi-key", "model" => "kimi-test" },
        local: { adapter: "openai_compatible", base_url: "http://local.example.test/v1", model: "local-test",
                 requires_key: false },
        unconfigured: { adapter: "openai_compatible", base_url: "https://nobody.example.test/v1", model: "some-model" }
      },
      tasks: {
        chat: { providers: "claude, kimi,unconfigured,local" },
        receipt: { providers: %w[local claude] }
      }
    }
  end

  it "lists a task's configured providers in order, skipping unconfigured ones" do
    providers = config.providers_for(:chat)

    expect(providers.map(&:name)).to eq(%w[claude kimi local])
    expect(providers.map(&:class)).to eq([ LlmKit::Providers::Anthropic, LlmKit::Providers::OpenaiCompatible,
                                           LlmKit::Providers::OpenaiCompatible ])
    expect(providers.first.model).to eq("claude-opus-5-5")
  end

  it "accepts the order as an array" do
    expect(config.providers_for("receipt").map(&:name)).to eq(%w[local claude])
  end

  it "offers every configured provider as a choice: the task's order first, then the rest" do
    expect(config.choices_for(:chat).map(&:name)).to eq(%w[claude kimi local claude_haiku])
    expect(config.choices_for(:unknown).map(&:name)).to eq(%w[claude claude_haiku kimi local])
  end

  it "returns nothing for unknown tasks and providers, and with no settings at all" do
    expect(config.providers_for(:unknown)).to eq([])
    expect(config.provider("nope")).to be_nil
    expect(described_class.new(nil).choices_for(:chat)).to eq([])
  end

  it "needs a model, and a key unless the provider says it doesn't" do
    expect(config.configured?({ model: "m", api_key: "k" })).to be(true)
    expect(config.configured?({ model: "m", requires_key: false })).to be(true)
    expect(config.configured?({ model: "m" })).to be(false)
    expect(config.configured?({ model: "", api_key: "k" })).to be(false)
  end

  it "names an unknown adapter" do
    broken = described_class.new(providers: { odd: { adapter: "telepathy", model: "m", requires_key: false } })
    expect { broken.provider(:odd) }.to raise_error(LlmKit::Error, 'odd: unknown adapter "telepathy"')
  end

  it "is what LlmKit.configure sets up, rebuilt when the settings change" do
    LlmKit.configure { it.settings = settings }
    expect(LlmKit.config.providers_for(:receipt).map(&:name)).to eq(%w[local claude])

    LlmKit.configure { it.settings = { tasks: { chat: { providers: "local" } } } }
    expect(LlmKit.config.providers_for(:receipt)).to eq([])
  end
end
