# frozen_string_literal: true

RSpec.describe LlmKit::Providers::Anthropic do
  subject(:provider) { described_class.new(name: "claude", api_key: "test-key", model: "claude-opus-5-5", effort: "low") }

  let(:endpoint) { %r{\Ahttps://api\.anthropic\.com/v1/messages} }

  def reply(content, stop_reason: "end_turn")
    {
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { id: "msg_1", type: "message", role: "assistant", model: "claude-opus-5-5", content: content,
              stop_reason: stop_reason, stop_sequence: nil, usage: { input_tokens: 120, output_tokens: 30 } }.to_json
    }
  end

  def sent_body
    body = nil
    expect(a_request(:post, endpoint).with { |request| body = JSON.parse(request.body) }).to have_been_made.at_least_once
    body
  end

  it "sends the system prompt, conversation, effort and refusal fallbacks, and reads a text answer" do
    stub_request(:post, endpoint).to_return(reply([ { type: "text", text: "You spent 500 €." } ]))

    response = provider.chat(system: "You help with money.", messages: [ { role: :user, text: "How much?" } ])

    expect(response).to have_attributes(text: "You spent 500 €.", tool_calls: [], stop: :end, model: "claude-opus-5-5",
                                        input_tokens: 120, output_tokens: 30)
    body = sent_body
    expect(body).to include("model" => "claude-opus-5-5", "system" => "You help with money.", "max_tokens" => 16_000,
                            "fallbacks" => "default", "output_config" => { "effort" => "low" },
                            "messages" => [ { "role" => "user", "content" => "How much?" } ])
    expect(body).not_to include("tools", "thinking")
    expect(a_request(:post, endpoint).with(headers: { "anthropic-beta" => /server-side-fallback-2026-07-01/ }))
      .to have_been_made
  end

  it "leaves effort out when none is set" do
    stub_request(:post, endpoint).to_return(reply([ { type: "text", text: "Hi" } ]))
    haiku = described_class.new(name: "claude_haiku", api_key: "test-key", model: "claude-haiku-5-5")

    haiku.chat(system: "s", messages: [ { role: :user, text: "x" } ])

    body = sent_body
    expect(body).to include("model" => "claude-haiku-5-5")
    expect(body).not_to include("output_config")
  end

  it "offers tools and reads tool calls, keeping the native blocks to send back unchanged" do
    stub_request(:post, endpoint).to_return(reply([
      { type: "text", text: "Let me check." },
      { type: "tool_use", id: "toolu_1", name: "get_insights", input: { month_id: 11 } }
    ], stop_reason: "tool_use"))
    tools = [ { name: "get_insights", description: "Report", input_schema: { type: "object", properties: {} } } ]

    response = provider.chat(system: "s", messages: [ { role: :user, text: "Hi" } ], tools: tools)

    expect(response.stop).to eq(:tool_use)
    expect(response.tool_calls).to eq([ { id: "toolu_1", name: "get_insights", input: { month_id: 11 } } ])
    expect(response.native.map { it[:type] }).to eq(%i[text tool_use])
    expect(sent_body).to include("tool_choice" => { "type" => "auto" },
                                 "tools" => [ { "name" => "get_insights", "description" => "Report",
                                                "input_schema" => { "type" => "object", "properties" => {} } } ])
  end

  it "sends earlier assistant turns as text, a tool turn natively, and tool results as a user turn" do
    stub_request(:post, endpoint).to_return(reply([ { type: "text", text: "Done" } ]))
    native = [ { type: :tool_use, id: "toolu_1", name: "list_months", input: {} } ]

    provider.chat(system: "s", tools: [ { name: "list_months", description: "d", input_schema: { type: "object" } } ],
                  allow_tools: false,
                  messages: [
                    { role: :user, text: "Q1" }, { role: :assistant, text: "A1" }, { role: :user, text: "Q2" },
                    { role: :assistant, text: "", tool_calls: [], native: native },
                    { role: :tool_results, results: [ { id: "toolu_1", content: "[]", is_error: false } ] }
                  ])

    body = sent_body
    expect(body["messages"]).to eq([
      { "role" => "user", "content" => "Q1" },
      { "role" => "assistant", "content" => "A1" },
      { "role" => "user", "content" => "Q2" },
      { "role" => "assistant", "content" => [ { "type" => "tool_use", "id" => "toolu_1", "name" => "list_months", "input" => {} } ] },
      { "role" => "user", "content" => [ { "type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "[]", "is_error" => false } ] }
    ])
    expect(body["tool_choice"]).to eq("type" => "none")
  end

  it "sends images before the text" do
    stub_request(:post, endpoint).to_return(reply([ { type: "text", text: "ok" } ]))

    provider.chat(system: "s", messages: [ { role: :user, text: "Read it", images: [ { media_type: "image/jpeg", data: "QUJD" } ] } ])

    expect(sent_body["messages"].first["content"]).to eq([
      { "type" => "image", "source" => { "type" => "base64", "media_type" => "image/jpeg", "data" => "QUJD" } },
      { "type" => "text", "text" => "Read it" }
    ])
  end

  it "reports refusals and cut-off answers" do
    stub_request(:post, endpoint).to_return(reply([], stop_reason: "refusal"))
    expect(provider.chat(system: "s", messages: [ { role: :user, text: "x" } ]).stop).to eq(:refusal)

    stub_request(:post, endpoint).to_return(reply([ { type: "text", text: "Half" } ], stop_reason: "max_tokens"))
    expect(provider.chat(system: "s", messages: [ { role: :user, text: "x" } ]).stop).to eq(:max_tokens)
  end

  it "treats a rejected request as final" do
    stub_request(:post, endpoint).to_return(status: 400, body: { type: "error", error: { type: "invalid_request_error", message: "bad" } }.to_json,
                                            headers: { "Content-Type" => "application/json" })
    expect { provider.chat(system: "s", messages: [ { role: :user, text: "x" } ]) }
      .to raise_error(LlmKit::RequestRejected, /claude/)
  end

  it "treats outages, rate limits and bad keys as the provider being unavailable" do
    [ 401, 429, 529 ].each do |status|
      stub_request(:post, endpoint).to_return(status: status, body: { type: "error", error: { type: "x", message: "no" } }.to_json,
                                              headers: { "Content-Type" => "application/json", "retry-after" => "0" })
      expect { provider.chat(system: "s", messages: [ { role: :user, text: "x" } ]) }
        .to raise_error(LlmKit::ProviderUnavailable, /claude/)
    end
  end

  it "asks for the anthropic gem when it isn't installed" do
    allow(described_class).to receive(:require).with("anthropic").and_raise(LoadError)
    expect { described_class.new(name: "claude", api_key: "k", model: "m") }
      .to raise_error(LlmKit::NotConfigured, /gem "anthropic"/)
  end
end
