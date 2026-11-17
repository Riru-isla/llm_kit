# llm_kit

One interface to local and cloud LLMs, for Rails apps (or plain Ruby). Extracted
from Buckets' `Llm` layer, to share it with Reliquary and future projects.

- **Providers:** any OpenAI-compatible API over plain `Net::HTTP` (Ollama, LM Studio,
  Gemini, DeepSeek, Kimi, OpenAI) and, optionally, Claude through the `anthropic` gem.
- **Fallback order** per task; a provider that is down or rejects the request
  hands over to the next one. `prefer:` puts a user-picked provider first.
- **Tool loop** with a round limit; the app runs its own tools.
- **Logging hook** with each call's metadata (never its content).
- No runtime dependencies. Local models first: Claude is only needed if you configure it.

## Install

```ruby
# Gemfile
gem "llm_kit", github: "Riru-isla/llm_kit", tag: "v0.1.0"
gem "anthropic", "~> 1.80" # only if a provider uses `adapter: anthropic`
```

Not published on rubygems.org: apps install it from GitHub, pinned to a tag.

## Configure

`config/llm.yml` (keys come from the environment, never from this file):

```yaml
default: &default
  providers:
    local:
      adapter: openai_compatible
      base_url: <%= ENV.fetch("OLLAMA_URL", "http://localhost:11434") %>/v1
      model: <%= ENV["LOCAL_MODEL"] %>
      requires_key: false
      reasoning_effort: <%= ENV["LOCAL_REASONING_EFFORT"] %>  # optional, e.g. "none"
      timeout: <%= ENV.fetch("LOCAL_TIMEOUT", 300) %>          # seconds
    claude:
      adapter: anthropic
      api_key: <%= ENV["ANTHROPIC_API_KEY"] %>
      model: claude-opus-5-5
      effort: medium                                          # optional
  tasks:
    chat:
      providers: <%= ENV.fetch("LLM_PROVIDERS", "local,claude") %>  # order = fallbacks
```

A provider is used only when it has a model, plus an API key unless `requires_key: false`.

```ruby
# config/initializers/llm_kit.rb
LlmKit.configure do |config|
  config.settings = Rails.application.config_for(:llm)
  # Optional. call: { task:, provider:, model:, status:, latency_ms:,
  #                   input_tokens:, output_tokens:, error:, context: }
  config.on_call = ->(call) { LlmCall.create!(account: call[:context], **call.except(:context)) }
end
```

## Use

```ruby
reply = LlmKit::Client.new(task: :chat, prefer: params[:provider], context: Current.account).run do |provider|
  LlmKit::ToolLoop.new(system: prompt, tools: Tools::DEFINITIONS).run(provider, history) do |call|
    Tools.call(call[:name], call[:input])   # => { content: "...", is_error: false }
  end
end
reply.text # also reply.model, reply.stop (:end, :tool_use, :max_tokens, :refusal)
```

If a provider fails halfway, the whole block runs again on the next one, so keep
side effects out of it (or reset them at its start).

Model picker: `LlmKit.config.choices_for(:chat)` lists every configured provider
(`name`, `model`), the task's order first.

Messages are provider-neutral:

```ruby
{ role: :user, text: "...", images: [{ media_type: "image/jpeg", data: base64 }] } # images optional
{ role: :assistant, text: "...", tool_calls: [{ id:, name:, input: }], native: ... }
{ role: :tool_results, results: [{ id:, content: "...", is_error: false }] }
```

## Testing your app

```ruby
require "llm_kit/testing"
RSpec.configure { it.include LlmKit::Testing::Helpers }

provider = LlmKit::Testing::FakeProvider.new(
  llm_response(tool_calls: [tool_call("count_models")]),
  llm_response("You have 3."),
  name: "local"
)
provider.requests # what was sent
```

## Development

```sh
bundle install
bundle exec rspec   # WebMock, no real API calls; 100% line coverage enforced
```
