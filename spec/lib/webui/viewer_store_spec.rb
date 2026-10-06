# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui/viewer_store'
require 'webui/page'

RSpec.describe Lich::WebUI::ViewerStore do
  let(:owner) { Object.new }
  let(:page) do
    Lich::WebUI::Page.new(owner: owner, id: 'form', title: 'Form') do
      text_input(key: 'name', value: '')
    end
  end

  it 'refuses repeated attachment without retaining unreachable viewers' do
    now = 100.0
    store = described_class.new(clock: -> { now })
    first = store.attach(connection_id: 'one', address: 'page-one', page: page)
    first.values[:draft] = 'retained'
    3.times do
      expect { store.attach(connection_id: 'one', address: 'page-one', page: page) }
        .to raise_error(Lich::WebUI::Error, /already attached/)
    end
    expect(store.attachments_for(page)).to eq([first])
    expect(store.transient_disconnect('one')).to eq([first])
    now += described_class::RECONNECT_WINDOW + 1
    expect(store.attachments_for(page)).to be_empty
    expect(first.values).to be_empty
  end

  it 'does not orphan either viewer when a resume targets an occupied connection/page pair' do
    store = described_class.new
    first = store.attach(connection_id: 'one', address: 'page-one', page: page)
    store.transient_disconnect('one')
    second = store.attach(connection_id: 'two', address: 'page-one', page: page)
    expect do
      store.attach(connection_id: 'two', address: 'page-one', page: page, resume_token: first.resume_token)
    end.to raise_error(Lich::WebUI::Error, /already attached/)
    expect(store.fetch(connection_id: 'two', address: 'page-one')).to equal(second)
    expect(store.attach(connection_id: 'three', address: 'page-one', page: page, resume_token: first.resume_token)).to equal(first)
    store.close(connection_id: 'two', address: 'page-one')
    store.close(connection_id: 'three', address: 'page-one')
    expect(store.attachments_for(page)).to be_empty
  end

  it 'keeps viewer-local values isolated and shared display content common' do
    store = described_class.new
    first = store.attach(connection_id: 'one', address: 'page-one', page: page)
    second = store.attach(connection_id: 'two', address: 'page-one', page: page)
    first_render = page.render
    second_render = page.render
    store.deliver(first, first_render)
    store.deliver(second, second_render)
    first_input = first_render.tree.each.find { |component| component.type == :text_input }

    store.update(first, first_input, :change, value: 'Alice')

    expect(store.serialize(first).dig(:children, 0, :props, :value)).to eq('Alice')
    expect(store.serialize(second).dig(:children, 0, :props, :value)).to eq('')
  end

  it 'refuses serialization before a render has been delivered' do
    store = described_class.new
    attachment = store.attach(connection_id: 'one', address: 'page-one', page: page)

    expect { store.serialize(attachment) }.to raise_error(Lich::WebUI::Error, /no delivered render/)
  end

  it 'ignores an older delivery without reverting the tree or viewer selections' do
    choices = [{ value: 'old', label: 'Old' }]
    target = Lich::WebUI::Page.new(owner: owner, id: 'choices', title: 'Choices') do
      select(key: 'choice', options: choices, value: choices.first[:value])
    end
    store = described_class.new
    attachment = store.attach(connection_id: 'one', address: 'choices', page: target)
    older = target.render
    choices.replace([{ value: 'new', label: 'New' }])
    newer = target.render
    store.deliver(attachment, newer)
    values = attachment.values.dup

    store.deliver(attachment, older)

    expect(attachment.delivered_generation).to eq(newer.generation)
    expect(attachment.render).to equal(newer)
    expect(attachment.values).to eq(values)
    expect(store.serialize(attachment).dig(:children, 0, :props, :value)).to eq('new')
    store.deliver(attachment, newer)
    expect(attachment.render).to equal(newer)
  end

  it 'retains a moved divider whose initial position was naturally sized, isolated by viewer' do
    target = Lich::WebUI::Page.new(owner: owner, id: 'split', title: 'Split') do
      split(key: 'row', orientation: :horizontal) do
        text(slot: :first, content: 'Duration')
        text(slot: :second, content: 'Spell')
      end
    end
    store = described_class.new
    first = store.attach(connection_id: 'one', address: 'split', page: target)
    second = store.attach(connection_id: 'two', address: 'split', page: target)
    render = target.render
    [first, second].each { |viewer| store.deliver(viewer, render) }
    divider = render.tree.children.first
    store.update(first, divider, :move, position: 35)
    [first, second].each { |viewer| store.deliver(viewer, target.render) }
    expect(store.serialize(first).dig(:children, 0, :props, :position)).to eq(35)
    expect(store.serialize(second).dig(:children, 0, :props)).not_to have_key(:position)
  end

  it 'clears a removed select choice for each viewer while retaining other valid choices' do
    options = [{ value: 'none', label: '' }, { value: 'old', label: 'Old' }, { value: 'keep', label: 'Keep' }]
    page = Lich::WebUI::Page.new(owner: owner, id: 'choices', title: 'Choices') do
      select(key: 'choice', options: options, value: 'none')
    end
    store = described_class.new
    first = store.attach(connection_id: 'one', address: 'choices', page: page)
    second = store.attach(connection_id: 'two', address: 'choices', page: page)
    render = page.render
    [first, second].each { |viewer| store.deliver(viewer, render) }
    input = render.tree.each.find { |node| node.type == :select }
    store.update(first, input, :change, value: 'old')
    store.update(second, input, :change, value: 'keep')
    options.delete_at(1)
    render = page.render
    [first, second].each { |viewer| store.deliver(viewer, render) }
    expect(store.serialize(first).dig(:children, 0, :props, :value)).to eq('none')
    expect(store.serialize(second).dig(:children, 0, :props, :value)).to eq('keep')
  end

  it 'resumes within the transient window and destroys values after expiry' do
    now = 100.0
    store = described_class.new(clock: -> { now })
    attachment = store.attach(connection_id: 'one', address: 'page-one', page: page)
    render = page.render
    store.deliver(attachment, render)
    input = render.tree.each.find { |component| component.type == :text_input }
    store.update(attachment, input, :change, value: 'retained')
    store.transient_disconnect('one')

    resumed = store.attach(
      connection_id: 'two', address: 'page-one', page: page, resume_token: attachment.resume_token
    )
    expect(resumed).to equal(attachment)
    expect(resumed.values[[input.cid, :value]]).to eq('retained')

    store.transient_disconnect('two')
    now += described_class::RECONNECT_WINDOW + 1
    fresh = store.attach(
      connection_id: 'three', address: 'page-one', page: page, resume_token: attachment.resume_token
    )
    expect(fresh).not_to equal(attachment)
    expect(attachment.values).to be_empty
  end

  it 'destroys all viewer state when its page owner terminates' do
    store = described_class.new
    attachment = store.attach(connection_id: 'one', address: 'page-one', page: page)
    store.deliver(attachment, page.render)

    store.destroy_page(page)

    expect(attachment.values).to be_empty
    expect { store.fetch(connection_id: 'one', address: 'page-one') }.to raise_error(Lich::WebUI::Error)
  end

  it 'retains false viewer values when a later render redeclares a true default' do
    page = Lich::WebUI::Page.new(owner: owner, id: 'expander', title: 'Expander') do
      expander(key: 'details', label: 'Details', open: true) { text(content: 'body') }
    end
    store = described_class.new
    attachment = store.attach(connection_id: 'one', address: 'page-one', page: page)
    first = page.render
    store.deliver(attachment, first)
    expander = first.tree.each.find { |component| component.type == :expander }
    store.update(attachment, expander, :toggle, open: false)

    store.deliver(attachment, page.render)

    serialized = store.serialize(attachment)
    expect(serialized.dig(:children, 0, :props, :open)).to be false
  end
end
