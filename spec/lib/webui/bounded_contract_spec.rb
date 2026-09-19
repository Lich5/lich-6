# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../../lib/webui/validator'

RSpec.describe 'bounded compatibility contract additions' do
  let(:validator) { Lich::WebUI::Validator.new }
  let(:context) { { owner: 'vars', page_id: 'setup', cid: 'name' } }

  it 'admits an ordered focus notification without a value or submission' do
    props = validator.validate_component!(:text_input, { value: '(new var name)' }, **context)
    expect(validator.validate_event!(:text_input, :focus, {}, props: props, **context)).to eq({})
    expect(Lich::WebUI::Contract.schema(:text_input)[:events][:focus][:lifecycle]).to be(true)
    expect do
      validator.validate_event!(:text_input, :focus, { value: 'not permitted' }, props: props, **context)
    end.to raise_error(Lich::WebUI::SchemaViolationError)
  end

  it 'bounds vertical scroll measurements and keeps requested position viewer-local' do
    props = validator.validate_component!(:scroll, { scroll_position: 120 }, **context)
    payload = { position: 120, upper: 800, page_size: 300 }
    expect(validator.validate_event!(:scroll, :scrolled, payload, props: props, **context)).to eq(payload)
    expect(Lich::WebUI::Contract.schema(:scroll)[:properties][:scroll_position][:scope]).to eq(:viewer)
    expect do
      validator.validate_event!(:scroll, :scrolled, payload.merge(upper: -1), props: props, **context)
    end.to raise_error(Lich::WebUI::SchemaViolationError)
    expect do
      validator.validate_event!(:scroll, :scrolled, payload.merge(upper: 20), props: props, **context)
    end.to raise_error(Lich::WebUI::SchemaViolationError)
  end

  it 'keeps the type count and sensitive input event vocabulary unchanged' do
    expect(Lich::WebUI::Contract::TYPES.length).to eq(29)
    expect(Lich::WebUI::Contract.schema(:password_input)[:events].keys).to eq([:submit])
  end
end
