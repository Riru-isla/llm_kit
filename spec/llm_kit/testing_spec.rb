# frozen_string_literal: true

RSpec.describe LlmKit::Testing::FakeProvider do
  it "says when it runs out of scripted responses" do
    expect { described_class.new(name: "local").chat(system: "s", messages: []) }
      .to raise_error(RuntimeError, /FakeProvider local: no more scripted responses/)
  end

  it "builds responses that stop for tools when they have tool calls" do
    expect(llm_response(tool_calls: [ tool_call("x") ]).stop).to eq(:tool_use)
    expect(llm_response("hi").stop).to eq(:end)
  end
end
