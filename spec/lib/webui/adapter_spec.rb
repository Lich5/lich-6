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

  %i[get set].each do |operation|
    it "releases the adapter monitor before viewer #{operation} enters page rendering" do
      allow(service.runtime).to receive(:schedule_render)
      root = adapter.create(:page, title: 'Form')
      input = adapter.create(:text_input, value: 'before')
      adapter.attach(root, input)
      adapter.send(:flush!)
      page = service.registry.pages_for(owner).first
      allow(page).to receive(operation) do |*_args, **_options|
        worker = Thread.new { adapter.get(root, :title) }
        expect(worker.join(1)).to equal(worker)
        'after'
      ensure
        worker&.kill
      end
      operation == :get ? adapter.get(input, :value) : adapter.set(input, :value, 'after')
    end
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

  it 'accepts unattributed defaults only before publication, preserving later viewer isolation' do
    allow(service.runtime).to receive(:schedule_render)
    identity = Struct.new(:viewer_id).new(nil)
    port = described_class.new(owner: owner, service: service, viewer: identity)
    root = port.create(:page, title: 'Queued initialization')
    input = port.create(:text_input, value: 'before')
    port.attach(root, input)
    port.set(input, :value, 'initialized')
    expect { port.get(input, :value) }.to raise_error(Lich::WebUI::AmbiguousViewerError)
    port.send(:flush!)
    page = service.registry.pages_for(owner).first
    expect(page.last_render.tree.children.first.props[:value]).to eq('initialized')
    expect { port.set(input, :value, 'unattributed') }.to raise_error(Lich::WebUI::AmbiguousViewerError)
    viewers = %w[first second].map do |id|
      connection = double(id, viewer_id: id, alive?: true, send_text: true)
      service.runtime.handle(connection, type: 'attach', page: service.registry.address_for(page))
      service.runtime.instance_variable_get(:@viewers).fetch(connection_id: id, address: service.registry.address_for(page)).viewer_id
    end
    identity.viewer_id = viewers.first
    port.set(input, :value, 'first only')
    expect(port.get(input, :value)).to eq('first only')
    identity.viewer_id = viewers.last
    expect(port.get(input, :value)).to eq('initialized')
  end

  it 'replaces select options without retaining a removed default or accepting an invalid option list' do
    options = [{ value: 'none', label: '' }, { value: 'old', label: 'Old' }]
    select = adapter.create(:select, options: options, value: 'old')
    adapter.set(select, :options, options.take(1))
    expect(adapter.get(select, :value)).to eq('none')
    expect { adapter.set(select, :options, [{ label: 'Missing value' }]) }.to raise_error(Lich::WebUI::Error)
    expect(adapter.get(select, :options)).to eq(options.take(1))
  end

  context 'browse selection before publication' do
    let(:columns) { [{ key: 'name', label: 'Name' }] }
    let(:rows) { [{ key: 'first', cells: { name: 'First' } }, { key: 'second', cells: { name: 'Second' } }] }

    it 'selects the first remaining row and permits an empty table to be repopulated' do
      table = adapter.create(:table, columns: columns, rows: rows, selection: 'browse', selected: ['first'])
      # Read before publication so ViewerStore reconciliation cannot mask a stale default.
      adapter.set(table, :rows, rows.drop(1))
      expect(adapter.get(table, :selected)).to eq(['second'])
      adapter.set(table, :rows, [])
      expect(adapter.get(table, :selected)).to eq([])
      adapter.set(table, :rows, rows)
      expect(adapter.get(table, :selected)).to eq(['first'])
      expect { adapter.set(table, :rows, [{ cells: {} }]) }.to raise_error(Lich::WebUI::SchemaViolationError)
      expect(adapter.get(table, :selected)).to eq(['first'])
    end

    it 'supplies a selection when entering browse mode unless the table is empty' do
      [[], rows].each do |initial_rows|
        table = adapter.create(:table, columns: columns, rows: initial_rows, selection: 'single', selected: [])
        adapter.set(table, :selection, 'browse')
        expect(adapter.get(table, :selected)).to eq(initial_rows.empty? ? [] : ['first'])
      end
    end

    it 'preserves a surviving selection when entering browse mode or replacing rows' do
      table = adapter.create(:table, columns: columns, rows: rows, selection: 'single', selected: ['second'])
      adapter.set(table, :selection, 'browse')
      expect(adapter.get(table, :selected)).to eq(['second'])
      adapter.set(table, :rows, rows)
      expect(adapter.get(table, :selected)).to eq(['second'])
    end

    it 'keeps none and single modes from automatically selecting a replacement row' do
      %w[none single].each do |mode|
        table = adapter.create(:table, columns: columns, rows: rows, selection: 'browse', selected: ['first'])
        adapter.set(table, :selection, mode)
        expect(adapter.get(table, :selected)).to eq(mode == 'none' ? [] : ['first'])
        adapter.set(table, :rows, rows.drop(1))
        expect(adapter.get(table, :selected)).to eq([])
      end
    end
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

  it 'publishes equal page roots independently in the same render batch' do
    scheduled = []
    published = []
    allow(service.runtime).to receive(:schedule_render) { |_key, **_options, &render| scheduled << render }
    port = described_class.new(owner: owner, service: service, on_publish: ->(page) { published << page })
    first = port.create(:page, title: '')
    second = port.create(:page, title: '')

    scheduled.shift.call

    expect(published.length).to eq(2)
    expect(published.map(&:id).uniq.length).to eq(2)
    expect(service.registry.pages_for(owner)).to match_array(published)
    port.destroy(first)
    expect(service.registry.pages_for(owner)).to eq([published.last])
    port.set(second, :title, 'Still open')
    scheduled.shift.call
    expect(published.last.last_render.tree.props[:title]).to eq('Still open')
  end

  it 'resolves equal unrendered roots to their own handles' do
    allow(service.runtime).to receive(:schedule_render)
    first = adapter.create(:page, title: '')
    second = adapter.create(:page, title: '')
    nodes = adapter.instance_variable_get(:@nodes)

    expect(adapter.send(:handle_for, nodes.fetch(first))).to equal(first)
    expect(adapter.send(:handle_for, nodes.fetch(second))).to equal(second)
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

  ["\r\n", "\r"].each do |line_break|
    it "reconciles real textarea edits before Save without replaying #{line_break.inspect} normalization" do
      allow(service.runtime).to receive(:schedule_render)
      root = adapter.create(:page, title: 'Text form')
      input = adapter.create(:textarea, value: "First#{line_break}Second")
      save = adapter.create(:button, label: 'Save')
      adapter.attach(root, input)
      adapter.attach(root, save)
      events = Queue.new
      adapter.bind(input, :change, ->(event) { events << [:change, event.payload[:value]] })
      adapter.bind(save, :activate, ->(event) { events << [:save, event.submission[event.submission.cids.first]] })
      adapter.send(:flush!)
      page = service.registry.pages_for(owner).first
      address = service.registry.address_for(page)
      connection = double('connection', viewer_id: 'textarea-reader', alive?: true)
      messages = []
      allow(connection).to receive(:send_text) { |json| messages << JSON.parse(json) }
      service.runtime.handle(connection, type: 'attach', page: address)
      render = messages.last
      submit = lambda do |text|
        service.runtime.handle(connection, type: 'event', page: address, generation: render['generation'],
                                           cid: render.dig('tree', 'children', 1, 'cid'), event: 'activate', payload: {}, submission: [text])
      end

      # Browser newline conversion is not an edit; a missed real edit still
      # reaches the legacy change handler before the terminal Save callback.
      expect(submit.call("First\nSecond")).to eq(:queued)
      expect(events.pop(timeout: 2)).to eq([:save, "First\nSecond"])
      expect(events).to be_empty
      expect(submit.call("First\nChanged")).to eq(:queued)
      expect(events.pop(timeout: 2)).to eq([:change, "First\nChanged"])
      expect(events.pop(timeout: 2)).to eq([:save, "First\nChanged"])
      expect(events).to be_empty
    end
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

  %i[string_like resolver].each do |identity_kind|
    it "normalizes #{identity_kind} identities and seeds before a concurrent live write" do
      allow(service.runtime).to receive(:schedule_render)
      identity = double('string-like identity')
      selected = identity_kind == :resolver ? double('viewer resolver', viewer_id: identity) : identity
      scoped = described_class.new(owner: owner, service: service, viewer: selected)
      root = scoped.create(:page, title: 'Ordered seeds')
      scoped.send(:flush!)
      page = service.registry.pages_for(owner).first
      connection = double('connection', viewer_id: 'seed-reader', alive?: true, send_text: true)
      service.runtime.handle(connection, type: 'attach', page: service.registry.address_for(page))
      attachment = service.runtime.instance_variable_get(:@viewers).attachments_for(page).first
      allow(identity).to receive(:to_s).and_return(attachment.viewer_id)
      input = scoped.create(:textarea, value: 'Default')
      scoped.attach(root, input)
      scoped.set(input, :value, 'Queued')
      entered = Queue.new
      writer = nil
      allow(service.runtime).to receive(:seed_viewer_properties).and_wrap_original do |original, *args|
        # Force a live writer into the publication/seeding gap. It must wait
        # until the older seed is installed, then win with its newer value.
        writer = Thread.new do
          entered << true
          scoped.set(input, :value, 'Newer')
        end
        entered.pop
        writer.join(0.05)
        original.call(*args)
      end
      scoped.send(:flush!)
      expect(writer.join(2)).to equal(writer)
      expect(service.runtime).to have_received(:seed_viewer_properties).with(page, [[attachment.viewer_id, anything, :value, 'Queued']])
      expect(scoped.get(input, :value)).to eq('Newer')
    ensure
      writer&.kill if writer&.alive?
    end
  end
end
