# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui'

RSpec.describe 'bounded release admission' do
  let(:owner) { Object.new }
  let(:registry) { Lich::WebUI::Registry.new }
  let(:dispatcher) { Lich::WebUI::Dispatcher.new }
  let(:viewers) { Lich::WebUI::ViewerStore.new(clock: -> { @now }) }
  let(:runtime) { Lich::WebUI::Runtime.new(registry: registry, dispatcher: dispatcher, viewers: viewers, logger: ->(_level, message) { @logs << message }) }

  before do
    @now, @tick = 100.0, 0
    @disabled = @hidden = @removed = false
    @caption, @width = 'Release target', 100
    @order = %w[release peer]
    @calls, @logs, @frames = [], [], []
    @callback = proc { |context| @calls << context.component.cid }
    @connection = connection('release-viewer', @frames)
  end

  after { dispatcher.shutdown }

  def connection(id, frames)
    result = Object.new
    result.define_singleton_method(:viewer_id) { id }
    result.define_singleton_method(:alive?) { true }
    result.define_singleton_method(:send_text) { |text| frames << JSON.parse(text); true }
    result
  end

  def publish
    state = self
    @page = registry.register(Lich::WebUI::Page.new(owner: owner, id: 'releases', title: 'Release admission') do
      stack(key: 'ancestor', disabled: state.instance_variable_get(:@disabled), hidden: state.instance_variable_get(:@hidden)) do
        state.instance_variable_get(:@order).each do |key|
          if key == 'release'
            next if state.instance_variable_get(:@removed)
            stack(key: key, pointer_events: true, width: state.instance_variable_get(:@width),
                  on: { pointer_release: state.instance_variable_get(:@callback) }) do
              text(key: 'caption', content: state.instance_variable_get(:@caption))
            end
          else
            text(key: key, content: 'Peer')
          end
        end
      end
      text(key: 'ticker', content: "Tick #{state.instance_variable_get(:@tick)}")
    end)
    @address = registry.address_for(@page)
    runtime.handle(@connection, type: 'attach', page: @address, version: Lich::WebUI::Contract::VERSION)
    frame = @frames.last
    @event = { type: 'event', page: @address, cid: frame['tree']['children'].first['children'].first['cid'],
               event: 'pointer_release', request: 1, generation: frame['generation'],
               payload: { x: 12, y: 25, button: 1, time: 42, state: 0, click_count: 1 } }
  end

  def paint
    @tick += 1
    runtime.refresh(@page)
  end

  def drain
    done = Queue.new
    runtime.dispatch(owner: owner) { done << true }
    expect(done.pop(timeout: 3)).to be(true)
  end

  it 'executes exactly once through unrelated paints and duplicate delivery' do
    publish
    12.times { paint }
    expect(runtime.handle(@connection, @event)).to eq(:queued)
    expect(runtime.handle(@connection, @event)).to eq(:queued)
    drain
    expect(@calls).to eq([@event[:cid]])
    expect(@logs.grep(/pointer_release phase=completed/).size).to eq(1)
    expect(@frames.none? { |frame| frame['type'] == 'refusal' }).to be(true)
  end

  %i[binding order disabled hidden width caption removal aba].each do |change|
    it "rejects an old release after #{change} changes" do
      publish
      case change
      when :binding then @callback = proc { @calls << 'replacement' }
      when :order then @order.reverse!
      when :disabled then @disabled = true
      when :hidden then @hidden = true
      when :width then @width = 200
      when :caption then @caption = 'Replacement target'
      when :removal then @removed = true
      when :aba
        @removed = true
        paint
        @removed = false
      end
      paint
      expect(runtime.handle(@connection, @event)).to eq(:refused)
      drain
      expect(@calls).to be_empty
      expect(@frames.reverse.find { |frame| frame['type'] == 'refusal' }['reason']).to eq('stale_generation')
    end
  end

  %i[binding detach expire].each do |change|
    it "retires an admitted queued release on #{change}" do
      publish
      gate, entered = Queue.new, Queue.new
      runtime.dispatch(owner: owner) { entered << true; gate.pop }
      expect(entered.pop(timeout: 3)).to be(true)
      expect(runtime.handle(@connection, @event)).to eq(:queued)
      case change
      when :binding then @callback = proc { @calls << 'replacement' }; paint
      when :detach then runtime.disconnect(@connection)
      when :expire then @now += Lich::WebUI::ViewerStore::RELEASE_ADMISSION_WINDOW + 1
      end
      gate << true
      drain
      expect(@calls).to be_empty
      expect(@logs.grep(/pointer_release phase=retired/).size).to eq(1)
    ensure
      gate << true if gate
    end
  end

  it 'expires old authority and admits a fresh retry overtaken by more paints' do
    publish
    @now += Lich::WebUI::ViewerStore::RELEASE_ADMISSION_WINDOW + 1
    paint
    expect(runtime.handle(@connection, @event)).to eq(:refused)
    retry_event = @event.merge(generation: @frames.last['generation'], request: 2)
    5.times { paint }
    expect(runtime.handle(@connection, retry_event)).to eq(:queued)
    drain
    expect(@calls).to eq([@event[:cid]])
  end

  it 'keeps an already queued release valid through unrelated paints' do
    publish
    gate, entered = Queue.new, Queue.new
    runtime.dispatch(owner: owner) { entered << true; gate.pop }
    expect(entered.pop(timeout: 3)).to be(true)
    expect(runtime.handle(@connection, @event)).to eq(:queued)
    5.times { paint }
    gate << true
    drain
    expect(@calls).to eq([@event[:cid]])
    expect(@logs.grep(/pointer_release phase=completed/).size).to eq(1)
  ensure
    gate << true if gate
  end

  it 'retains deduplication across surface replacement and window renewal' do
    publish
    expect(runtime.handle(@connection, @event)).to eq(:queued)
    drain
    @width = 200
    @now += Lich::WebUI::ViewerStore::RELEASE_ADMISSION_WINDOW + 1
    paint
    expect(runtime.handle(@connection, @event.merge(generation: @frames.last['generation']))).to eq(:queued)
    drain
    expect(@calls).to eq([@event[:cid]])
  end

  it 'refuses future and foreign-viewer generations' do
    publish
    expect(runtime.handle(@connection, @event.merge(generation: @event[:generation] + 100))).to eq(:refused)
    paint
    second = connection('other-viewer', [])
    runtime.handle(second, type: 'attach', page: @address, version: Lich::WebUI::Contract::VERSION)
    expect(runtime.handle(second, @event)).to eq(:refused)
    drain
    expect(@calls).to be_empty
  end

  it 'does not reinterpret supplied submission data as a release' do
    publish
    paint
    expect(runtime.handle(@connection, @event.merge(submission: ['unexpected']))).to eq(:refused)
    drain
    expect(@calls).to be_empty
    expect(@frames.reverse.find { |frame| frame['type'] == 'refusal' }['reason']).to eq('submission_scope')
  end

  it 'runs the captured callback outside the store monitor' do
    @callback = proc do |context|
      worker = Thread.new { viewers.fetch(connection_id: @connection.viewer_id, address: @address) }
      expect(worker.join(2)).to be(worker)
      @calls << context.render.generation
    end
    publish
    paint
    generation = @frames.last['generation']
    expect(runtime.handle(@connection, @event)).to eq(:queued)
    drain
    expect(@calls).to eq([generation])
  end

  it 'keeps configure and pointer-press events strict' do
    publish
    paint
    %w[configure pointer_press].each do |event|
      expect(runtime.handle(@connection, @event.merge(event: event))).to eq(:refused)
      expect(@frames.reverse.find { |frame| frame['type'] == 'refusal' }['reason']).to eq('stale_generation')
    end
  end
end
