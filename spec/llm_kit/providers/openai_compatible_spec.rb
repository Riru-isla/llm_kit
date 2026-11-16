# frozen_string_literal: true

RSpec.describe LlmKit::Providers::OpenaiCompatible do
  subject(:provider) do
    described_class.new(name: "kimi", base_url: "https://kimi.example.test/v1/", api_key: "secret", model: "kimi-test")
  end

  let(:endpoint) { "https://kimi.example.test/v1/chat/completions" }

  def completion(message, finish_reason: "stop")
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { model: "kimi-test-0925", choices: [ { message: message, finish_reason: finish_reason } ],
              usage: { prompt_tokens: 80, completion_tokens: 12 } }.to_json }
  end

  def sent_body
    body = nil
    expect(a_request(:post, endpoint).with { |request| body = JSON.parse(request.body) }).to have_been_made
    body
  end

  it "sends the system prompt as the first message with the key, and reads a text answer" do
    stub_request(:post, endpoint).with(headers: { "Authorization" => "Bearer secret" })
                                 .to_return(completion({ role: "assistant", content: " Hola " }))

    response = provider.chat(system: "Be brief.", messages: [ { role: :user, text: "¿Cuánto?" } ])

    expect(response).to have_attributes(text: "Hola", stop: :end, model: "kimi-test-0925", input_tokens: 80,
                                        output_tokens: 12, tool_calls: [], native: nil)
    expect(sent_body).to eq(
      "model" => "kimi-test", "max_tokens" => 8_000,
      "messages" => [ { "role" => "system", "content" => "Be brief." }, { "role" => "user", "content" => "¿Cuánto?" } ]
    )
  end

  it "offers tools as functions and parses tool calls, passing bad JSON through for validation" do
    stub_request(:post, endpoint).to_return(completion({
      role: "assistant", content: nil,
      tool_calls: [
        { id: "c1", type: "function", function: { name: "get_insights", arguments: '{"month_id": 11}' } },
        { id: "c2", type: "function", function: { name: "list_months", arguments: "{oops" } }
      ]
    }, finish_reason: "tool_calls"))
    tools = [ { name: "get_insights", description: "Report", input_schema: { type: "object" } } ]

    response = provider.chat(system: "s", messages: [ { role: :user, text: "x" } ], tools: tools)

    expect(response.stop).to eq(:tool_use)
    expect(response.text).to eq("")
    expect(response.tool_calls).to eq([
      { id: "c1", name: "get_insights", input: { "month_id" => 11 } },
      { id: "c2", name: "list_months", input: "{oops" }
    ])
    expect(response.native.map { it["id"] }).to eq(%w[c1 c2])
    expect(sent_body).to include(
      "tool_choice" => "auto",
      "tools" => [ { "type" => "function", "function" => { "name" => "get_insights", "description" => "Report",
                                                           "parameters" => { "type" => "object" } } } ]
    )
  end

  it "sends tool turns and results in the OpenAI format" do
    stub_request(:post, endpoint).to_return(completion({ role: "assistant", content: "Done" }))

    provider.chat(system: "s", tools: [ { name: "list_months", description: "d", input_schema: {} } ], allow_tools: false,
                  messages: [
                    { role: :user, text: "Q" },
                    { role: :assistant, text: "", tool_calls: [ { id: "c1", name: "list_months", input: {} } ] },
                    { role: :tool_results, results: [ { id: "c1", content: "[]", is_error: false } ] },
                    { role: :assistant, text: "Earlier answer" }
                  ])

    body = sent_body
    expect(body["messages"].drop(1)).to eq([
      { "role" => "user", "content" => "Q" },
      { "role" => "assistant", "tool_calls" => [ { "id" => "c1", "type" => "function",
                                                   "function" => { "name" => "list_months", "arguments" => "{}" } } ] },
      { "role" => "tool", "tool_call_id" => "c1", "content" => "[]" },
      { "role" => "assistant", "content" => "Earlier answer" }
    ])
    expect(body["tool_choice"]).to eq("none")
  end

  it "sends a tool turn back exactly as the provider sent it, keeping extra fields" do
    stub_request(:post, endpoint).to_return(completion({ role: "assistant", content: "Done" }))
    native = [ { "id" => "c1", "type" => "function", "function" => { "name" => "list_months", "arguments" => "{}" },
                 "extra_content" => { "google" => { "thought_signature" => "sig" } } } ]

    provider.chat(system: "s", messages: [
      { role: :user, text: "Q" },
      { role: :assistant, text: "", tool_calls: [ { id: "c1", name: "list_months", input: {} } ], native: native },
      { role: :tool_results, results: [ { id: "c1", content: "[]", is_error: false } ] }
    ])

    expect(sent_body["messages"][2]).to eq("role" => "assistant", "tool_calls" => native)
  end

  it "sends reasoning_effort only when set" do
    thinking = described_class.new(name: "local", base_url: "https://kimi.example.test/v1", model: "qwen",
                                   reasoning_effort: "none")
    stub_request(:post, endpoint).to_return(completion({ role: "assistant", content: "x" }))

    thinking.chat(system: "s", messages: [ { role: :user, text: "x" } ])
    expect(sent_body).to include("reasoning_effort" => "none")

    WebMock.reset_executed_requests!
    described_class.new(name: "local", base_url: "https://kimi.example.test/v1", model: "qwen", reasoning_effort: "")
                   .chat(system: "s", messages: [ { role: :user, text: "x" } ])
    expect(sent_body).not_to have_key("reasoning_effort")
  end

  it "sends images as data URLs next to the text" do
    stub_request(:post, endpoint).to_return(completion({ role: "assistant", content: "ok" }))

    provider.chat(system: "s", messages: [ { role: :user, text: "Read it", images: [ { media_type: "image/jpeg", data: "QUJD" } ] } ])

    expect(sent_body["messages"].last).to eq(
      "role" => "user",
      "content" => [ { "type" => "text", "text" => "Read it" },
                     { "type" => "image_url", "image_url" => { "url" => "data:image/jpeg;base64,QUJD" } } ]
    )
  end

  it "waits as long as configured for an answer" do
    expect(Net::HTTP).to receive(:start).with("kimi.example.test", 443, hash_including(read_timeout: 300)).and_call_original
    slow = described_class.new(name: "local", base_url: "https://kimi.example.test/v1", model: "qwen", timeout: "300")
    stub_request(:post, endpoint).to_return(completion({ role: "assistant", content: "x" }))
    slow.chat(system: "s", messages: [ { role: :user, text: "x" } ])

    expect(Net::HTTP).to receive(:start).with(anything, anything, hash_including(read_timeout: 120)).and_call_original
    provider.chat(system: "s", messages: [ { role: :user, text: "x" } ])
  end

  it "maps finish reasons" do
    { "length" => :max_tokens, "content_filter" => :refusal, nil => :end }.each do |reason, stop|
      stub_request(:post, endpoint).to_return(completion({ role: "assistant", content: "x" }, finish_reason: reason))
      expect(provider.chat(system: "s", messages: [ { role: :user, text: "x" } ]).stop).to eq(stop)
    end
  end

  it "works without a key (local models) and falls back to the configured model name" do
    local = described_class.new(name: "local", base_url: "http://local.example.test/v1", model: "llama")
    stub_request(:post, "http://local.example.test/v1/chat/completions")
      .to_return(status: 200, body: { choices: [ { message: { content: "ok" }, finish_reason: "stop" } ] }.to_json)

    expect(local.chat(system: "s", messages: [ { role: :user, text: "x" } ]).model).to eq("llama")
    expect(a_request(:post, "http://local.example.test/v1/chat/completions").with { !it.headers.key?("Authorization") })
      .to have_been_made
  end

  it "treats a rejected request as final" do
    stub_request(:post, endpoint).to_return(status: 400, body: "bad tool schema")
    expect { provider.chat(system: "s", messages: [ { role: :user, text: "x" } ]) }
      .to raise_error(LlmKit::RequestRejected, /kimi: HTTP 400 bad tool schema/)
  end

  it "treats outages, timeouts and garbage answers as unavailable" do
    [
      -> { stub_request(:post, endpoint).to_return(status: 503) },
      -> { stub_request(:post, endpoint).to_return(status: 401) },
      -> { stub_request(:post, endpoint).to_timeout },
      -> { stub_request(:post, endpoint).to_raise(Errno::ECONNREFUSED) },
      -> { stub_request(:post, endpoint).to_return(status: 200, body: "<html>") },
      -> { stub_request(:post, endpoint).to_return(status: 200, body: { choices: [] }.to_json) }
    ].each do |stub|
      stub.call
      expect { provider.chat(system: "s", messages: [ { role: :user, text: "x" } ]) }
        .to raise_error(LlmKit::ProviderUnavailable, /kimi/)
    end
  end
end
