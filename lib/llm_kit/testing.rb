# frozen_string_literal: true

require "llm_kit"

module LlmKit
  # Test support for apps using LlmKit (and for its own specs). Not loaded by
  # `require "llm_kit"`; in an app's spec helper:
  #
  #   require "llm_kit/testing"
  #   RSpec.configure { it.include LlmKit::Testing::Helpers }
  module Testing
    # A scripted stand-in for an AI provider: returns (or raises) the given
    # responses in order and records every request it received.
    class FakeProvider
      attr_reader :name, :model, :requests

      def initialize(*script, name: "fake", model: "fake-model")
        @script = script
        @name = name
        @model = model
        @requests = []
      end

      def chat(**request)
        @requests << request
        step = @script.shift || raise("LlmKit::Testing::FakeProvider #{name}: no more scripted responses")
        raise step if step.is_a?(Exception)

        step
      end
    end

    module Helpers
      def llm_response(text = "", tool_calls: [], stop: nil, model: "fake-model", native: nil)
        LlmKit::Response.new(text: text, tool_calls: tool_calls, stop: stop || (tool_calls.any? ? :tool_use : :end),
                             input_tokens: 100, output_tokens: 20, model: model, native: native)
      end

      def tool_call(name, input = {}, id: "call_#{name}")
        { id: id, name: name, input: input }
      end
    end
  end
end
