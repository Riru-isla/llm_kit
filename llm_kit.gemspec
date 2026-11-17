# frozen_string_literal: true

require_relative "lib/llm_kit/version"

Gem::Specification.new do |spec|
  spec.name = "llm_kit"
  spec.version = LlmKit::VERSION
  spec.authors = [ "Diego Isla" ]
  spec.summary = "One interface to local and cloud LLMs: fallback order, tool loop, call logging hook."
  spec.description = "Provider-neutral chat with OpenAI-compatible providers (Ollama, LM Studio, Gemini, OpenAI...) " \
                     "and, optionally, Claude through the anthropic gem."
  spec.required_ruby_version = ">= 3.4"
  spec.metadata["allowed_push_host"] = "none" # installed from GitHub; never pushed to rubygems.org
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = [ "lib" ]

  # No runtime dependencies. Claude providers need the app to add `gem "anthropic"`.
end
