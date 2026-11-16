# frozen_string_literal: true

RSpec.describe LlmKit::Client do
  let(:calls) { [] }
  let(:config) { instance_double(LlmKit::Config) }
  let(:question) { { system: "s", messages: [ { role: :user, text: "Hi" } ] } }

  def client(**options)
    described_class.new(task: :chat, config: config, on_call: ->(call) { calls << call }, **options)
  end

  def use_providers(*providers)
    allow(config).to receive(:providers_for).with(:chat).and_return(providers)
  end

  it "answers with the first provider and reports the call, without content" do
    claude = LlmKit::Testing::FakeProvider.new(llm_response("Hello", model: "claude-opus-5-5"), name: "claude", model: "claude-opus-5-5")
    use_providers(claude)

    answer = client(context: :account_1).run { |provider| provider.chat(**question) }

    expect(answer.text).to eq("Hello")
    expect(calls.size).to eq(1)
    expect(calls.first).to include(task: "chat", provider: "claude", model: "claude-opus-5-5", status: :success,
                                  input_tokens: 100, output_tokens: 20, error: nil, context: :account_1)
    expect(calls.first[:latency_ms]).to be >= 0
    expect(calls.first.keys).to contain_exactly(:task, :provider, :model, :status, :latency_ms, :input_tokens,
                                               :output_tokens, :error, :context)
  end

  it "falls back to the next provider when one is unavailable, reporting both" do
    claude = LlmKit::Testing::FakeProvider.new(LlmKit::ProviderUnavailable.new("claude: HTTP 529"), name: "claude", model: "opus")
    kimi = LlmKit::Testing::FakeProvider.new(llm_response("Hola"), name: "kimi", model: "kimi-test")
    use_providers(claude, kimi)

    expect(client.run { |provider| provider.chat(**question) }.text).to eq("Hola")
    expect(calls.map { it.values_at(:provider, :model, :status, :error) })
      .to eq([ [ "claude", "opus", :error, "claude: HTTP 529" ], [ "kimi", "fake-model", :success, nil ] ])
  end

  it "keeps reported errors short" do
    use_providers(LlmKit::Testing::FakeProvider.new(LlmKit::ProviderUnavailable.new("x" * 300), name: "claude"),
                  LlmKit::Testing::FakeProvider.new(llm_response("ok"), name: "kimi"))
    client.run { |provider| provider.chat(**question) }
    expect(calls.first[:error].length).to eq(255)
  end

  it "restarts the whole block on the next provider when one fails halfway" do
    claude = LlmKit::Testing::FakeProvider.new(llm_response("step 1"), LlmKit::ProviderUnavailable.new("down"), name: "claude")
    kimi = LlmKit::Testing::FakeProvider.new(llm_response("step 1"), llm_response("step 2"), name: "kimi")
    use_providers(claude, kimi)

    result = client.run { |provider| [ provider.chat(**question), provider.chat(**question) ].map(&:text) }

    expect(result).to eq([ "step 1", "step 2" ])
    expect(kimi.requests.size).to eq(2)
  end

  it "falls back when a provider rejects the request (e.g. no credit left)" do
    claude = LlmKit::Testing::FakeProvider.new(LlmKit::RequestRejected.new("claude: credit balance is too low"), name: "claude")
    kimi = LlmKit::Testing::FakeProvider.new(llm_response("Hola"), name: "kimi")
    use_providers(claude, kimi)

    expect(client.run { |provider| provider.chat(**question) }.text).to eq("Hola")
    expect(calls.map { it.values_at(:provider, :status) }).to eq([ [ "claude", :error ], [ "kimi", :success ] ])
  end

  it "says when every provider failed" do
    use_providers(LlmKit::Testing::FakeProvider.new(LlmKit::ProviderUnavailable.new("a down"), name: "a"),
                  LlmKit::Testing::FakeProvider.new(LlmKit::ProviderUnavailable.new("b down"), name: "b"))
    expect { client.run { |provider| provider.chat(**question) } }
      .to raise_error(LlmKit::AllProvidersFailed, "a down; b down")
  end

  it "says when no provider is configured" do
    use_providers
    expect { client.run { |provider| provider.chat(**question) } }.to raise_error(LlmKit::NotConfigured, /chat/)
  end

  it "asks a preferred provider first, keeping the others as fallbacks" do
    claude = LlmKit::Testing::FakeProvider.new(llm_response("Hi", model: "claude-opus-5-5"), name: "claude")
    gemini = LlmKit::Testing::FakeProvider.new(LlmKit::ProviderUnavailable.new("gemini: HTTP 429"), name: "gemini")
    local = LlmKit::Testing::FakeProvider.new(name: "local")
    use_providers(claude, gemini, local)

    answer = client(prefer: "gemini").run { it.chat(**question) }

    expect(answer.model).to eq("claude-opus-5-5")
    expect(calls.map { it[:provider] }).to eq(%w[gemini claude])
    expect(local.requests).to be_empty
  end

  it "can be asked to use a configured provider outside the task's order first" do
    haiku = LlmKit::Testing::FakeProvider.new(llm_response("Hi", model: "claude-haiku-5-5"), name: "claude_haiku")
    claude = LlmKit::Testing::FakeProvider.new(name: "claude")
    use_providers(claude)
    allow(config).to receive(:provider).with("claude_haiku").and_return(haiku)

    answer = client(prefer: "claude_haiku").run { it.chat(**question) }

    expect(answer.model).to eq("claude-haiku-5-5")
    expect(claude.requests).to be_empty
  end

  it "refuses a preferred provider the task can't use" do
    use_providers(LlmKit::Testing::FakeProvider.new(name: "claude"))
    allow(config).to receive(:provider).with("gemini").and_return(nil)
    expect { client(prefer: "gemini").run { it.chat(**question) } }
      .to raise_error(LlmKit::UnknownProvider, "gemini is not available for chat")
  end

  it "exposes the provider's name and model to the block" do
    use_providers(LlmKit::Testing::FakeProvider.new(name: "claude", model: "claude-opus-5-5"))
    expect(client.run { |provider| [ provider.name, provider.model ] }).to eq([ "claude", "claude-opus-5-5" ])
  end

  it "uses the global configuration by default, and works without a logging hook" do
    LlmKit.configure do |c|
      c.settings = { providers: { local: { adapter: "openai_compatible", base_url: "http://local.example.test/v1",
                                           model: "local-test", requires_key: false } },
                     tasks: { chat: { providers: "local" } } }
    end
    stub_request(:post, "http://local.example.test/v1/chat/completions")
      .to_return(status: 200, body: { choices: [ { message: { content: "ok" }, finish_reason: "stop" } ] }.to_json)

    expect(described_class.new(task: :chat).run { it.chat(**question) }.text).to eq("ok")
  end
end
