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
end
