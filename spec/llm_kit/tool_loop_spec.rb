# frozen_string_literal: true

RSpec.describe LlmKit::ToolLoop do
  let(:tools) { [ { name: "count_models", description: "Counts models", input_schema: { type: "object" } } ] }
  let(:loop_runner) { described_class.new(system: "Be brief.", tools: tools) }
  let(:history) { [ { role: :user, text: "How many?" } ] }

  it "answers directly, sending the system prompt, history and tools" do
    provider = LlmKit::Testing::FakeProvider.new(llm_response("Twelve"))

    response = loop_runner.run(provider, history) { raise "no tools expected" }

    expect(response.text).to eq("Twelve")
    expect(provider.requests.size).to eq(1)
    expect(provider.requests.first).to eq(system: "Be brief.", messages: history, tools: tools, allow_tools: true)
  end

  it "runs the tools the model asks for and sends back only content and is_error, with the native turn" do
    native = [ { type: :tool_use, id: "t1" } ]
    calls = [ tool_call("count_models", { "status" => "pending" }, id: "t1"), tool_call("nope", {}, id: "t2") ]
    provider = LlmKit::Testing::FakeProvider.new(llm_response("Checking", tool_calls: calls, native: native),
                                                 llm_response("You have 3 pending."))
    seen = []

    response = loop_runner.run(provider, history) do |call|
      seen << call
      if call[:name] == "count_models"
        { content: '{"count":3}', is_error: false, action: { type: "prefill" } }
      else
        { content: "Unknown tool", is_error: "yes" }
      end
    end

    expect(response.text).to eq("You have 3 pending.")
    expect(seen).to eq(calls)
    messages = provider.requests.last[:messages]
    expect(messages[1]).to eq(role: :assistant, text: "Checking", tool_calls: calls, native: native)
    expect(messages[2]).to eq(role: :tool_results, results: [
      { id: "t1", content: '{"count":3}', is_error: false },
      { id: "t2", content: "Unknown tool", is_error: true }
    ])
  end

  it "does not change the messages it was given" do
    provider = LlmKit::Testing::FakeProvider.new(llm_response(tool_calls: [ tool_call("count_models") ]), llm_response("3"))
    loop_runner.run(provider, history) { { content: "3" } }
    expect(history).to eq([ { role: :user, text: "How many?" } ])
  end

  it "stops offering tools after the maximum number of rounds" do
    looping = Array.new(described_class::MAX_ROUNDS) { llm_response(tool_calls: [ tool_call("count_models") ]) }
    provider = LlmKit::Testing::FakeProvider.new(*looping, llm_response("Final", tool_calls: [ tool_call("count_models") ]))

    response = loop_runner.run(provider, history) { { content: "1" } }

    expect(response.text).to eq("Final")
    expect(provider.requests.map { it[:allow_tools] }).to eq([ true ] * described_class::MAX_ROUNDS + [ false ])
  end

  it "takes its own round limit" do
    provider = LlmKit::Testing::FakeProvider.new(llm_response(tool_calls: [ tool_call("count_models") ]), llm_response("Done"))
    described_class.new(system: "s", tools: tools, max_rounds: 1).run(provider, history) { { content: "1" } }
    expect(provider.requests.map { it[:allow_tools] }).to eq([ true, false ])
  end
end
