# frozen_string_literal: true

require_relative '../../spec_helper'
require 'webui'
require_relative '../../support/webui_browser'

RSpec.describe 'WebUI browser bootstrap', browser: true do
  it 'loads a native page through the private file and delivers its callback' do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    service = Lich::WebUI::Service.new
    activated = false
    page = Lich::WebUI::Page.new(owner: Object.new, id: 'bootstrap', title: 'Browser fixture') do |ui|
      ui.text key: 'status', content: activated ? 'Callback received' : 'Awaiting callback'
      ui.button key: 'activate', label: 'Activate', on: { activate: lambda { |_event|
        activated = true
        service.runtime.refresh(page)
      } }
    end
    service.registry.register(page)
    page.bind_runtime(service.runtime)
    page.render
    WebUIBrowser.check(service: service, page: page, scenario: 'native-bootstrap')
    expect(activated).to be(true)
  ensure
    service&.stop
  end
end
