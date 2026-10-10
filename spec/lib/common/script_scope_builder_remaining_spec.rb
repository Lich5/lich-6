# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../../lib/common/script_scope'
require_relative '../../support/webui_browser'
require 'timeout'
require 'digest'

RSpec.describe 'remaining Builder setup families' do
  let(:scope) { Lich::Common::ScriptScope }
  let(:owner) { Struct.new(:name).new('remaining-builder.lic') }
  let(:service) { Lich::WebUI::Service.new }
  let(:gtk) { scope.const_get(:Gtk, false) }

  before do
    scope.activate!
    stub_const('Lich::Common::Script', Class.new { def self.current; end })
    allow(Lich::Common::Script).to receive(:current).and_return(owner)
    allow(Lich::WebUI).to receive(:adapter) { |owner:, viewer: nil| Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer) }
    allow(Lich::WebUI).to receive(:callback_queue) { |owner:| proc { |&work| service.runtime.dispatch(owner: owner, &work) } }
    @diagnostics, @downloads, @saved = [], [], []
    allow(Lich).to receive(:log) { |message| @diagnostics << message }
  end

  after do
    Lich::Common::ScriptDeath.run(owner)
    service.stop
    @runner&.join(2)
    @runner&.kill if @runner&.alive?
  end

  def drain
    2.times do
      barrier = Queue.new
      gtk.queue { barrier << true }
      expect(barrier.pop(timeout: 3)).to be(true)
    end
    expect(@diagnostics.grep(/callback failed/)).to be_empty, @diagnostics.join("\n")
  end

  # Keep all original construction and callbacks. Only game lookups, waiting
  # and external command/persistence destinations belong to this isolated harness.
  def original(name, game: 'GS')
    sandbox = Module.new
    sandbox.const_set(:Gtk, gtk)
    sandbox.const_set(:XMLData, double(game: game))
    sandbox.const_set(:Stats, double(prof: 'Warrior'))
    sandbox.const_set(:Society, double(membership: 'None', rank: 0))
    go2 = sandbox.const_set(:Go2, Module.new)
    saved, downloads = @saved, @downloads
    go2.define_singleton_method(:load) { |settings| saved << settings.dup }
    go2.define_singleton_method(:get_script_version) { 'fixture' }
    script = Object.new
    script.define_singleton_method(:run) { |*args, **options| downloads << [args, options] }
    sandbox.const_set(:Script, script)
    path = File.expand_path("../../fixtures/webui/#{name}_setup.lic", __dir__)
    source = File.read(path)
    expected = { 'repository' => 'ac0107e3149a487f61cfd345a3b962b7673df65ec99921f4b9fdd74d47dd86e5',
                 'go2'        => '8bdcf8959473c59d9da2eba4dbc69a2dd13185acd9a3c556288b1bd8198862b2' }
    wrappers = name == 'repository' ? 3 : 2
    expect(Digest::SHA256.hexdigest(source.lines[wrappers...-wrappers].join.lstrip.chomp)).to eq(expected.fetch(name))
    sandbox.module_eval(source, path)
    klass = name == 'repository' ? sandbox::Repository::RepositoryGUI::Setup : go2::Setup
    klass.define_method(:wait_while) { |&condition| sleep 0.005 while condition.call }
    @settings = {}
    @form = nil
    if name == 'repository'
      rows = [['header'], ['zeta.lic', 'GS', '2048', '1700000000', 'Zed', '1200', '8', '2', 'hunting', 'Zeta comments'],
              ['alpha.lic', 'GS', '10240', '1700000000', 'Ada', '90', '5', '1', 'travel', 'Alpha comments']]
      # Its constructor owns the wait loop, so retain the allocated instance for cleanup.
      @form = klass.allocate
      @runner = Thread.new { @form.send(:initialize, rows) }
      Timeout.timeout(3) { sleep 0.005 until @form.instance_variable_get(:@running) }
    else
      @form = klass.new(@settings)
      drain
      @runner = Thread.new { @form.start }
    end
    page = nil
    Timeout.timeout(4) do
      loop do
        drain
        page = service.registry.pages_for(owner).first
        break if page&.last_render
        sleep 0.005
      end
    end
    @page = page
    @form
  end

  def connect
    @messages = []
    @connection = double('viewer', viewer_id: 'fixture', alive?: true)
    allow(@connection).to receive(:send_text) { |json| @messages << JSON.parse(json) }
    service.runtime.handle(@connection, type: 'attach', page: service.registry.address_for(@page))
  end

  def cid(widget)
    handle = widget.instance_variable_get(:@handle)
    widget.session.port.send(:node!, handle).cid
  end

  def event(widget, name, payload, submission: nil)
    service.runtime.refresh(@page)
    render = @messages.reverse.find { |message| message['type'] == 'render' }
    message = { type: 'event', page: service.registry.address_for(@page), generation: render['generation'],
                cid: cid(widget), event: name, payload: payload }
    if submission == :current
      pending = [render.fetch('tree')]
      inputs = {}
      until pending.empty?
        node = pending.pop
        inputs[node['cid']] = node.fetch('props')
        pending.concat(node.fetch('children', []))
      end
      message[:submission] = @page.last_render.submissions.fetch(cid(widget), []).map { |id| inputs.fetch(id).fetch('value') }
    elsif submission
      message[:submission] = submission
    end
    expect(service.runtime.handle(@connection, message)).to eq(:queued), @messages.last.inspect
    drain
  end

  it 'loads repository, preserves numeric sorting and filters before activating the original download callback' do
    form = original('repository')
    connect
    tabs = @page.last_render.tree.each.find { |node| node.type == :tabs }
    expect(tabs.props[:show_tabs]).to be(false)
    table = @page.last_render.tree.each.find { |node| node.type == :table }
    expect(table.props).to include(activation: 'single', grid_lines: 'both')
    expect(table.props).not_to have_key(:search_column)
    expect(table.props[:columns].map { |column| column[:align] }).to include('end')
    size_column = form['repository'].columns.find { |column| column.sort_column_id == 3 }
    event(form['repository'], 'sort_change', { column: size_column.key, direction: 'asc' })
    expect(form['repository_store'].rows.map { |iter| iter[0] }).to eq(['zeta.lic', 'alpha.lic'])
    event(form['search_entry'], 'change', { value: 'travel' })
    row = form['repository_store'].iter_first
    expect(row[0]).to eq('alpha.lic')
    event(form['repository'], 'row_activate', { row: row.key }, submission: :current)
    expect(form['comments'].text).to eq('Alpha comments')
    event(form['download_link'], 'activate', {}, submission: :current)
    expect(@downloads).to eq([[['repository', 'download alpha.lic --author=Ada --game=GS'], { force: true }]])
    form.on_close_clicked
    drain
    expect(@runner.join(2)).to equal(@runner)
    expect(service.registry.pages_for(owner)).to be_empty
  end

  %w[GS DR].each do |game|
    it "loads go2 #{game} settings and runs the original update/Close callbacks" do
      form = original('go2', game: game)
      connect
      event(form['delay'], 'change', { value: 7 })
      event(form['echo_input'], 'change', { value: false })
      expect(@settings).to include(delay: 7, echo_input: false)
      form.on_close_clicked
      drain
      expect(@saved.last).to include(delay: 7, echo_input: false)
      expect(@runner.join(2)).to equal(@runner)
      expect(service.registry.pages_for(owner)).to be_empty
    end
  end

  [['repository', 'GS'], ['go2', 'GS'], ['go2', 'DR']].each do |name, game|
    it "runs original #{name} #{game} setup interactions in Chrome", browser: true do
      skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

      form = original(name, game: game)
      controls = form.objects.filter_map do |widget|
        next unless widget.respond_to?(:builder_name) && widget.instance_variable_get(:@handle)
        [widget.builder_name, cid(widget)]
      end.to_h
      WebUIBrowser.check(service: service, page: @page, scenario: "shim-#{name}", controls: controls)
      drain
      expect(form['main']).to be_destroyed
      expect(@runner.join(2)).to equal(@runner)
      expect(service.registry.pages_for(owner)).to be_empty
      if name == 'repository'
        expect(@downloads).to eq([[['repository', 'download alpha.lic --author=Ada --game=GS'], { force: true }]])
      else
        expect(@saved.last).to include(delay: 7, echo_input: false)
      end
    end
  end

  it 'refuses visible or multiple-page notebook reordering and unsupported search icon actions' do
    page = '<child><object class="GtkLabel"/></child><child type="tab"><object class="GtkLabel"/>' \
           '<packing><property name="reorderable">True</property></packing></child>'
    ["<object class=\"GtkNotebook\">#{page}</object>",
     "<object class=\"GtkNotebook\"><property name=\"show-tabs\">False</property>#{page}#{page}</object>"].each do |notebook|
      candidate = gtk::Builder.new
      expect { candidate.add_from_string("<interface>#{notebook}</interface>") }.to raise_error(gtk::BuilderError, /reorderable/)
      expect(candidate.objects).to be_empty
    end
    search = gtk::SearchEntry.new
    expect { search.primary_icon_name = 'document-open' }.to raise_error(gtk::UnsupportedOperation)
    expect { search.primary_icon_activatable = true }.to raise_error(gtk::UnsupportedOperation)
    expect { search.primary_icon_sensitive = true }.to raise_error(gtk::UnsupportedOperation)
    expect { gtk::Label.new.justify = :fill }.to raise_error(gtk::UnsupportedOperation)
  end
end
