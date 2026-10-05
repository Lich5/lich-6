# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui'
require 'timeout'

RSpec.describe Lich::WebUI::Adapter do
  let(:owner) { Object.new }
  let(:service) { Lich::WebUI::Service.new }
  let(:adapter) { described_class.new(owner: owner, service: service, viewer: 'viewer-one') }

  after { service.stop }

  it 'exposes exactly the ten locked operations' do
    expect(described_class.public_instance_methods(false)).to contain_exactly(
      :create, :get, :set, :attach, :detach, :bind, :unbind, :destroy, :modal, :schema
    )
  end

  it 'creates opaque handles and returns the frozen contract schema' do
    handle = adapter.create(:button, label: 'Go')

    expect(handle.inspect).to eq('#<Lich::WebUI::Adapter::Handle opaque>')
    expect(handle).not_to respond_to(:type, :props, :cid)
    expect(adapter.schema(:button)).to be_frozen
    expect { adapter.schema(:invented) }.to raise_error(Lich::WebUI::UnknownTypeError, /owner=/)
  end

  it 'carries validated child placement through the existing create and attach operations' do
    grid = adapter.create(:grid, cols: 3)
    child = adapter.create(:text, content: 'Spanning cell', placement: { span: 2 })
    expect(adapter.attach(grid, child)).to be_nil
    invalid = adapter.create(:text, content: 'Too wide', placement: { span: 4 })
    expect { adapter.attach(grid, invalid) }.to raise_error(Lich::WebUI::Error, /placement/)
    overflow = adapter.create(:text, content: 'Offset overflow', placement: { column: 3, span: 2 })
    expect { adapter.attach(grid, overflow) }.to raise_error(Lich::WebUI::Error, /placement/)
    # The refused attach is atomic; the child can still join a wider grid.
    expect(adapter.attach(adapter.create(:grid, cols: 4), invalid)).to be_nil
  end

  it 'gets and sets validated server-held state with explicit viewer scope' do
    input = adapter.create(:text_input, value: 'before')
    button = adapter.create(:button, label: 'Before')

    expect(adapter.get(input, :value)).to eq('before')
    expect(adapter.set(input, :value, 'after')).to be_nil
    expect(adapter.set(button, :label, 'After')).to be_nil
    expect(adapter.get(input, :value)).to eq('after')
    expect(adapter.get(button, :label)).to eq('After')

    unscoped = described_class.new(owner: owner, service: service)
    unscoped_input = unscoped.create(:text_input, value: '')
    expect { unscoped.get(unscoped_input, :value) }.to raise_error(Lich::WebUI::AmbiguousViewerError)
    expect { adapter.set(button, :invented, true) }.to raise_error(Lich::WebUI::UnknownPropertyError, /opaque-/)
  end

  it 'refuses shrinking a grid past an existing cell without corrupting its layout' do
    grid = adapter.create(:grid, cols: 4)
    child = adapter.create(:text, content: 'Fourth column', placement: { column: 4 })
    adapter.attach(grid, child)
    expect { adapter.set(grid, :cols, 3) }.to raise_error(Lich::WebUI::Error, /placement/)
    expect(adapter.get(grid, :cols)).to eq(4)
  end

  it 'retires a replaced binding so its old token cannot remove the new callback' do
    button = adapter.create(:button, label: 'Save')
    previous = adapter.bind(button, :activate, proc {})
    replacement = adapter.bind(button, :activate, proc {})
    expect { adapter.unbind(previous) }.to raise_error(Lich::WebUI::Error, /unknown binding/)
    expect(adapter.unbind(replacement)).to be_nil
  end

  it 'refuses every read and server-side write of sensitive values' do
    password = adapter.create(:password_input, label: 'Password')

    expect { adapter.get(password, :value) }.to raise_error(Lich::WebUI::SensitiveReadError)
    expect { adapter.set(password, :value, 'secret') }.to raise_error(Lich::WebUI::SchemaViolationError)
  end

  it 'replaces select options without retaining a removed default or accepting an invalid option list' do
    options = [{ value: 'none', label: '' }, { value: 'old', label: 'Old' }]
    select = adapter.create(:select, options: options, value: 'old')
    adapter.set(select, :options, options.take(1))
    expect(adapter.get(select, :value)).to eq('none')
    expect { adapter.set(select, :options, [{ label: 'Missing value' }]) }.to raise_error(Lich::WebUI::Error)
    expect(adapter.get(select, :options)).to eq(options.take(1))
  end

  it 'attaches, detaches, binds, unbinds, and destroys with attributed failures' do
    page = adapter.create(:page, title: 'Adapter page')
    group = adapter.create(:group, label: 'Actions')
    button = adapter.create(:button, label: 'Go')
    callback = proc {}

    expect(adapter.attach(page, group)).to be_nil
    expect(adapter.attach(group, button, 0)).to be_nil
    binding = adapter.bind(button, :activate, callback)
    expect(binding).to match(/\Abinding-[0-9a-f]{32}\z/)
    expect(adapter.unbind(binding)).to be_nil
    expect(adapter.detach(group, button)).to be_nil
    expect { adapter.detach(group, button) }.to raise_error(Lich::WebUI::Error, /owner=.*opaque-/)
    expect(adapter.destroy(button)).to be_nil
    expect { adapter.destroy(button) }.to raise_error(Lich::WebUI::Error, /already destroyed/)
  end

  it 'publishes a page using only the ten public operations' do
    rendered = Queue.new
    allow(service).to receive(:refresh).and_wrap_original do |original, page|
      result = original.call(page)
      rendered << page
      result
    end
    page = adapter.create(:page, title: 'Public port')
    button = adapter.create(:button, label: 'Visible')
    adapter.attach(page, button)

    published = Timeout.timeout(2) { rendered.pop }
    expect(service.registry.pages_for(owner)).to include(published)
    expect(published.last_render.tree.children.first.props[:label]).to eq('Visible')
  end

  it 'does not resurrect a page when its owner terminates before delivery' do
    adapter.create(:page, title: 'Cancelled')
    service.terminate_owner(owner)
    service.stop
    expect(service.registry.pages_for(owner)).to be_empty
  end

  it 'batches mutations into one generation at the runtime render boundary' do
    scheduled = []
    allow(service.runtime).to receive(:schedule_render) { |_key, **_options, &render| scheduled << render }
    page_handle = adapter.create(:page, title: 'Adapter page')
    button = adapter.create(:button, label: 'Before')
    adapter.attach(page_handle, button)

    scheduled.shift.call
    page = service.registry.pages_for(owner).fetch(0)
    first_generation = page.generation

    adapter.set(button, :label, 'Intermediate')
    adapter.set(button, :label, 'After')
    expect(page.generation).to eq(first_generation)

    scheduled.shift.call
    expect(page.generation).to eq(first_generation + 1)
    expect(page.last_render.tree.children.first.props[:label]).to eq('After')
  end

  it 'returns a cancellable future from modal' do
    future = adapter.modal(
      id: 'adapter-dialog', title: 'Question', body: 'Continue?',
      buttons: [{ id: 'yes', label: 'Yes' }], no_viewer: :default, default_button: 'yes'
    )

    expect(future).to be_a(Lich::WebUI::Future)
    expect(future.await(timeout: 1)&.button).to eq('yes')
  end

  it 'reads and writes the event viewer without exposing their value to another viewer' do
    unscoped = described_class.new(owner: owner, service: service)
    scheduled = []
    allow(service.runtime).to receive(:schedule_render) { |_key, **_options, &render| scheduled << render }
    root = unscoped.create(:page, title: 'Private drafts')
    input = unscoped.create(:text_input, value: 'initial')
    unscoped.attach(root, input)
    results = Queue.new
    unscoped.bind(input, :change, proc do |_event|
      value = unscoped.get(input, :value)
      unscoped.set(input, :value, value.upcase)
      results << value
    end)
    scheduled.shift.call
    page = service.registry.pages_for(owner).first
    address = service.registry.address_for(page)
    connections = %w[first second].map do |id|
      connection = double("connection #{id}", viewer_id: id, alive?: true)
      messages = []
      allow(connection).to receive(:send_text) { |json| messages << JSON.parse(json) }
      service.runtime.handle(connection, type: 'attach', page: address)
      [connection, messages]
    end
    first, messages = connections.first
    render = messages.last
    service.runtime.handle(first, type: 'event', page: address,
                                  cid: render.dig('tree', 'children', 0, 'cid'),
                                  generation: render['generation'], event: 'change', payload: { value: 'private' })

    expect(Timeout.timeout(2) { results.pop }).to eq('private')
    service.refresh(page)
    expect(connections.first.last.last.dig('tree', 'children', 0, 'props', 'value')).to eq('PRIVATE')
    expect(connections.last.last.last.dig('tree', 'children', 0, 'props', 'value')).to eq('initial')
  end
end
