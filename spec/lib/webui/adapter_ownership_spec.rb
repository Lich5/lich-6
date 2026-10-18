# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui'
require 'weakref'

RSpec.describe 'adapter handle ownership' do
  let(:owner) { Object.new }
  let(:service) { Lich::WebUI::Service.new }
  let(:viewer) { Struct.new(:viewer_id).new('one') }
  let(:adapter) { Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer) }

  before { allow(service.runtime).to receive(:schedule_render) }
  after { service.stop }

  def collect
    3.times { GC.start(full_mark: true, immediate_sweep: true) }
  end

  def orphan(parent, publish: false)
    row = adapter.create(:stack, {})
    input = adapter.create(:text_input, value: 'Default')
    button = adapter.create(:button, label: 'Action')
    adapter.set(input, :value, 'Detached pending')
    adapter.bind(button, :activate, proc { adapter.set(button, :label, 'Clicked') })
    adapter.attach(row, input)
    adapter.attach(row, button)
    adapter.attach(parent, row)
    adapter.send(:flush!) if publish
    adapter.detach(parent, row)
    adapter.send(:flush!) if publish
    WeakRef.new(row)
  end

  def attached(parent)
    button = adapter.create(:button, label: 'Mounted')
    adapter.attach(parent, button)
    WeakRef.new(button)
  end

  def tombstone
    handle = adapter.create(:text, content: 'Retired')
    adapter.destroy(handle)
    WeakRef.new(handle)
  end

  it 'keeps detached native handles, callbacks and independent pending viewer values reusable across GC' do
    first, second = adapter.create(:stack, {}), adapter.create(:stack, {})
    row, input, button = adapter.create(:stack, {}), adapter.create(:text_input, value: ''), adapter.create(:button, label: 'Action')
    adapter.attach(row, input); adapter.attach(row, button); adapter.attach(first, row)
    token = adapter.bind(button, :activate, proc { adapter.set(button, :label, 'Clicked') })
    adapter.set(input, :value, 'One')
    viewer.viewer_id = 'two'
    adapter.set(input, :value, 'Two')
    adapter.detach(first, row)
    collect
    adapter.attach(second, row)
    expect(adapter.get(input, :value)).to eq('Two')
    viewer.viewer_id = 'one'
    expect(adapter.get(input, :value)).to eq('One')
    record = adapter.send(:binding_record, token)
    record.last.call(Lich::WebUI::Runtime::EventContext.new(nil, nil, nil, :activate, {}, nil))
    expect(adapter.get(button, :label)).to eq('Clicked')
    expect(adapter.unbind(token.dup)).to be_nil
    expect { adapter.unbind(token) }.to raise_error(Lich::WebUI::Error, /unknown binding/)
  end

  it 'keeps attached children alive without construction locals' do
    root = adapter.create(:stack, {})
    reference = attached(root)
    collect
    expect(reference.weakref_alive?).to be(true)
    expect(adapter.get(reference.__getobj__, :label)).to eq('Mounted')
    adapter.destroy(root)
  end

  it 'collects abandoned detached graphs including callbacks and pending drafts' do
    parent = adapter.create(:stack, {})
    references = 80.times.map { orphan(parent) }
    collect
    expect(references.none?(&:weakref_alive?)).to be(true)
    adapter.send(:prune_bindings!)
    expect(adapter.instance_variable_get(:@nodes).size).to eq(1)
    expect(adapter.instance_variable_get(:@bindings)).to be_empty
  end

  it 'collects published rebuild generations after replacement snapshots release callbacks' do
    root = adapter.create(:page, title: 'Rebuild')
    references = 40.times.map { orphan(root, publish: true) }
    collect
    expect(references.none?(&:weakref_alive?)).to be(true)
    adapter.send(:prune_bindings!)
    expect(adapter.instance_variable_get(:@nodes).size).to eq(1)
    expect(adapter.instance_variable_get(:@bindings)).to be_empty
    expect(service.registry.pages_for(owner).first.last_render.tree.children).to be_empty
  end

  it 'bounds dead string lookup metadata through normal binding churn' do
    parent = adapter.create(:stack, {})
    3.times do
      64.times { orphan(parent) }
      collect
    end
    # This normal binding reaches the next maintenance boundary, without
    # invoking the private sweep or forcing GC in production code.
    64.times { orphan(parent) }
    expect(adapter.instance_variable_get(:@bindings).size).to be <= 64
  end

  it 'retains only live explicit-destruction diagnostics and collects old tombstones' do
    handle = adapter.create(:text, content: 'Retained tombstone')
    adapter.destroy(handle)
    references = 20.times.map { tombstone }
    collect
    expect(references.none?(&:weakref_alive?)).to be(true)
    expect { adapter.destroy(handle) }.to raise_error(Lich::WebUI::Error, /already destroyed/)
    expect(adapter.instance_variable_get(:@destroyed).size).to eq(1)
  end

  it 'keeps focus discovery non-owning after detachment without changing retained target reuse' do
    root = adapter.create(:page, title: 'Focus')
    target = adapter.create(:button, label: 'Target')
    adapter.attach(root, target)
    adapter.focus(root, target)
    adapter.detach(root, target)
    collect
    adapter.attach(root, target)
    adapter.send(:flush!)
    page = service.registry.pages_for(owner).first
    expect(page.last_render.facilities[:focus]).to include('button:')
  end

  def abandoned_focus(root)
    target = adapter.create(:button, label: 'Abandoned focus')
    adapter.attach(root, target)
    adapter.focus(root, target)
    adapter.detach(root, target)
    WeakRef.new(target)
  end

  it 'does not retain abandoned detached targets through focus bookkeeping' do
    root = adapter.create(:page, title: 'Focus retirement')
    reference = abandoned_focus(root)
    collect
    expect(reference.weakref_alive?).not_to be(true)
    adapter.send(:flush!)
    expect(service.registry.pages_for(owner).first.last_render.facilities).not_to have_key(:focus)
  end

  it 'does not let a weak index accept foreign or duplicate handles' do
    handle = adapter.create(:text, content: 'Owned')
    foreign = Lich::WebUI::Adapter.new(owner: Object.new, service: service)
    collect
    expect(adapter.get(handle, :content)).to eq('Owned')
    expect { foreign.get(handle, :content) }.to raise_error(Lich::WebUI::Error, /unknown handle/)
    expect { adapter.get(handle.dup, :content) }.to raise_error(Lich::WebUI::Error, /unknown handle/)
  end
end
