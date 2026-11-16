# frozen_string_literal: true

RSpec.describe LlmKit do
  it "has a version" do
    expect(LlmKit::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "treats nil, empty strings and empty collections as blank" do
    expect([ nil, "", [], {} ].map { described_class.blank?(it) }).to all(be(true))
    expect([ "x", [ 1 ], 0, false ].map { described_class.blank?(it) }).to all(be(false))
  end
end
