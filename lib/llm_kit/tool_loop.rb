# frozen_string_literal: true

module LlmKit
  # Lets the model call tools a few times, then answer. The app runs the tools:
  #
  #   response = LlmKit::ToolLoop.new(system: prompt, tools: definitions).run(provider, messages) do |call|
  #     my_tools.call(call[:name], call[:input])   # => { content: "...", is_error: false }
  #   end
  #   response.text
  #
  # tools: [{ name:, description:, input_schema: }]. The block gets each tool
  # call ({ id:, name:, input: }) and returns { content:, is_error: }; any other
  # keys it returns stay in the app (only content and is_error reach the model).
  #
  # After max_rounds of tool calls the model is asked once more with tools
  # forbidden, so it has to answer. Returns the last Response. `messages` is
  # not changed.
  class ToolLoop
    MAX_ROUNDS = 5

    attr_reader :max_rounds

    def initialize(system:, tools:, max_rounds: MAX_ROUNDS)
      @system = system
      @tools = tools
      @max_rounds = max_rounds
    end

    def run(provider, messages)
      conversation = messages.dup
      rounds = 0
      loop do
        allow_tools = rounds < max_rounds
        response = provider.chat(system: @system, messages: conversation, tools: @tools, allow_tools: allow_tools)
        return response if response.tool_calls.empty? || !allow_tools

        conversation << { role: :assistant, text: response.text, tool_calls: response.tool_calls, native: response.native }
        conversation << { role: :tool_results, results: response.tool_calls.map { result_for(it, yield(it)) } }
        rounds += 1
      end
    end

    private

    def result_for(call, result)
      { id: call[:id], content: result[:content].to_s, is_error: result[:is_error] ? true : false }
    end
  end
end
