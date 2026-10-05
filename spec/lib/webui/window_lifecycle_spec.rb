# frozen_string_literal: true

require_relative '../../spec_helper'
require 'timeout'
require 'webui'

RSpec.describe 'WebUI script window lifecycle' do
  let(:opened) { [] }
  let(:terminated) { [] }
  let(:service) do
    Lich::WebUI::Service.new(
      browser_open: lambda { |_url, **options| opened << options; options[:on_start].call(opened.length); true },
      browser_terminate: ->(signal, pid) { terminated << [signal, pid] }
    )
  end

  def page(owner = Object.new, &closed)
    result = service.registry.register(Lich::WebUI::Page.new(
      owner: owner, id: 'panel', title: 'Panel', on: { close: closed || proc {} }
    ) { text(key: 'label', content: 'Running') })
    result.bind_runtime(service.runtime)
    service.refresh(result)
    result
  end

  after { service.stop }

  it 'closes only the requested page window and leaves the server and other owner working' do
    first = page
    second = page
    service.start
    service.open(first, geometry: { width: 196, height: 254, position: [20, 30] })
    service.open(second)
    service.runtime.close_page(first)

    expect(opened.first[:geometry]).to eq(width: 196, height: 254, position: [20, 30])
    expect(terminated).to eq([['TERM', 1]])
    expect(service.registry.pages_for(second.owner)).to eq([second])
    expect(service.server).to be_running
  end

  it 'reports the OS window close once, even without a connected viewer' do
    closed = Queue.new
    target = page { |event| closed << event }
    service.start
    service.open(target)
    opened.first[:on_exit].call
    opened.first[:on_exit].call

    event = Timeout.timeout(2) { closed.pop }
    expect(event.event).to eq(:close)
    expect(event.payload).to eq(reason: :user)
    expect(closed).to be_empty
    service.runtime.close_page(target)
    expect(terminated).to be_empty
  end

  it 'closes an owners windows on termination without delivering another user close callback' do
    closed = []
    target = page { closed << true }
    service.start
    service.open(target)
    service.terminate_owner(target.owner)
    opened.first[:on_exit].call

    expect(terminated).to eq([['TERM', 1]])
    expect(closed).to be_empty
    expect(service.registry.size).to eq(0)
  end

  it 'delivers only one user close when pagehide precedes process exit' do
    closed = Queue.new
    target = page { |event| closed << event }
    service.start
    service.open(target)
    sent = []
    connection = Object.new
    connection.define_singleton_method(:viewer_id) { 'test-viewer' }
    connection.define_singleton_method(:send_text) { |payload| sent << JSON.parse(payload) }
    address = service.registry.address_for(target)
    service.runtime.handle(connection, type: 'attach', page: address, version: '2.7.0')
    generation = sent.last.fetch('generation')
    service.runtime.handle(connection, type: 'detach', page: address, generation: generation)
    opened.first[:on_exit].call
    Timeout.timeout(2) { closed.pop }
    service.runtime.instance_variable_get(:@dispatcher).shutdown_owner(target.owner)

    expect(closed).to be_empty
  end

  it 'closes a process that finishes opening after the page was removed' do
    target = page
    entered = Queue.new
    release = Queue.new
    allow(Lich::WebUI::BrowserWindow).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options.merge(opener: lambda { |_url, **callbacks|
        entered << true
        release.pop
        callbacks[:on_start].call(77)
        true
      }))
    end
    service.start
    opening = Thread.new { service.open(target) }
    Timeout.timeout(2) { entered.pop }
    service.runtime.close_page(target)
    release << true
    opening.value
    expect(terminated).to eq([['TERM', 77]])
  ensure
    release << true if release
    opening&.join(2)
  end

  it 'does not open another process for a page that already has a window' do
    target = page
    service.start
    2.times { service.open(target) }
    expect(opened.size).to eq(1)
  end

  it 'uses the published page size and position when the caller supplies no geometry override' do
    target = service.registry.register(Lich::WebUI::Page.new(
      owner: Object.new, id: 'sized', title: 'Sized', props: { size: [340, 144], position: [10, 28] }
    ) {})
    service.refresh(target)
    service.start
    service.open(target)
    expect(opened.first[:geometry]).to eq(width: 340, height: 144, position: [10, 28])
  end

  it 'advertises and delivers real root configure events before close, retaining the last measurement' do
    observed = Queue.new
    target = service.registry.register(Lich::WebUI::Page.new(
      owner: Object.new, id: 'geometry', title: 'Geometry',
      on: { configure: proc { |event| observed << event.payload }, close: proc {} }
    ) {})
    service.refresh(target)
    sent = []
    connection = Object.new
    connection.define_singleton_method(:viewer_id) { 'geometry-viewer' }
    connection.define_singleton_method(:send_text) { |payload| sent << JSON.parse(payload) }
    address = service.registry.address_for(target)
    service.runtime.handle(connection, type: 'attach', page: address, version: Lich::WebUI::Contract::VERSION)
    render = sent.last
    expect(render.fetch('bindings').fetch('page:geometry')).to include('configure')
    measurement = { width: 444, height: 333, position: [-800, 45] }
    service.runtime.handle(connection, type: 'event', page: address, cid: 'page:geometry',
                           generation: render.fetch('generation'), event: 'configure', payload: measurement)
    expect(Timeout.timeout(2) { observed.pop }).to eq(measurement)
    service.runtime.close_page(target)
    expect(target.window_geometry).to eq(measurement)
  end

  it 'reopens each of three owners on a new address while the others keep running' do
    active = Array.new(3) { page }
    service.start
    active.each { |target| service.open(target) }
    original_addresses = active.map { |target| service.registry.address_for(target) }

    3.times do |index|
      owner = active[index].owner
      service.terminate_owner(owner)
      expect(terminated).to eq((1..index + 1).map { |pid| ['TERM', pid] })
      active[index] = page(owner)
      service.open(active[index])
      expect(service.registry.address_for(active[index])).not_to eq(original_addresses[index])
      expect(active.map { |target| service.registry.fetch_address(service.registry.address_for(target)) }).to eq(active)
      expect(service.server).to be_running
    end
    expect(opened.length).to eq(6)
  end

  it 'saves final close geometry even when a refresh overtakes the viewer' do
    events = Queue.new
    target = service.registry.register(Lich::WebUI::Page.new(
      owner: Object.new, id: 'final', title: 'Final',
      on: { configure: proc { |event| events << event.event }, close: proc { |event| events << event.event } }
    ) {})
    service.refresh(target)
    sent = []
    connection = Object.new
    connection.define_singleton_method(:viewer_id) { 'final-viewer' }
    connection.define_singleton_method(:alive?) { true }
    connection.define_singleton_method(:send_text) { |payload| sent << JSON.parse(payload) }
    address = service.registry.address_for(target)
    service.runtime.handle(connection, type: 'attach', page: address, version: Lich::WebUI::Contract::VERSION)
    previous_generation = sent.last.fetch('generation')
    service.refresh(target)
    measurement = { width: 501, height: 302, position: [-700, 40] }
    service.runtime.handle(connection, type: 'detach', page: address, generation: previous_generation, geometry: measurement)
    expect(Timeout.timeout(2) { [events.pop, events.pop] }).to eq(%i[configure close])
    expect(target.window_geometry).to eq(measurement)
  end

  it 'restores a resized form ahead of its first-run defaults but respects an explicit script override' do
    store = instance_double(Lich::WebUI::WindowGeometryStore)
    service.instance_variable_set(:@geometry_store, store)
    saved = { width: 720, height: 480, position: [-500, 80] }
    allow(store).to receive(:read).and_return(saved)
    allow(store).to receive(:save)
    target = service.registry.register(Lich::WebUI::Page.new(
      owner: Object.new, id: 'defaults', title: 'Defaults', props: { size: [600, 400] }
    ) {})
    service.refresh(target)
    service.start
    service.open(target)
    expect(opened.first[:geometry]).to eq(saved)
    expect(target.render.tree.props).to include(size: [720, 480], position: [-500, 80])
    other = page
    explicit = { width: 300, height: 200, position: [10, 20] }
    service.open(other, geometry: explicit)
    expect(opened.last[:geometry]).to eq(explicit)
  end
end
