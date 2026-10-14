# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../../lib/common/script_scope'
require_relative '../../support/webui_browser'
require 'json'
require 'digest'
require 'timeout'

RSpec.describe 'scheduled repository and sail2 source acceptance' do
  let(:scope) { Lich::Common::ScriptScope }
  let(:gtk) { scope::Gtk }
  let(:glib) { scope::GLib }
  let(:owner) { Struct.new(:name).new('scheduling-acceptance.lic') }
  let(:service) { Lich::WebUI::Service.new }

  before do
    scope.activate!
    stub_const('Lich::Common::Script', Class.new { def self.current; end })
    allow(Lich::Common::Script).to receive(:current).and_return(owner)
    allow(Lich::WebUI).to receive(:adapter) { |owner:, viewer: nil| Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer) }
    allow(Lich::WebUI).to receive(:callback_queue) { |owner:| proc { |&work| service.runtime.dispatch(owner: owner, &work) } }
    allow(Lich::WebUI).to receive(:callback_scheduler) { |owner:| service.runtime.scheduler.for_owner(owner) }
    @logs, @downloads, @saved = [], [], []
    allow(Lich).to receive(:log) { |message| @logs << message }
    @old_sail_window = $sail2_config_window
  end

  after do
    Lich::Common::ScriptDeath.run(owner)
    service.stop
    @runner&.join(2)
    @runner&.kill if @runner&.alive?
    $sail2_config_window = @old_sail_window
  end

  def source(name)
    fixture = JSON.parse(File.read(File.expand_path('../../fixtures/webui/scheduling.json', __dir__)))['scripts'].fetch(name)
    text = fixture.fetch('source')
    expect(Digest::SHA256.hexdigest(text)).to eq(fixture.fetch('sha256'))
    [text, fixture.fetch('line')]
  end

  def drain(expect_success: true)
    2.times do
      done = Queue.new
      service.runtime.dispatch(owner: owner) { done << true }
      expect(done.pop(timeout: 3)).to be(true)
    end
    expect(@logs.grep(/callback failed/)).to be_empty, @logs.join("\n") if expect_success
  end

  def wait_for_page
    Timeout.timeout(4) do
      loop do
        drain
        @page = service.registry.pages_for(owner).first
        break if @page&.last_render

        sleep 0.005
      end
    end
    @page
  end

  def repository
    sandbox = Module.new
    sandbox.const_set(:Gtk, gtk)
    sandbox.const_set(:GLib, glib)
    downloads = @downloads
    script = Module.new
    script.define_singleton_method(:start) { |*args, **options| downloads << [args, options] }
    sandbox.const_set(:Script, script)
    text, line = source('repository')
    sandbox.module_eval(text, 'repository.lic', line)
    klass = sandbox::Setup
    klass.define_method(:wait_while) { |&condition| sleep 0.005 while condition.call }
    rows = [['header'], ['alpha.lic', 'GS', '1024', '1700000000', 'Ada', '90', '5', '1', 'travel', 'Alpha comments'],
            ['zeta.lic', 'GS', '2048', '1700000000', 'Zed', '1200', '8', '2', 'hunting', 'Zeta comments']]
    @form = klass.allocate
    @runner = Thread.new { @form.send(:initialize, rows) }
    wait_for_page
    @form
  end

  # The original branch is preserved byte-for-byte. Positive UI acceptance changes
  # only its initial nil to :pending so its final nil wait cannot exit before Idle.
  def sail2(repaired:)
    sandbox = Module.new
    sandbox.const_set(:Gtk, gtk)
    sandbox.const_set(:GLib, glib)
    sandbox.define_singleton_method(:script) { Struct.new(:vars).new([nil, 'config']) }
    sandbox.define_singleton_method(:load_sail2_data) { { 'use_flag' => true, 'flag_mode' => 'white', 'unrelated' => 'preserved' } }
    saved, logs = @saved, @logs
    sandbox.define_singleton_method(:save_sail2_data) { |data| saved << data.dup }
    sandbox.define_singleton_method(:respond) { |message| logs << message }
    sandbox.define_singleton_method(:wait_until) { |&condition| sleep 0.005 until condition.call }
    sandbox.define_singleton_method(:exit) { raise SystemExit }
    text, line = source('sail2')
    text = text.sub('$sail2_config_window = nil', '$sail2_config_window = :pending') if repaired
    if repaired
      @runner = Thread.new do
        sandbox.module_eval(text, 'sail2.lic', line)
      rescue SystemExit
        nil
      end
      wait_for_page
    else
      sandbox.module_eval(text, 'sail2.lic', line)
    end
  end

  it 'preserves sail2 original startup failure when the deferred creation has not run' do
    started, release = Queue.new, Queue.new
    service.runtime.dispatch(owner: owner) { started << true; release.pop }
    expect(started.pop(timeout: 2)).to be(true)
    expect { sail2(repaired: false) }.to raise_error(SystemExit)
    expect($sail2_config_window).to be_nil
    gtk.session.close
    release << true
    drain
    expect(service.registry.pages_for(owner)).to be_empty
  ensure
    release << true
  end

  it 'accepts repaired sail2 creation, inherited sensitivity, save and close' do
    sail2(repaired: true)
    window = $sail2_config_window
    descendants = lambda { |widget| [widget] + widget.children.flat_map { |child| descendants.call(child) } }
    all = descendants.call(window)
    checkbox = all.find { |widget| widget.is_a?(gtk::CheckButton) }
    combo = all.find { |widget| widget.is_a?(gtk::ComboBoxText) }
    connection = double('viewer', viewer_id: 'fixture', alive?: true, send_text: nil)
    service.runtime.handle(connection, type: 'attach', page: service.registry.address_for(@page))
    viewer = service.runtime.instance_variable_get(:@viewers).fetch(connection_id: 'fixture', address: service.registry.address_for(@page)).viewer_id
    gtk.session.send(:with_callback_context, viewer, window) do
      checkbox.active = false
      checkbox.send(:emit_handlers, :change)
      expect(combo.parent.sensitive?).to be(false)
      expect(combo.sensitive?).to be(true) # Retain the child's authored setting.
      expect(combo.is_sensitive?).to be(false)
      combo.active = 1
      all.find { |widget| widget.is_a?(gtk::Button) && widget.label == 'Save' }.send(:emit_handlers, :activate)
    end
    expect(@saved).to eq([{ 'use_flag' => false, 'flag_mode' => 'black', 'unrelated' => 'preserved' }])
    all.find { |widget| widget.is_a?(gtk::Button) && widget.label == 'Close' }.send(:emit_handlers, :activate)
    drain
    expect(@logs.grep(/callback failed/)).to be_empty
    expect(@runner.join(2)).to equal(@runner)
    expect(window).to be_destroyed
  end

  it 'runs the current repository download, replacement timer and ten-second re-enable unchanged' do
    form = repository
    button = form['download_link']
    form['link_data'].text = 'download alpha.lic --author=Ada --game=GS'
    button.send(:emit_handlers, :activate)
    first = form.instance_variable_get(:@download_timer)
    expect(button.sensitive?).to be(false)
    form['link_data'].text = 'download zeta.lic --author=Zed --game=GS'
    button.send(:emit_handlers, :activate)
    expect(glib::Source.remove(first)).to be(false)
    expect(@downloads.size).to eq(2)
    expect(@downloads.last).to eq([['repository', 'download zeta.lic --author=Zed --game=GS'], { force: true }])
    Timeout.timeout(12) { sleep 0.01 until form.instance_variable_get(:@download_timer).nil? }
    expect(button.sensitive?).to be(true)
    expect(form.instance_variable_get(:@pending_link)).to be_nil
    button.send(:emit_handlers, :activate)
    pending = form.instance_variable_get(:@download_timer)
    form.on_close_clicked
    expect(@runner.join(2)).to equal(@runner)
    Lich::Common::ScriptDeath.run(owner)
    expect(service.runtime.scheduler.for_owner(owner).cancel(pending)).to be(false)
  end

  it 'validates repository download suppression and re-enable in the browser', :browser do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    form = repository
    WebUIBrowser.check(service: service, page: @page, scenario: 'shim-repository-scheduling')
    expect(@downloads).to eq([[['repository', 'download alpha.lic --author=Ada --game=GS'], { force: true }]])
    expect(form.instance_variable_get(:@download_timer)).to be_nil
    expect(form.instance_variable_get(:@running)).to be(false)
    expect(@logs.grep(/callback failed/)).to be_empty
  end

  it 'validates retained window hide and scheduled show in the browser', :browser do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    window = gtk::Window.new
    window.title = 'Scheduled visibility'
    box = gtk::Box.new(:vertical)
    entry = gtk::Entry.new
    entry.text = 'Initial'
    hide = gtk::Button.new(label: 'Hide for 8 seconds')
    finish = gtk::Button.new(label: 'Finish')
    restored, saved = [], []
    hide.signal_connect('clicked') do
      window.hide
      glib::Timeout.add_seconds(8) do
        window.show
        restored << window.materialize
        false
      end
    end
    finish.signal_connect('clicked') { saved << entry.text; window.destroy }
    [entry, hide, finish].each { |widget| box.add(widget) }
    window.add(box)
    window.show_all
    handle = window.materialize
    wait_for_page
    WebUIBrowser.check(service: service, page: @page, scenario: 'shim-scheduled-visibility')
    expect(restored).to eq([handle])
    expect(saved).to eq(['Retained draft'])
    expect(window).to be_destroyed
    expect(@logs.grep(/callback failed/)).to be_empty
  end

  it 'validates repaired sail2 setup, inherited sensitivity and close in the browser', :browser do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    sail2(repaired: true)
    WebUIBrowser.check(service: service, page: @page, scenario: 'shim-sail2-scheduling')
    drain
    expect(@saved).to eq([{ 'use_flag' => false, 'flag_mode' => 'black', 'unrelated' => 'preserved' }])
    expect(@logs.grep(/callback failed/)).to be_empty
    expect(@logs.grep(/GUI error/)).to be_empty
    expect($sail2_config_window).to be_nil
  end
end
