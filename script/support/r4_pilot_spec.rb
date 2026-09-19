# frozen_string_literal: true

# Run explicitly with R4_CORPUS_ROOT pointing to the read-only frozen corpus.
# This acceptance spec uses the production Script loader and exact source bytes.
# Only game/settings services are fixtures; widget calls run through the shim.
require_relative '../../spec/spec_helper'
require 'digest'
require 'json'
require 'timeout'
require 'shellwords'
require 'sqlite3'
require_relative '../../lib/common/limitedarray'
require_relative '../../lib/common/class_exts/nilclass'
require_relative '../../lib/common/class_exts/stringproc'
require_relative '../../lib/common/feature_flags'
require_relative '../../lib/common/downstreamhook'
require_relative '../../lib/common/upstreamhook'
require_relative '../../lib/common/script_scope'
require_relative '../../lib/common/script'
require_relative '../../lib/webui'
Object.include Lich::Common

RSpec.describe 'R4 actual script consumers' do
  let(:runtime_script) { Lich::Common::Script }
  let(:service_errors) { [] }
  let(:service) do
    Lich::WebUI::Service.new(logger: lambda do |level, message|
      service_errors << message if level == :error
      warn(message) if ENV['DEBUG']
    end)
  end

  before do |example|
    skip 'requires the corrected Projects/scripts source' if example.metadata[:corrected] && !ENV['R4_SOURCE_REPO']
    corpus = ENV.fetch('R4_CORPUS_ROOT')
    @name = example.metadata.fetch(:script_name, 'MyFletch')
    @description = example.description
    @repository = example.metadata.fetch(:repository, 'eo-scripts')
    @relative_source = @repository == 'eo-scripts' ? "scripts/#{@name}.lic" : "#{@name}.lic"
    @source = if ENV['R4_SOURCE_REPO'] && @repository == 'eo-scripts'
                File.join(ENV.fetch('R4_SOURCE_REPO'), @relative_source)
              else
                File.join(corpus, @repository, @relative_source)
              end
    stub_const('SCRIPT_DIR', File.dirname(@source))
    @settings = {}
    @settings.define_singleton_method(:load) { self }
    @settings.define_singleton_method(:save) { self }
    @saved = {}
    variables = OpenStruct.new
    variables.define_singleton_method(:change) { |name, value, _scope| @values[name] = value }
    variables.instance_variable_set(:@values, @saved)
    scope_name = 'Lich::Common::ScriptScope'
    stub_const("#{scope_name}::CharSettings", @settings)
    stub_const("#{scope_name}::Settings", @settings)
    stub_const("#{scope_name}::UserVars", variables)
    vars = { 'existing' => 'original' }
    vars.define_singleton_method(:list) { self }
    stub_const("#{scope_name}::Vars", vars)
    stub_const("#{scope_name}::Char", Struct.new(:name, :prof, :level).new('Fixture', 'Ranger', 20))
    stub_const("#{scope_name}::XMLData", Struct.new(:game, :name).new('GSF', 'Fixture'))
    stub_const("#{scope_name}::LICH_VERSION", '6.0.0')
    spells = Object.new
    known = example.metadata.fetch(:spells_known, true)
    spells.define_singleton_method(:[]) { |_number| Struct.new(:known?).new(known) }
    stub_const("#{scope_name}::Spell", spells)
    allow(Lich).to receive(:log)
    allow(Lich::WebUI).to receive(:adapter) do |owner:, viewer: nil|
      Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer)
    end
    Lich::Common::ScriptScope.module_eval do
      define_method(:before_dying) { |&block| Lich::Common::Script.at_exit(&block) }
      define_method(:undo_before_dying) { Lich::Common::Script.clear_exit_procs }
      define_method(:wait_while) { |&condition| sleep(0.01) while condition.call }
      define_method(:wait_until) { |&condition| sleep(0.01) until condition.call }
      define_method(:report_errors) { |&block| block.call }
      define_method(:variable) { Lich::Common::Script.current.vars }
      define_method(:no_kill_all) { Lich::Common::Script.current.no_kill_all = !Lich::Common::Script.current.no_kill_all }
      define_method(:no_pause_all) { Lich::Common::Script.current.no_pause_all = !Lich::Common::Script.current.no_pause_all }
      define_method(:hide_me) { Lich::Common::Script.current.hidden = !Lich::Common::Script.current.hidden }
      define_method(:silence_me) { Lich::Common::Script.current.silent = !Lich::Common::Script.current.silent }
      define_method(:monsterbold_start) { '<pushBold/>' }
      define_method(:monsterbold_end) { '<popBold/>' }
      define_method(:checkname) { 'Fixture' }
      define_method(:checkstance) { 'defensive' }
      define_method(:checkleft) { nil }
      define_method(:checkright) { nil }
      define_method(:pause) { |seconds| sleep(seconds) }
      define_method(:get_settings) { OpenStruct.new(performance_monitor_weapons: ['longsword']) }
      define_method(:start_scripts_if_available) do |names|
        raise 'unexpected fixture dependency' unless names == ['textsubs']
      end
    end
    allow_any_instance_of(runtime_script).to receive(:report_errors) { |_script, &block| block.call }
  end

  after do
    @tracepoint&.disable
    @script&.kill(context: :runtime, async: false) if @script&.running?
    service.stop
    expect(service_errors).to be_empty, "WebUI worker errors: #{service_errors.join('; ')}"
    expect($LOADED_FEATURES.grep(%r{/(?:gtk3|glib2|gdk3|pango)(?:/|\.)})).to be_empty
  end

  def wait_for
    Timeout.timeout(5) do
      loop do
        result = yield
        return result if result

        raise @script.exit_error if @script&.exit_error
        sleep 0.01
      end
    end
  end

  def consumer_page
    expect(@script).to be_a(runtime_script), "#{@name} did not start"
    page = wait_for do
      candidate = service.registry.pages_for(@script).first
      candidate if candidate&.last_render
    end
    @controls = page.last_render.tree.each.map do |component|
      { type: component.type, label: component.props[:label], tabs: component.props[:names], content: component.props[:content] }.compact
    end
    page
  end

  def submit_form(page, label, values, finish: true)
    sent = []
    connection = double('authenticated fixture', viewer_id: 'pilot-viewer', alive?: true)
    allow(connection).to receive(:send_text) { |json| sent << JSON.parse(json) }
    address = service.registry.address_for(page)
    service.runtime.handle(connection, type: 'attach', page: address)
    button = page.last_render.tree.each.find { |component| component.type == :button && component.props[:label] == label }
    expect(button).not_to be_nil, "missing submit button #{label.inspect}"
    result = service.runtime.handle(connection, type: 'event', page: address, cid: button.cid,
                                               generation: sent.last['generation'], event: 'activate', payload: {}, submission: values)
    expect(result).to eq(:queued), "submission cid=#{button.cid} was refused: #{sent.last}"
    expect(@script.join(5)).to equal(@script) if finish
  end

  def browser_completion(page)
    service.start
    puts "R4_BROWSER_URL=#{service.launch_url(page: page)}"
    $stdout.flush
    expect(@script.join(180)).to equal(@script)
  end

  def start_trace
    @trace = []
    source_lines = File.readlines(@source)
    @tracepoint = TracePoint.new(:call, :return, :line) do |event|
      if event.event == :line
        if event.path == @name && (gate = source_lines[event.lineno - 1]&.match(/Gtk::Version::(?:STRING|MAJOR)|HAVE_GTK/))
          @trace << { phase: :gate, gate: gate[0], source: @relative_source, line: event.lineno }
        end
        next
      end
      receiver = event.self.is_a?(Module) ? event.self.name : event.self.class.name
      namespaces = /ScriptScope::(?:Gtk|Pango|Gdk)/
      receiver = event.defined_class.name unless receiver&.match?(namespaces)
      next unless receiver&.match?(namespaces)

      # Only calls made directly by the frozen source are evidence of its API
      # needs. Internal shim calls must not inflate the measured population.
      location = caller_locations[1]
      next unless location&.path == @name

      @trace << {
        receiver: receiver.split('ScriptScope::').last, operation: event.method_id,
        phase: event.event, source: @relative_source, line: location.lineno,
        arguments: event.event == :call ? event.parameters.filter_map do |kind, name|
          next unless name && name.to_s.match?(/\A[a-z_]\w*\z/) && event.binding.local_variable_defined?(name)

          value = event.binding.local_variable_get(name)
          { parameter: name, kind: kind, shape: argument_shape(value) }
        end : [],
        signal: event.method_id == :signal_connect ? event.binding.local_variable_get(:name) : nil,
        returns_self: event.event == :return && event.return_value.equal?(event.self)
      }
    end
    @tracepoint.enable
  end

  def argument_shape(value)
    case value
    when Symbol, Numeric, true, false, nil then { type: value.class.name, value: value }
    when String then { type: 'String', length: value.length }
    when Array then { type: 'Array', elements: value.map { |item| argument_shape(item) } }
    when Hash then { type: 'Hash', keys: value.keys.map(&:to_s) }
    else { type: value.class.name.sub('Lich::Common::ScriptScope::', '') }
    end
  end

  def record_trace
    @tracepoint.disable
    return unless ENV['R4_TRACE_OUTPUT'] || ENV['R4_TRACE_DIR']

    browser = ENV['R4_BROWSER'] == '1'
    environment = %w[R4_CORPUS_ROOT R4_SOURCE_REPO R4_TRACE_DIR R4_TRACE_OUTPUT].filter_map do |name|
      "#{name}=#{Shellwords.escape(ENV[name])}" if ENV[name]
    end
    metadata = {
      source_path: @relative_source, sha256: Digest::SHA256.file(@source).hexdigest,
      entrypoint: [";#{@name}", @script.vars.first].compact.join(' '), browser: browser,
      generation_ruby: RUBY_DESCRIPTION, source_unmodified: !ENV['R4_SOURCE_REPO'],
      expected_controls: @controls,
      command: "#{environment.join(' ')} R4_BROWSER=#{browser ? 1 : 0} rspec script/support/r4_pilot_spec.rb --example #{Shellwords.escape(@description)}"
    }
    # One ordered event per line keeps mechanically generated evidence compact.
    output = JSON.generate(metadata)[0...-1] + ",\"trace\":[\n" + @trace.map { |call| JSON.generate(call) }.join(",\n") + "]}\n"
    destination = ENV['R4_TRACE_OUTPUT'] || File.join(ENV.fetch('R4_TRACE_DIR'), "#{@name}.json")
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, output)
  end

  it 'loads setup, preserves chained layout, edits a field and saves after destroying the window' do
    start_trace
    @script = runtime_script.start('MyFletch', 'setup', quiet: true)
    expect(@script).to be_a(runtime_script)
    page = consumer_page
    tree = page.last_render.tree
    expect(tree.props[:title]).to eq('MyFletch Configuration for Fixture')
    expect(tree.each.count { |component| component.type == :text_input }).to eq(8)
    expect(tree.each.find { |component| component.type == :tabs }.props[:names]).to eq(['MyFletch Settings'])

    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      inputs = tree.each.select { |component| %i[text_input checkbox].include?(component.type) }
      values = inputs.map { |component| component.type == :checkbox ? false : '' }
      values[0] = '  dagger  '
      submit_form(page, 'Save', values)
    end
    expect(@script.exit_error).to be_nil
    expect(@saved['Fsmallblade']).to eq('dagger')
    expect(service.registry.pages_for(@script)).to be_empty
    expect(@trace.any? { |call| call[:operation] == :set_markup && call[:returns_self] }).to be(true)
    expect($LOADED_FEATURES.grep(%r{/(?:gtk3|glib2|gdk3|pango)(?:/|\.)})).to be_empty
    record_trace
  end

  it 'runs the real STRING gate and saves the selected professions', script_name: 'heal_spellup' do
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    checks = page.last_render.tree.each.select { |component| component.type == :checkbox }
    expect(checks.map { |component| component.props[:label] }).to eq(%w[Bard Cleric Empath Monk Paladin Ranger Rogue Sorcerer Warrior Wizard])
    expect(checks.map { |component| component.props[:checked] }).to all(eq(false))
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      submit_form(page, 'Save and Close', [true, *Array.new(9, false)])
    end
    expect(@settings['Bard']).to be(true)
    expect(@settings['Wizard']).to be(false)
    expect(@trace.none? { |call| call[:receiver] == 'Gtk::VBox' }).to be(true)
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'passes the DR availability gate and updates the kill count', script_name: 'kill-counter', repository: 'dr-scripts' do
    start_trace
    @script = runtime_script.start(@name, quiet: true)
    page = consumer_page
    @script.downstream_buffer.push('You search the goblin.')
    wait_for { page.last_render.tree.each.any? { |component| component.props[:content] == 'Kill Count: 1' } }
    expect(page.last_render.tree.each.count { |component| component.type == :text }).to eq(2)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      @script.kill(context: :runtime, async: false)
      expect(@script.join(5)).to equal(@script)
    end
    expect(@script.exit_error).to be_nil
    expect(service.registry.pages_for(@script)).to be_empty
    record_trace
  end

  it 'runs the label-based ForgeMaster setup and saves its bag name', script_name: 'ForgeMaster' do
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    tree = page.last_render.tree
    expect(tree.each.count { |component| component.type == :text_input }).to eq(5)
    expect(tree.each.count { |component| component.type == :checkbox }).to eq(9)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      inputs = tree.each.select { |component| %i[text_input checkbox].include?(component.type) }
      values = inputs.map { |component| component.type == :checkbox ? false : '' }
      values[inputs.index { |component| component.type == :text_input }] = '  forge satchel  '
      submit_form(page, 'Save', values)
    end
    expect(@saved['mainforgebag']).to eq('forge satchel')
    expect(@script.exit_error).to be_nil
    record_trace
  end

  { 'iSigns' => '9903', 'isigils' => '9703' }.each do |name, first_setting|
    it "saves the first choice in #{name} without changing the other ten", script_name: name do
      start_trace
      @script = runtime_script.start(@name, 'setup', quiet: true)
      page = consumer_page
      expect(page.last_render.tree.each.count { |component| component.type == :checkbox }).to eq(11)
      if ENV['R4_BROWSER'] == '1'
        browser_completion(page)
      else
        submit_form(page, 'Save and Close', [true, *Array.new(10, false)])
      end
      expect(@settings[first_setting]).to be(true)
      expect(@settings.values.count(true)).to eq(1)
      expect(@script.exit_error).to be_nil
      record_trace
    end
  end

  it 'saves perfume fields while its window is still materialized', script_name: 'perfume' do
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    expect(page.last_render.tree.each.count { |component| component.type == :text_input }).to eq(2)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      submit_form(page, 'Save & Close', ['  rose perfume  ', 'scent pouch', false])
    end
    expect(@saved).to include('frag_type' => 'rose perfume', 'frag_cont' => 'scent pouch')
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'calculates and displays DR weapon statistics from fixture game lines', script_name: 'performance-monitor', repository: 'dr-scripts' do
    start_trace
    @script = runtime_script.start(@name, quiet: true)
    page = consumer_page
    @script.downstream_buffer.push('<combat> longsword a good hit'.dup)
    @script.downstream_buffer.push('Roundtime: 4'.dup)
    wait_for do
      page.last_render.tree.each.any? { |component| component.props[:content] == "longsword:\tavg RT:4.0\tavg DPS:0.5" }
    end
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      @script.kill(context: :runtime, async: false)
      expect(@script.join(5)).to equal(@script)
    end
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'saves the herb bag with both optional spell controls available', script_name: 'betazzherb' do
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    tree = page.last_render.tree
    expect(tree.each.count { |component| component.type == :text_input }).to eq(1)
    expect(tree.each.count { |component| component.type == :checkbox }).to eq(5)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      submit_form(page, 'Save & Close', ['herb satchel', *Array.new(5, false)])
    end
    expect(@saved['lootsack']).to eq('herb satchel')
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'saves boon settings across its four configuration tabs', script_name: 'boon' do
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    tree = page.last_render.tree
    notebook = tree.each.find { |component| component.type == :tabs }
    expect(notebook.props[:names]).to eq(%w[Sacks Looting Skinning Selling])
    expect(notebook.props[:selected]).to eq(0)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      inputs = tree.each.select { |component| %i[text_input checkbox].include?(component.type) }
      values = inputs.map { |component| component.type == :checkbox ? false : component.props.fetch(:value, '') }
      values[inputs.index { |component| component.type == :text_input }] = 'ammo satchel'
      submit_form(page, 'Save & Close', values)
    end
    expect(@saved['ammosack']).to eq('ammo satchel')
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'saves herb settings when neither optional spell is known', script_name: 'betazzherb', spells_known: false, corrected: true do
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    expect(page.last_render.tree.each.count { |component| component.type == :checkbox }).to eq(3)
    submit_form(page, 'Save & Close', ['herb satchel', false, false, false])
    expect(@saved['lootsack']).to eq('herb satchel')
    expect(@script.exit_error).to be_nil
    expect(Lich).not_to have_received(:log).with(/child already packed/)
  end

  it 'exits perfume setup when its page is intentionally closed', script_name: 'perfume', corrected: true do
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    connection = double('closing viewer', viewer_id: 'closing-viewer', alive?: true, send_text: nil)
    address = service.registry.address_for(page)
    service.runtime.handle(connection, type: 'attach', page: address)
    service.runtime.handle(connection, type: 'detach', page: address, generation: page.last_render.generation)
    expect(@script.join(1)).to equal(@script)
    expect(@saved).to be_empty
  end

  it 'opens vars and appends a new editable row on actual focus', script_name: 'vars' do
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    expect(page.last_render.tree.each.count { |component| component.type == :text_input }).to eq(3)
    sent = []
    connection = double('vars viewer', viewer_id: 'vars-viewer', alive?: true)
    allow(connection).to receive(:send_text) { |json| sent << JSON.parse(json) }
    address = service.registry.address_for(page)
    service.runtime.handle(connection, type: 'attach', page: address)
    entry = page.last_render.tree.each.find do |component|
      component.props[:placeholder] == '(new var name)' || component.props[:value] == '(new var name)'
    end
    result = service.runtime.handle(connection, type: 'event', page: address, cid: entry.cid,
                                    generation: sent.last['generation'], event: 'focus', payload: {})
    expect(result).to eq(:queued), sent.inspect
    wait_for { page.last_render.tree.each.count { |component| component.type == :text_input } == 5 }
    expect(@script.exit_error).to be_nil
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      @script.kill(context: :runtime, async: false)
      expect(@script.join(5)).to equal(@script)
    end
    record_trace
  end

  it 'saves the actual eforgery storage form', script_name: 'eforgery' do
    @settings['first_run'] = false
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    controls = page.last_render.tree.each.select { |component| %i[text_input checkbox].include?(component.type) }
    expect(controls.count { |component| component.type == :text_input }).to eq(13)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      values = controls.map { |component| component.type == :checkbox ? false : component.props[:value] }
      values[controls.index { |component| component.type == :text_input }] = 'forging bag'
      submit_form(page, 'Save & Close', values)
    end
    expect(@settings['average_container']).to eq('forging bag')
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'saves the actual uberfletch paint selection by its legacy index', script_name: 'uberfletch' do
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    controls = page.last_render.tree.each.select { |component| %i[text_input checkbox select].include?(component.type) }
    expect(controls.count { |component| component.type == :select }).to eq(1)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      values = controls.map do |component|
        case component.type
        when :checkbox then false
        when :select then component.props[:options][3][:value]
        else component.props[:value]
        end
      end
      submit_form(page, 'Save & Close', values)
    end
    expect(@settings['fletch_paint']).to eq(2)
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'saves fletchit ammunition using its one-based persisted setting', script_name: 'fletchit' do
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    controls = page.last_render.tree.each.select { |component| %i[text_input checkbox select].include?(component.type) }
    expect(controls.count { |component| component.type == :select }).to eq(2)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      values = controls.map do |component|
        case component.type
        when :checkbox then false
        when :select then component.props[:options][2][:value]
        else component.props[:value]
        end
      end
      submit_form(page, 'Save & Close', values)
    end
    expect(@settings[:ammo]).to eq(2)
    expect(@settings[:paint]).to eq(1)
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'updates hands and room labels in their original top-to-bottom order', script_name: 'hands_and_room' do
    game_objects = OpenStruct.new(right_hand: OpenStruct.new(name: 'empty'), left_hand: OpenStruct.new(name: 'empty'), pcs: [], npcs: [])
    stub_const('Lich::Common::ScriptScope::GameObj', game_objects)
    @settings['window_position'] = [0, 0]
    start_trace
    @script = runtime_script.start(@name, quiet: true)
    page = consumer_page
    game_objects.right_hand = OpenStruct.new(name: 'fixture sword')
    game_objects.left_hand = OpenStruct.new(name: 'fixture shield')
    game_objects.pcs = ['Companion']
    wait_for { page.last_render.tree.each.any? { |component| component.props[:content] == 'Right: fixture sword' } }
    labels = page.last_render.tree.each.select { |component| component.type == :text }.map { |component| component.props[:content] }
    expect(labels).to eq(['Right: fixture sword', 'Left: fixture shield', 'Room: Companion'])
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      @script.kill(context: :runtime, async: false)
      @script.join(5)
    end
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'saves corrected sellunder settings without loading native GTK', script_name: 'sellunder', corrected: true do
    Dir.mktmpdir('r4-sellunder-') do |directory|
      stub_const('DATA_DIR', directory)
      start_trace
      @script = runtime_script.start(@name, 'setup', quiet: true)
      page = consumer_page
      controls = page.last_render.tree.each.select { |component| %i[text_input checkbox].include?(component.type) }
      expect(controls.count { |component| component.type == :text_input }).to eq(1)
      if ENV['R4_BROWSER'] == '1'
        browser_completion(page)
      else
        values = controls.map { |component| component.type == :checkbox ? component.props[:checked] : '60000' }
        submit_form(page, 'Save', values)
      end
      saved = YAML.load_file(File.join(directory, 'GSF', 'Fixture', 'sellunder.yaml'))
      expect(saved['price_ceiling']).to eq(60_000)
      expect(@script.exit_error).to be_nil
      expect($LOADED_FEATURES.grep(%r{/(?:gtk3|gdk3|pango)[/.]})).to be_empty
      record_trace
    end
  end

  it 'saves symbolz choices and destroys its top-level window', script_name: 'symbolz' do
    Dir.mktmpdir('r4-symbolz-') do |directory|
      stub_const('DATA_DIR', directory)
      start_trace
      @script = runtime_script.start(@name, 'setup', quiet: true)
      page = consumer_page
      expect(page.last_render.tree.each.count { |component| component.type == :checkbox }).to eq(7)
      if ENV['R4_BROWSER'] == '1'
        browser_completion(page)
      else
        submit_form(page, 'Save and Close', [true, *Array.new(6, false)])
      end
      saved = YAML.load_file(File.join(directory, 'GSF', 'Fixture', 'symbolz.yaml'))
      expect(saved['9806']).to be(true)
      expect(@script.exit_error).to be_nil
      record_trace
    end
  end

  it 'updates ecure wound thresholds through numeric events and saves', script_name: 'ecure' do
    Lich::Common::ScriptScope::Char.prof = 'Empath'
    stub_const('Lich::Common::ScriptScope::Stats', Lich::Common::ScriptScope::Char)
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    expect(page.last_render.tree.each.count { |component| component.type == :number_input }).to be > 20
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      sent = []
      connection = double('ecure viewer', viewer_id: 'ecure-viewer', alive?: true)
      allow(connection).to receive(:send_text) { |json| sent << JSON.parse(json) }
      address = service.registry.address_for(page)
      service.runtime.handle(connection, type: 'attach', page: address)
      control = page.last_render.tree.each.find { |component| component.type == :number_input }
      expect(service.runtime.handle(connection, type: 'event', page: address, cid: control.cid,
                                               generation: sent.last['generation'], event: 'change', payload: { value: 2 })).to eq(:queued)
      controls = page.last_render.tree.each.select { |component| %i[text_input checkbox number_input].include?(component.type) }
      values = controls.map { |component| component.type == :checkbox ? component.props[:checked] : component.props[:value] }
      submit_form(page, 'Save', values)
    end
    expect(@settings['Fixture']).to have_key('head_wounds_heal')
    expect(@settings['Fixture']['all_wounds_level']).to eq(2)
    expect(@script.exit_error).to be_nil
    record_trace
  end

  { 'mybounty' => :mybounty, 'madwarrior' => :warrior }.each do |name, setting|
    it "saves corrected #{name} through an explicit submission", script_name: name, corrected: true do
      Lich::Common::ScriptScope::Char.prof = 'Warrior' if name == 'madwarrior'
      variables = Lich::Common::ScriptScope::UserVars
      variables.public_send("#{setting}=", {})
      variables.define_singleton_method(:save) { true }
      start_trace
      @script = runtime_script.start(@name, 'setup', quiet: true)
      page = consumer_page
      controls = page.last_render.tree.each.select { |component| component.type == :text_input }
      expect(controls).not_to be_empty
      if ENV['R4_BROWSER'] == '1'
        browser_completion(page)
      else
        submit_form(page, 'Save & Close', ['yes', *Array.new(controls.length - 1, '')])
      end
      expect(variables.public_send(setting).values).to include('yes')
      expect(@script.exit_error).to be_nil
      record_trace
    end
  end

  it 'saves sloot sack settings across its legacy tabs', script_name: 'sloot' do
    objects = OpenStruct.new(type_data: { 'gem' => { name: /berry|thorn/ }, 'skin' => { name: /shriveled cutting/ } })
    stub_const('Lich::Common::ScriptScope::GameObj', objects)
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    controls = page.last_render.tree.each.select { |component| %i[text_input checkbox].include?(component.type) }
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      values = controls.map { |component| component.type == :checkbox ? false : component.props[:value] }
      values[controls.index { |component| component.type == :text_input }] = 'ammo satchel'
      submit_form(page, 'Save & Close', values)
    end
    expect(@saved['ammosack']).to eq('ammo satchel')
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'opens corrected armor charts and closes from its terminal button', script_name: 'armor', corrected: true do
    start_trace
    @script = runtime_script.start(@name, 'popup', quiet: true)
    page = consumer_page
    expect(page.last_render.tree.each.find { |node| node.type == :tabs }.props[:names]).to eq(['Armor Hindrance', 'Cast vs Hindrance', 'Padding Info'])
    content = page.last_render.tree.each.filter_map { |node| node.props[:content] }
    groups = content.find { |text| text.start_with?("AG\n") }
    expect(groups.lines.size).to eq(23)
    expect(content.any? { |text| text.start_with?("Points\n01 - 02") }).to be(true)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      submit_form(page, 'Close', [])
    end
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'toggles a signore power through its inherited GTK widgets', script_name: 'signore' do
    power = Struct.new(:num, :name, :known?, :active?) do
      def to_s = name
    end
    spells = Object.new
    spells.define_singleton_method(:[]) { |number| power.new(number, "Power #{number}", number == 9903, false) }
    stub_const('Lich::Common::ScriptScope::Spell', spells)
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    expect(page.last_render.tree.each.count { |node| node.type == :checkbox }).to eq(1)
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      @script.kill(context: :runtime, async: false)
    end
    expect(@settings['Power 9903']).to be(true) if ENV['R4_BROWSER'] == '1'
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'updates corrected clearcheckwiz and closes while game input is idle', script_name: 'clearcheckwiz', corrected: true do
    incoming = Queue.new
    incoming << 'for a list of other options.'
    incoming << '(OOC) Friend\'s player whispers, "Clear: village, Scrip: 250, Timeleft: 30M."'
    Lich::Common::ScriptScope.module_eval do
      define_method(:get?) { incoming.pop(true) rescue nil }
      define_method(:checkgrouped) { false }
      define_method(:fput) { |*| nil }
    end
    start_trace
    @script = runtime_script.start(@name, quiet: true)
    page = consumer_page
    wait_for { page.last_render.tree.each.any? { |node| node.props[:content] == '250' } }
    consumer_page
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      @script.kill(context: :runtime, async: false)
    end
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'creates and saves a corrected sbounty location without a tree model', script_name: 'sbounty', corrected: true do
    room = Struct.new(:tags).new([])
    rooms = Object.new
    rooms.define_singleton_method(:[]) { |_| room }
    stub_const('Lich::Common::ScriptScope::Room', rooms)
    sack = Struct.new(:noun, :name).new('satchel', 'a satchel')
    stub_const('Lich::Common::ScriptScope::GameObj', OpenStruct.new(inv: [sack]))
    Lich::Common::ScriptScope::UserVars.lootsack = 'satchel'
    Lich::Common::ScriptScope::UserVars.skinsack = 'satchel'
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
      expect($sbounty[:locations]).to have_key('Fixture hunting')
    else
      inputs = page.last_render.tree.each.select { |node| Lich::WebUI::Contract.schema(node.type)[:value] }
      submit_form(page, 'Close', inputs.map { |node| node.type == :checkbox ? node.props[:checked] : node.props[:value] })
    end
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'appends corrected localchat text and closes without GTK', script_name: 'localchat', corrected: true do
    incoming = Queue.new
    incoming << 'Friend says, "Hello <script>plain text</script>."'
    incoming << 'Friend recites:'
    incoming << 'A short verse.'
    Lich::Common::ScriptScope.module_eval { define_method(:get) { incoming.pop } }
    start_trace
    @script = runtime_script.start(@name, quiet: true)
    page = consumer_page
    wait_for { page.last_render.tree.each.any? { |node| node.type == :log && node.props[:lines].join.include?('A short verse.') } }
    consumer_page
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      @script.kill(context: :runtime, async: false)
    end
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'updates corrected spellson progress and removes expired spells', script_name: 'spellson', corrected: true do
    spell = Struct.new(:num, :name, :duration, :timeleft, :stacks, :remaining).new(401, 'Elemental Defense I', 60.0, 30.0, false, '30 seconds')
    spells = Object.new
    active = [spell]
    spells.define_singleton_method(:active) { active.dup }
    stub_const('Lich::Common::ScriptScope::Spell', spells)
    start_trace
    @script = runtime_script.start(@name, quiet: true)
    page = consumer_page
    wait_for { page.last_render.tree.each.any? { |node| node.type == :progress && (node.props[:value] - 0.5).abs < 0.0001 } }
    spell.timeleft = 120.0
    wait_for { page.last_render.tree.each.any? { |node| node.type == :progress && (node.props[:value] - 1.0).abs < 0.0001 } }
    consumer_page
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      active.clear
      wait_for { page.last_render.tree.each.none? { |node| node.type == :progress } }
      @script.kill(context: :runtime, async: false)
    end
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'displays the DR status monitor with isolated game and notification fixtures', script_name: 'status-monitor', repository: 'dr-scripts' do
    settings = OpenStruct.new(status_monitor_no_window: false, quit_on_status_warning: false,
                              unique_line_threshold: 1, line_frequency_threshold: 20,
                              line_similarity_percentage: 50, status_monitor_respond: false)
    Lich::Common::ScriptScope::UserVars.npcs = []
    notices = []
    Lich::Common::ScriptScope.module_eval do
      define_method(:status_tags) { nil }
      define_method(:parse_args) { |_| OpenStruct.new(debug: false, nowindow: false) }
      define_method(:get_settings) { settings }
      define_method(:get_data) { |_| { 'filter_strings' => [] } }
      define_method(:register_slackbot) { |_| nil }
      define_method(:send_slackbot_message) { |message| notices << message }
      define_method(:health) { 100 }
    end
    Dir.mktmpdir('r4-status-') do |directory|
      Dir.chdir(directory) do
        start_trace
        @script = runtime_script.start(@name, quiet: true)
        page = consumer_page
        @script.downstream_buffer << +'fixture repeated message'
        @script.downstream_buffer << +'fixture repeated message'
        wait_for { page.last_render.tree.each.any? { |node| node.type == :log && node.props[:lines].join.include?('fixture repeated message') } }
        consumer_page
        if ENV['R4_BROWSER'] == '1'
          browser_completion(page)
        else
          @script.kill(context: :runtime, async: false)
        end
        expect(notices).not_to be_empty
        expect(@script.exit_error).to be_nil
      end
    end
    record_trace
  end

  it 'saves corrected vars through an explicit terminal action before closing', script_name: 'vars', corrected: true do
    start_trace
    @script = runtime_script.start(@name, 'setup', quiet: true)
    page = consumer_page
    if ENV['R4_BROWSER'] == '1'
      browser_completion(page)
    else
      submit_form(page, 'Save & Close', ['replacement', '(new var name)', '(new var value)'])
    end
    expect(Lich::Common::ScriptScope::Vars['existing']).to eq('replacement')
    expect(Lich::Common::ScriptScope::Vars['newsetting']).to eq('42') if ENV['R4_BROWSER'] == '1'
    expect(@script.exit_error).to be_nil
    record_trace
  end

  it 'saves corrected alias triggers in the real database', script_name: 'alias', corrected: true do
    database = SQLite3::Database.new(':memory:')
    allow(runtime_script).to receive(:open_file).with('db3').and_return(database)
    @hooks = {}
    allow(Lich::Common::UpstreamHook).to receive(:add) { |name, callable, **| @hooks[name] = callable }
    allow(Lich::Common::UpstreamHook).to receive(:list) { @hooks.keys }
    allow(Lich::Common::UpstreamHook).to receive(:remove) { |name| @hooks.delete(name) }
    start_trace
    @script = runtime_script.start(@name, quiet: true)
    wait_for { @hooks['alias-service'] }
    previous_lich_char = $lich_char
    $lich_char = ';'
    worker = Thread.new { @hooks['alias-service'].call(';alias setup') }
    worker.join(2)
    page = consumer_page
    expect(page.last_render.tree.each.find { |component| component.type == :tabs }.props[:names]).to eq(["Fixture's Aliases", 'Global Aliases'])
    expect(page.last_render.tree.each.any? { |component| component.props[:label] == 'Save & Close' }).to be(true)
    if ENV['R4_BROWSER'] == '1'
      service.start
      puts "R4_BROWSER_URL=#{service.launch_url(page: page)}"
      $stdout.flush
      Timeout.timeout(180) { sleep 0.01 until service.registry.pages_for(@script).empty? }
    else
      sent = []
      connection = double('alias viewer', viewer_id: 'alias-viewer', alive?: true)
      allow(connection).to receive(:send_text) { |json| sent << JSON.parse(json) }
      address = service.registry.address_for(page)
      service.runtime.handle(connection, type: 'attach', page: address)
      entry = page.last_render.tree.each.find { |component| component.props[:placeholder] == '(new alias trigger)' }
      expect(service.runtime.handle(connection, type: 'event', page: address, cid: entry.cid,
                                    generation: sent.last['generation'], event: 'focus', payload: {})).to eq(:queued)
      wait_for { page.last_render.tree.each.count { |component| component.type == :text_input } == 6 }
      submit_form(page, 'Save & Close', ['inspect', 'look', '(new alias trigger)', '(new alias target)', '(new alias trigger)', '(new alias target)'], finish: false)
      wait_for { service.registry.pages_for(@script).empty? }
    end
    expect(database.get_first_value("SELECT target FROM gsf_fixture WHERE trigger='inspect'")).to eq('look')
    @script.kill(context: :runtime, async: false)
    @script.join(5)
    record_trace
  ensure
    $lich_char = previous_lich_char
    database&.close
  end
end
