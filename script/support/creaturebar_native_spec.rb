# frozen_string_literal: true

require_relative '../../spec/spec_helper'
require 'webui'
require 'tmpdir'
require 'tempfile'
require 'fileutils'
require 'yaml'
require 'uri'
require 'base64'
require 'monitor'

RSpec.describe 'native CreatureBar presentation' do
  before do |example|
    skip 'explicit browser run only' if example.metadata[:browser] && ENV['NATIVE_BROWSER'] != '1'
    source = File.read(File.join(ENV.fetch('NATIVE_SCRIPTS_ROOT'), 'scripts/creaturebar.lic'))
    definitions = source[/  # Native CreatureBar shared presentation\n(.*?)  # End native CreatureBar shared presentation/m, 1]
    expect(definitions).not_to be_nil, 'native CreatureBar presentation is missing'
    @scope = Module.new
    @scope.module_eval(definitions, 'creaturebar.lic')
    @host = Lich::WebUI::Service.new
    allow(Lich::WebUI).to receive(:service).and_return(@host)
    allow(Lich::WebUI).to receive(:registry).and_return(@host.registry)
    allow(Lich::WebUI).to receive(:start)
    allow(Lich::WebUI).to receive(:open)
    @directory = Dir.mktmpdir('native-creaturebar')
    FileUtils.mkdir_p(File.join(@directory, 'silhouettes/greyscale/town'))
    FileUtils.mkdir_p(File.join(@directory, 'configs/greyscale/town'))
    png = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aK1sAAAAASUVORK5CYII=')
    %w[default.png rank1.png rank2.png rank3.png eyes_back_nerves.png greyscale/town/rat.png].each do |relative|
      File.binwrite(File.join(@directory, 'silhouettes', relative), png)
    end
    allow(Lich::WebUI::ImageSize).to receive(:read).and_return([100, 180])
    @assets = @scope::NativeAssets.new(owner: :creature_fixture, directory: @directory)
    @config_path = File.join(@directory, 'configs/greyscale/town/rat.yaml')
  end

  it 'loads both complete script definitions through their actual shared import without GTK' do
    root = ENV.fetch('NATIVE_SCRIPTS_ROOT')
    stub_const('DATA_DIR', @directory)
    stub_const('SCRIPT_DIR', File.join(root, 'scripts'))
    stub_const('CreatureBar', Module.new)
    stub_const('Script', double('script class', current: double(name: 'fixture')))
    load File.join(root, 'scripts/calibrate_creaturebar.lic')
    panel_class = ::CreatureBar::NativePanel
    load File.join(root, 'scripts/creaturebar.lic')
    expect(::CreatureBar::NativePanel).to equal(panel_class)
    expect(::CreatureBar::NativePanel).to be_a(Class)
    expect(::CreatureBar::NativeCalibration).to be_a(Class)
    expect($LOADED_FEATURES.grep(%r{/(?:gtk3|gdk3|gdk_pixbuf2)(?:\.rb|/)})).to be_empty
  end

  it 'browser targets a fixture creature and closes its dashboard', browser: true do
    targets = []
    records = [{ id: 42, name: 'a rat', noun: 'rat', family: 'rodent', current_hp: 75,
                 max_hp: 100, injuries: { head: 2 }, status: ['stunned'], current: true }]
    @dashboard = @scope::NativeDashboard.new(owner: :creature_fixture, assets: @assets,
                                             config: { 'multi_creature' => { 'max_shown' => 5 }, 'layout' => { 'mode' => 'horizontal', 'max_columns' => 5 },
                                                       'colors' => { 'window_background' => '#112233', 'current_target_border' => '#FFD700' } },
                                             creatures: proc { records }, target: proc { |id| targets << id }, save: proc {})
    @dashboard.show
    @host.start
    puts "CREATUREBAR_BROWSER_URL=#{@host.launch_url(page: @dashboard.page)}"
    $stdout.flush
    waiter = Thread.new { @dashboard.wait }
    expect(waiter.join(180)).to equal(waiter)
    expect(targets).to eq([42])
  ensure
    waiter&.kill if waiter&.alive?
  end

  it 'browser edits and explicitly saves a calibration then closes', browser: true do
    source = File.read(File.join(ENV.fetch('NATIVE_SCRIPTS_ROOT'), 'scripts/calibrate_creaturebar.lic'))
    @scope.module_eval(source[/  # Native calibration controller\n(.*?)  # End native calibration controller/m, 1], 'calibrate_creaturebar.lic')
    @calibrator = @scope::NativeCalibration.new(owner: :calibration_fixture, assets: @assets,
                                                global: { 'colors'         => { 'name_font' => '#E01B24', 'hp_text' => '#FFFFFF' },
                                                          'status_effects' => [{ 'name' => 'stunned', 'symbol' => 'S', 'color' => '#FFD700' }] })
    @calibrator.show
    @host.start
    puts "CALIBRATION_BROWSER_URL=#{@host.launch_url(page: @calibrator.page)}"
    $stdout.flush
    waiter = Thread.new { @calibrator.wait }
    expect(waiter.join(180)).to equal(waiter)
    saved = YAML.load_file(File.join(@directory, 'configs/default.yaml'))
    expect(saved['scale']).to eq(1.5)
    expect(saved.dig('name_display', 'font_size')).to eq(18)
    expect(saved.dig('hp_bar', 'font_size')).to eq(14)
    expect(saved.dig('status', 'font_size')).to eq(16)
  ensure
    waiter&.kill if waiter&.alive?
  end

  it 'calibrates unscaled coordinates, saves only explicitly, and preserves another variant on cancel' do
    source = File.read(File.join(ENV.fetch('NATIVE_SCRIPTS_ROOT'), 'scripts/calibrate_creaturebar.lic'))
    definitions = source[/  # Native calibration controller\n(.*?)  # End native calibration controller/m, 1]
    expect(definitions).not_to be_nil, 'native calibration controller is missing'
    @scope.module_eval(definitions, 'calibrate_creaturebar.lic')
    @calibrator = @scope::NativeCalibration.new(owner: :calibration_fixture, assets: @assets, global: {})
    @calibrator.show
    fire_calibration('Apply preview', 'scale' => 2.0, 'marker_size' => 12, 'part' => 'head')
    @calibrator.click(x: 66, y: 86, button: 'primary')
    expect(File.exist?(File.join(@directory, 'configs/default.yaml'))).to eq(false)
    fire_calibration('Save calibration')
    saved = YAML.load_file(File.join(@directory, 'configs/default.yaml'))
    expect(saved.dig('body_parts', 'head')).to eq([30, 40])
    expect(saved['scale']).to eq(2.0)
    @calibrator.click(x: 126, y: 146, button: 'primary')
    @calibrator.close
    expect(YAML.load_file(File.join(@directory, 'configs/default.yaml')).dig('body_parts', 'head')).to eq([30, 40])
    expect(@host.registry.pages_for(:calibration_fixture)).to be_empty
  end

  def fire_calibration(label, values = {})
    render = @calibrator.page.last_render
    button = render.tree.each.find { |node| node.type == :button && node.props[:label] == label }
    expect(button).not_to be_nil
    submission = render.tree.each.to_h do |node|
      [node.cid, values.fetch(node.props[:key], node.props.key?(:value) ? node.props[:value] : node.props[:checked])]
    end
    render.bindings.fetch([button.cid, :activate]).call(Struct.new(:submission).new(submission))
  end

  after do
    @calibrator&.close
    @dashboard&.close
    @assets&.close
    @host&.stop
    FileUtils.remove_entry(@directory) if @directory
  end

  it 'targets the rendered creature ID and updates only the changed live snapshot without loading GTK' do
    targets = []
    records = [{ id: 42, name: 'a rat', noun: 'rat', family: 'rodent', current_hp: 90,
                 max_hp: 100, injuries: {}, status: [], current: true }]
    @dashboard = @scope::NativeDashboard.new(owner: :creature_fixture, assets: @assets,
                                             config: { 'multi_creature' => { 'max_shown' => 5 }, 'layout' => { 'mode' => 'horizontal', 'max_columns' => 5 } },
                                             creatures: proc { records }, target: proc { |id| targets << id }, save: proc {})
    @dashboard.show
    render = @dashboard.page.last_render
    button = render.tree.each.find { |node| node.type == :button && node.props[:label] == 'Target a rat' }
    render.bindings.fetch([button.cid, :activate]).call(nil)
    expect(targets).to eq([42])
    records.first[:current_hp] = 5
    @dashboard.tick
    hp = @dashboard.page.last_render.tree.each.find { |node| node.props[:key] == 'creature-42-health' }
    expect(hp.props[:layers].first[:value]).to eq(0.05)
    expect($LOADED_FEATURES.grep(%r{/(?:gtk3|gdk3|gdk_pixbuf2)(?:\.rb|/)})).to be_empty
    @dashboard.close
    expect(@host.registry.pages_for(:creature_fixture)).to be_empty
  end

  it 'keeps each calibration variant and false display setting, preserving unknown metadata on save' do
    File.write(@config_path, { 'name_display' => { 'show' => false }, 'vendor_note' => 'retain',
      'body_parts' => { 'head' => [30, 40] } }.to_yaml)
    config = @assets.config('greyscale/town/rat', 'name_display' => { 'show' => true })
    expect(config.dig('name_display', 'show')).to eq(false)
    config['marker_size'] = 18
    @assets.save('greyscale/town/rat', config)
    expect(YAML.load_file(@config_path)).to include('vendor_note' => 'retain', 'marker_size' => 18,
                                                    'body_parts' => { 'head' => [30, 40] })
    expect { @assets.save('../outside', config) }.to raise_error(ArgumentError)
  end

  it 'uses normalized wound coordinates at every scale and bounds invalid health values' do
    config = @assets.config('greyscale/town/rat')
    config.merge!('scale' => 2.0, 'marker_size' => 12, 'body_parts' => { 'head' => [30, 40] })
    creature = { id: 42, name: '<rat>', noun: 'rat', current_hp: 140, max_hp: 100,
                 injuries: { head: 2 }, status: ['stunned'] }
    panel = @scope::NativePanel.new(config: config, assets: @assets.snapshot('greyscale/town/rat'), global: {}, creature: creature)
    marker = panel.image_layers.find { |layer| layer[:src]&.end_with?('rank2.png') }
    expect(marker).to include(x: 60, y: 80, w: 12, h: 12)
    expect(panel.health).to eq(1.0)
    expect(panel.status_text).to include('stunned')
    expect(panel.name).to eq('<rat>')
    expect { panel.image_layers }.not_to(change { File.mtime(@directory) })
  end

  it 'renders the saved name, health and status typography as literal native text' do
    config = @assets.config('default')
    config['name_display']['font_size'] = 18
    config['hp_bar']['font_size'] = 14
    config['status']['font_size'] = 16
    panel = @scope::NativePanel.new(config: config, assets: @assets.snapshot('default'),
                                    global: { 'colors'         => { 'name_font' => '#E01B24', 'hp_text' => '#FFFFFF' },
                                              'status_effects' => [{ 'name' => 'stunned', 'symbol' => 'S', 'color' => '#FFD700' }] },
                                    creature: { name: '<rat>', noun: 'rat', current_hp: 75, max_hp: 100, injuries: {}, status: ['stunned'] })
    page = Lich::WebUI.page(owner: :creature_fixture, id: 'typography', title: 'Typography') { |tree| panel.render(tree, key: 'sample') }
    Lich::WebUI.refresh(page)
    nodes = page.last_render.tree.each.to_a
    expect(nodes.find { |node| node.props[:key] == 'sample-name' }.props)
      .to include(content: '<rat>', font_size: 18, foreground: { r: 224, g: 27, b: 36, a: 1.0 })
    hp = nodes.find { |node| node.props[:key] == 'sample-health' }.props[:layers].find { |layer| layer[:kind] == 'label' }
    expect(hp).to include(font_size: 14, foreground: { r: 255, g: 255, b: 255, a: 1.0 })
    expect(nodes.find { |node| node.props[:key] == 'sample-status-0' }.props)
      .to include(font_size: 16, foreground: { r: 255, g: 215, b: 0, a: 1.0 })
  end

  it 'uses existing composite bars for configured background and target borders' do
    panel = @scope::NativePanel.new(config: @assets.config('default'), assets: @assets.snapshot('default'),
                                    global: { 'colors' => { 'window_background' => '#112233', 'current_target_border' => '#FFD700' } },
                                    creature: { name: 'rat', noun: 'rat', current_hp: 50, max_hp: 100, injuries: {}, status: [], current: true })
    page = Lich::WebUI.page(owner: :creature_fixture, id: 'frame', title: 'Frame') { |tree| panel.render(tree, key: 'sample') }
    Lich::WebUI.refresh(page)
    layers = page.last_render.tree.each.find { |node| node.props[:key] == 'sample-silhouette' }.props[:layers]
    expect(layers.first).to include(kind: 'bar', value: 1.0, tone: { r: 17, g: 34, b: 51, a: 1.0 })
    expect(layers.last(4)).to all(include(kind: 'bar', value: 1.0, tone: { r: 255, g: 215, b: 0, a: 1.0 }))
  end

  it 'copies only display settings and leaves every destination coordinate and metadata intact' do
    File.write(@config_path, { 'body_parts' => { 'head' => [10, 20] }, 'vendor_note' => 'rat' }.to_yaml)
    destination = File.join(@directory, 'configs/default.yaml')
    File.write(destination, { 'body_parts' => { 'head' => [80, 90] }, 'vendor_note' => 'default' }.to_yaml)
    config = @assets.config('greyscale/town/rat').merge('scale' => 1.5)
    result = @assets.copy_display_settings(config)
    expect(result[:errors]).to be_empty
    expect(result[:saved]).to eq(2)
    expect(YAML.load_file(destination)).to include('scale' => 1.5, 'vendor_note' => 'default',
                                                   'body_parts' => { 'head' => [80, 90] })
  end
end
