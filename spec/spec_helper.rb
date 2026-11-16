# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/spec/"
  enable_coverage :branch
  minimum_coverage line: 100
end

require "llm_kit"
require "llm_kit/testing"
require "webmock/rspec"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.include LlmKit::Testing::Helpers
  config.disable_monkey_patching!
  config.order = :random
  config.after { LlmKit.reset_configuration! }
end
