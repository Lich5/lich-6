# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui'
require 'timeout'

RSpec.describe 'core-owned adapter hosting' do
  after { Lich::WebUI.reset! }

  it 'opens the published page and creates a fresh service after launcher shutdown' do
    previous = Lich::WebUI.service
    previous.stop
    opened = Queue.new
    allow(Lich::WebUI::BrowserLauncher).to receive(:open) { |url| opened << url; true }
    owner = Object.new
    adapter = Lich::WebUI.adapter(owner: owner)
    adapter.create(:page, title: 'Script setup')

    expect(Timeout.timeout(2) { opened.pop }).to include('127.0.0.1')
    expect(Lich::WebUI.service).not_to equal(previous)
    expect(Lich::WebUI.service.registry.pages_for(owner).length).to eq(1)
  end

  it 'registers and opens a native page after the previous service stops' do
    previous = Lich::WebUI.service
    previous.stop
    opened = []
    allow(Lich::WebUI::BrowserLauncher).to receive(:open) { |url, **| opened << url; true }
    owner = Object.new
    page = Lich::WebUI.page(owner: owner, id: 'after-stop', title: 'Native setup') do
      text(key: 'status', content: 'Ready')
    end

    host = Lich::WebUI.service
    expect(host).not_to equal(previous)
    expect(host.registry.pages_for(owner)).to eq([page])
    host.refresh(page)
    host.start
    expect(Lich::WebUI.open(page: page)).to be(true)
    expect(opened.length).to eq(1)
    expect(opened.first).to include(host.registry.address_for(page))
  end
end
