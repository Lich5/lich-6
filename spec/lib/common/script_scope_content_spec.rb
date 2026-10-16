# frozen_string_literal: true

require_relative '../../spec_helper'
require 'timeout'
require_relative '../../../lib/common/script_scope'
require_relative '../../support/webui_browser'

RSpec.describe 'bounded text, image and menu compatibility' do
  let(:scope) { Lich::Common::ScriptScope }
  let(:owner) { Struct.new(:name).new('pilot.lic') }
  let(:asset_directory) { Dir.mktmpdir('shim-images-') }
  let(:service) { Lich::WebUI::Service.new(application_roots: [asset_directory]) }
  let(:compatibility) { scope.const_get(:Gtk, false) }

  before do
    @core_gtk = [Object, Lich::Common].to_h do |namespace|
      [namespace, namespace.const_defined?(:Gtk, false) ? namespace.const_get(:Gtk, false) : nil]
    end
    scope.activate!
    stub_const('Lich::Common::Script', Class.new { def self.current; end })
    allow(Lich::Common::Script).to receive(:current).and_return(owner)
    allow(Lich::WebUI).to receive(:adapter) { |owner:, viewer: nil| Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer) }
    allow(Lich::WebUI).to receive(:callback_queue) { |owner:| proc { |&work| service.runtime.dispatch(owner: owner, &work) } }
    allow(Lich::WebUI).to receive(:service).and_return(service)
    allow(Lich).to receive(:log)
  end

  after do
    Lich::Common::ScriptDeath.run(owner)
    service.stop
    FileUtils.remove_entry(asset_directory)
  end

  def wait_for(&block)
    Timeout.timeout(3) { sleep 0.005 until block.call }
  end

  def show(window)
    window.show_all
    page = nil
    wait_for { (page = service.registry.pages_for(owner).first)&.last_render }
    page
  end

  def connect(page, id)
    connection = Struct.new(:viewer_id, :messages).new(id, [])
    def connection.alive? = true
    def connection.send_text(text) = messages << JSON.parse(text)
    service.runtime.handle(connection, type: 'attach', page: service.registry.address_for(page))
    connection
  end

  def send_event(page, connection, node, name, payload = {}, submission: nil, **fields)
    render = connection.messages.reverse.find { |message| message['type'] == 'render' }
    message = { type: 'event', page: service.registry.address_for(page), generation: render.fetch('generation'),
                cid: node.cid, event: name, payload: payload.merge(fields) }
    message[:submission] = submission if submission
    service.runtime.handle(connection, message)
  end

  def flatten(node)
    [node] + Array(node['children']).flat_map { |child| flatten(child) }
  end

  def rendered_node(connection, type)
    render = connection.messages.reverse.find { |message| message['type'] == 'render' }
    flatten(render.fetch('tree')).find { |node| node['type'] == type.to_s }
  end

  it 'accepts legacy markup and width setters with bounded named sizes' do
    label = compatibility::Label.new('<b>Ready</b>')
    label.set_use_markup(true)
    label.width_chars = 12
    label.text = "<b><span foreground='#d4af37' size='large'>Gold</span></b>"
    props = label.send(:component_props)
    expect(props).to include(content: 'Gold', min_width_chars: 12)
    expect(props[:fragments].first).to include(emphasis: :strong, scale: 1.2)
    original = props.dup
    ["<span size='huge'>Bad</span>", "<span size='xx-large'><big>Too large</big></span>"].each do |markup|
      expect { label.markup = markup }.to raise_error(compatibility::UnsupportedOperation)
      expect(label.send(:component_props)).to eq(original)
    end
    [0, 1025, 2.5].each do |count|
      expect { label.width_chars = count }.to raise_error(compatibility::UnsupportedOperation)
    end
    window = compatibility::Window.new
    window.add(label)
    page = show(window)
    expect(page.last_render.tree.each.find { |node| node.type == :text }.props[:fragments].first[:scale]).to eq(1.2)
  end

  it 'keeps bounded LinkButton destinations, captions and sensitivity live without accepting executable markup' do
    link = compatibility::LinkButton.new('https://example.org/wiki?x=1&y=2', 'Open <wiki>')
    link.sensitive = false
    window = compatibility::Window.new
    window.add(link)
    page = show(window)
    viewer = connect(page, 'link-button')
    expect(rendered_node(viewer, :markdown)['props']).to include('disabled' => true)
    expect(link.label).to eq('Open <wiki>')
    link.uri = 'https://example.org/new'
    link.label = 'New wiki'
    link.sensitive = true
    wait_for { rendered_node(viewer, :markdown).dig('props', 'disabled') == false }
    expect(rendered_node(viewer, :markdown)['props']['content']).to eq('[New wiki](https://example.org/new)')
    original = link.send(:component_props).dup
    ['javascript:alert(1)', 'file:///tmp/test', 'https://user:secret@example.org', 'https://example.org/ bad'].each do |uri|
      expect { link.uri = uri }.to raise_error(compatibility::UnsupportedOperation)
      expect(link.uri).to eq('https://example.org/new')
      expect(link.send(:component_props)).to eq(original)
    end
    link.sensitive = false
    wait_for { rendered_node(viewer, :markdown).dig('props', 'disabled') == true }
  end

  it 'uses fill allocation and whole-label monospace markup through existing typed properties' do
    entry = compatibility::Entry.new
    entry.halign = :fill
    expect(entry.send(:component_props)[:align]).to eq(:stretch)
    expect { entry.halign = :unknown }.to raise_error(compatibility::UnsupportedOperation)
    label = compatibility::Label.new
    label.override_font(scope::Pango::FontDescription.new('serif 12'))
    label.markup = '<tt> A &lt; B </tt>'
    expect(label.text).to eq(' A < B ')
    expect(label.send(:component_props)[:font_family]).to eq('monospace')
    original = label.send(:component_props).dup
    expect { label.markup = '<tt><script>bad</script></tt>' }.to raise_error(compatibility::UnsupportedOperation)
    expect(label.send(:component_props)).to eq(original)
    label.markup = '<b>Plain</b>'
    expect(label.send(:component_props)[:font_family]).to eq('serif')
  end

  it 'validates fill geometry, live links and directional button callbacks in Chrome', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    window = compatibility::Window.new('Three compatibility controls')
    box = compatibility::Box.new(:vertical, 5)
    grid = compatibility::Grid.new
    4.times { |index| grid.attach(compatibility::Label.new("Column #{index}"), index, 0, 1, 1) }
    entry = compatibility::Entry.new
    entry.hexpand = true
    entry.halign = :fill
    entry.margin_start = 40
    entry.tooltip_text = 'Fill entry'
    grid.attach(entry, 0, 1, 4, 1)
    box.add(grid)
    mono = compatibility::Label.new
    mono.markup = '<tt>Mono caption</tt>'
    box.add(mono)
    link = compatibility::LinkButton.new('https://example.invalid/wiki', 'Open wiki')
    link.sensitive = false
    box.add(link)
    select = compatibility::Button.new('Select spell')
    select.signal_connect('clicked') do
      link.uri = 'https://example.invalid/spell'
      link.label = 'Open selected wiki'
      link.sensitive = true
    end
    clear = compatibility::Button.new('Clear selection')
    clear.signal_connect('clicked') { link.sensitive = false }
    box.add(select)
    box.add(clear)
    order = %w[First Second]
    status = compatibility::Label.new(order.join(', '))
    up, down = compatibility::Button.new, compatibility::Button.new
    up.relief = down.relief = :none
    up.image = compatibility::Image.new(icon_name: 'go-up', icon_size: :button)
    down.image = compatibility::Image.new(icon_name: 'go-down', icon_size: :button)
    up.sensitive = false
    up.signal_connect('clicked') do
      order.reverse!
      up.sensitive = false
      down.sensitive = true
      status.text = order.join(', ')
    end
    down.signal_connect('clicked') do
      order.reverse!
      up.sensitive = true
      down.sensitive = false
      status.text = order.join(', ')
    end
    [up, down, status].each { |widget| box.add(widget) }
    window.add(box)
    WebUIBrowser.check(service: service, page: show(window), scenario: 'three-compatibility')
    expect(order).to eq(%w[First Second])
    expect(link.sensitive?).to be(false)
  end

  it 'updates subclass Frame captions and shadow transitions without replacing child handles' do
    frame = Class.new(compatibility::Frame).new('Initial')
    entry = compatibility::Entry.new
    frame.add(entry)
    frame.set_label_widget(compatibility::Label.new('Copied'))
    expect(frame.label).to eq('Copied')
    frame.shadow_type = :none
    frame.set_shadow_type(:in)
    window = compatibility::Window.new
    window.add(frame)
    page = show(window)
    viewer = connect(page, 'frame-caption')
    original_child = rendered_node(viewer, :text_input)['cid']
    frame.label = 'Updated'
    wait_for { rendered_node(viewer, :group).dig('props', 'label') == 'Updated' }
    expect(rendered_node(viewer, :group)['props']['border_width']).to eq(1)
    expect(rendered_node(viewer, :text_input)['cid']).to eq(original_child)
    expect(frame.children).to eq([entry])
    [nil, 42, 'x' * 513, [255].pack('C').force_encoding('UTF-8')].each do |value|
      expect { frame.label = value }.to raise_error(compatibility::UnsupportedOperation)
      expect(frame.label).to eq('Updated')
    end
    %i[out etched_in etched_out unknown].each do |value|
      expect { frame.shadow_type = value }.to raise_error(compatibility::UnsupportedOperation)
      expect(frame.send(:component_props)[:border_width]).to eq(1)
    end
    frame.set_label('')
    wait_for { rendered_node(viewer, :group).dig('props', 'label') == '' }
    expect(frame.label).to eq('')
  end

  it 'bounds ButtonBox layout and live spacing without replacing button identities' do
    expect { compatibility::ButtonBox.new(:vertical) }.to raise_error(compatibility::UnsupportedOperation)
    footer = compatibility::ButtonBox.new(:horizontal)
    footer.layout = :end
    footer.spacing = 10
    first = compatibility::Button.new('Save')
    footer.add(first)
    window = compatibility::Window.new
    window.add(footer)
    viewer = connect(show(window), 'footer')
    original = rendered_node(viewer, :button)['cid']
    second = compatibility::Button.new('Cancel')
    footer.add(second)
    footer.set_spacing(12)
    wait_for { rendered_node(viewer, :grid).dig('props', 'gap') == 12 }
    expect(rendered_node(viewer, :grid)['props']).to include('cols' => 2, 'align' => 'end', 'expand_columns' => [])
    expect(rendered_node(viewer, :button)['cid']).to eq(original)
    expect(footer.children).to eq([first, second])
    [:start, :spread, nil].each do |value|
      expect { footer.layout = value }.to raise_error(compatibility::UnsupportedOperation)
      expect(footer.layout).to eq(:end)
    end
    [-1, 65, 1.5, '10', nil].each do |value|
      expect { footer.spacing = value }.to raise_error(compatibility::UnsupportedOperation)
      expect(footer.spacing).to eq(12)
    end
    footer.remove(second)
    wait_for { rendered_node(viewer, :grid).dig('props', 'cols') == 1 }
    expect(first.parent).to equal(footer)
  end

  it 'renders end-aligned ButtonBox actions and empty named combo choices in Chrome', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    window = compatibility::Window.new('ButtonBox and empty IDs')
    box = compatibility::Box.new(:vertical, 4)
    combo = compatibility::ComboBoxText.new
    combo.append('', '-- select spell --')
    combo.append('spell', 'Spell')
    combo.active = 0
    status = compatibility::Label.new('Ready')
    combo.signal_connect('changed') { status.text = "Choice: #{combo.active_id.inspect}" }
    footer = compatibility::ButtonBox.new(:horizontal)
    footer.layout = :end
    footer.spacing = 10
    save = compatibility::Button.new('Save & Close')
    save.signal_connect('clicked') do
      footer.spacing = 18
      combo.append('extra', 'Extra')
      status.text = "Saved: #{combo.active_id.inspect}"
    end
    cancel = compatibility::Button.new('Cancel')
    cancel.signal_connect('clicked') { combo.active_id = ''; status.text = "Reset: #{combo.active_id.inspect}" }
    footer.add(save)
    footer.add(cancel)
    box.add(combo)
    box.add(status)
    box.pack_end(footer, expand: false, fill: false, padding: 10)
    window.add(box)
    WebUIBrowser.check(service: service, page: show(window), scenario: 'buttonbox-empty-id')
    expect(footer.spacing).to eq(18)
    expect(combo.active_id).to eq('')
  end

  it 'normalizes only omitted or nil scroller adjustments and preserves the existing facade' do
    [compatibility::ScrolledWindow.new, compatibility::ScrolledWindow.new(nil, nil)].each do |scroll|
      expect(scroll.vadjustment).to be_a(compatibility::ScrollAdjustment)
      original = scroll.vadjustment
      scroll.shadow_type = compatibility::SHADOW_IN
      expect(scroll.vadjustment).to equal(original)
      expect(compatibility::SHADOW_IN).to eq(:in)
    end
    [[Object.new, nil], [nil, Object.new]].each do |arguments|
      expect { compatibility::ScrolledWindow.new(*arguments) }.to raise_error(compatibility::UnsupportedOperation)
    end
    expect(service.registry.pages_for(owner)).to be_empty
  end

  it 'preserves frame captions, borders and input drafts through live updates in Chrome', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    window = compatibility::Window.new('Frame and scroller compatibility')
    box = compatibility::Box.new(:vertical, 4)
    frame = compatibility::Frame.new('Initial frame')
    entry = compatibility::Entry.new
    entry.tooltip_text = 'Draft entry'
    frame.add(entry)
    frame.shadow_type = :in
    scroll = compatibility::ScrolledWindow.new(nil, nil)
    scroll.shadow_type = compatibility::SHADOW_IN
    scroll.add(frame)
    box.add(scroll)
    status = compatibility::Label.new('No submit')
    entry.signal_connect('activate') { status.text = "Submitted: #{entry.text}" }
    actions = {
      'Rename frame'   => proc { frame.label = 'Updated frame' },
      'Remove border'  => proc { frame.shadow_type = :none },
      'Restore border' => proc { frame.shadow_type = :in },
      'Empty caption'  => proc { frame.set_label('') }
    }
    actions.each do |caption, action|
      button = compatibility::Button.new(caption)
      button.signal_connect('clicked', &action)
      box.add(button)
    end
    box.add(status)
    window.add(box)
    WebUIBrowser.check(service: service, page: show(window), scenario: 'frame-scroller')
    expect(frame.label).to eq('')
    expect(entry.text).to eq('Retained draft')
    expect(status.text).to eq('Submitted: Retained draft')
  end

  it 'preserves nested and mixed label styles as literal fragments and clears them on a live text replacement' do
    label = compatibility::Label.new
    label.markup = '<b>Attack &amp; defend</b>  <i>(optional)</i>'
    window = compatibility::Window.new
    window.add(label)
    page = show(window)
    viewer = connect(page, 'mixed-label')
    props = rendered_node(viewer, :text)['props']
    expect(label.text).to eq('Attack & defend  (optional)')
    expected = [
      { 'content' => 'Attack & defend', 'emphasis' => 'strong' },
      { 'content' => '  ' }, { 'content' => '(optional)', 'font_style' => 'italic' }
    ]
    expect(props['fragments']).to eq(expected)
    label.markup = "<small><i><span foreground='#888888'>A &lt; B</span></i></small>"
    wait_for { rendered_node(viewer, :text).dig('props', 'content') == 'A < B' }
    fragment = rendered_node(viewer, :text)['props']['fragments'].first
    expect(fragment).to include('font_style' => 'italic', 'foreground' => { 'r' => 136, 'g' => 136, 'b' => 136, 'a' => 1.0 })
    expect(fragment['scale']).to be_within(0.001).of(1 / 1.2)
    label.text = 'Plain replacement'
    wait_for { rendered_node(viewer, :text).dig('props', 'content') == 'Plain replacement' }
    expect(rendered_node(viewer, :text)['props']).not_to have_key('fragments')
  end

  it 'maps foreground warning spans and use-markup initialization without leaking color into later markup' do
    label = compatibility::Label.new('<span foreground="black">12</span>')
    label.use_markup = true
    expect(label.text).to eq('12')
    expect(label.send(:component_props)[:fragments].first[:foreground]).to eq(r: 0, g: 0, b: 0, a: 1.0)
    label.markup = '<span foreground="#ffbf40" weight="bold">Cleric-only &amp; ready</span>'
    expect(label.send(:component_props)[:fragments].first).to include(emphasis: :strong, foreground: { r: 255, g: 191, b: 64, a: 1.0 })
    label.markup = '<span color="blue" weight="bold">Tip</span>'
    label.markup = '<b>Normal heading</b>'
    expect(label.send(:component_props).keys & %i[foreground fragments]).to be_empty
  end

  it 'rejects malformed, executable and excessive inline markup before changing a live label' do
    label = compatibility::Label.new
    label.markup = '<b>Retained</b><i> style</i>'
    window = compatibility::Window.new
    window.add(label)
    show(window)
    original = label.send(:component_props).dup
    [
      '<i>unclosed', '<i><script>bad</script></i>', '<i onclick="bad">bad</i>',
      '<i><span foreground="url(x)">bad</span></i>', '<i><span foreground="red" style="color:red">bad</span></i>',
      '<i><!--comment--></i>', '<i><?instruction bad?></i>',
      '<!DOCTYPE label [<!ENTITY x "bad">]><i>&x;</i>',
      '<i>' * 17 + 'deep' + '</i>' * 17,
      '<b>x</b><i>y</i>' * 257,
      '<i>' + 'x' * 65_537 + '</i>', '<i>'.b + [255].pack('C') + '</i>'.b
    ].each do |markup|
      expect { label.markup = markup }.to raise_error(compatibility::UnsupportedOperation)
      expect(label.send(:component_props)).to eq(original)
    end
    expect { label.text = 'x' * 65_537 }.to raise_error(Lich::WebUI::SchemaViolationError)
    expect(label.send(:component_props)).to eq(original)
  end

  it 'supports bounded size-only font descriptions while retaining the theme family' do
    pango = scope.const_get(:Pango)
    label = compatibility::Label.new('Timer')
    label.override_font(pango::FontDescription.new('12.5'))
    expect(label.send(:component_props)).to include(font_size: 12.5, font_unit: :pt)
    expect(label.send(:component_props)).not_to have_key(:font_family)
    expect(pango::FontDescription.from_string('14').properties).to eq(font_size: 14.0, font_unit: :pt)
    ['5', '49', '-12', 'NaN', 'Infinity', '12px', '0' * 513].each do |value|
      expect { pango::FontDescription.new(value) }.to raise_error(compatibility::UnsupportedOperation)
    end
  end

  it 'caps label width and requests end ellipsis without shortening the retained content' do
    label = compatibility::Label.new('A long service bonus description')
    expect(label.set_max_width_chars(40).set_ellipsize(:end)).to equal(label)
    window = compatibility::Window.new
    window.add(label)
    show(window)
    label.max_width_chars = 20
    label.ellipsize = :end
    expect(label.session.port.get(label.materialize, :max_width_chars)).to eq(20)
    expect(label.session.port.get(label.materialize, :ellipsize)).to eq('end')
    expect(label.text).to eq('A long service bonus description')
    [0, -1, 1025, 1.5, '40'].each do |width|
      expect { label.set_max_width_chars(width) }.to raise_error(compatibility::UnsupportedOperation)
    end
    expect { label.set_ellipsize(:start) }.to raise_error(compatibility::UnsupportedOperation)
    linked = compatibility::Label.new
    linked.markup = '<a href="https://example.com">Help</a>'
    expect { linked.set_max_width_chars(20) }.to raise_error(compatibility::UnsupportedOperation)
    expect { linked.set_ellipsize(:end) }.to raise_error(compatibility::UnsupportedOperation)
    capped = compatibility::Label.new
    capped.set_max_width_chars(20)
    expect { capped.markup = '<a href="https://example.com">Help</a>' }.to raise_error(compatibility::UnsupportedOperation)
  end

  it 'renders shared combo entry widths, text assignment and tooltip readback in Chrome', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    window = compatibility::Window.new('Priority 14 controls')
    box = compatibility::Box.new(:vertical)
    box.tooltip_text = 'Container help'
    row = compatibility::Box.new(:horizontal)
    row.tooltip_text = 'Horizontal help'
    row.add(compatibility::Label.new('Horizontal caption'))
    profile = compatibility::ComboBoxText.new(entry: true)
    profile.append_text('Profile A')
    profile.append_text('Profile B')
    profile.margin = 20
    profile.child.margin_start = 12
    profile.child.margin_top = 3
    profile.child.width_request = 400
    profile.child.tooltip_text = 'Profile name'
    profile.active_text = 'Profile A'
    material = compatibility::ComboBoxText.new
    %w[bronze iron].each { |text| material.append_text(text) }
    material.active_text = 'bronze'
    material.set_tooltip_text('Material help') unless material.tooltip_text
    status = compatibility::Label.new('Ready')
    update = compatibility::Button.new('Update controls')
    update.signal_connect('clicked') do
      material.active_text = 'iron'
      profile.child.margin = 0
      profile.child.width_request = 320
      profile.child.tooltip_text = 'Updated profile'
      status.text = "#{profile.child.get_tooltip_text} / #{material.active_text}"
    end
    [row, profile, material, status, update].each { |child| box.add(child) }
    window.add(box)
    WebUIBrowser.check(service: service, page: show(window), scenario: 'priority14-controls')
    expect(status.text).to eq('Updated profile / iron')
  end

  it 'renders mixed inline styles and real end truncation in Chrome', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'
    window = compatibility::Window.new('Priority 11 labels')
    box = compatibility::Box.new(:vertical)
    mixed = compatibility::Label.new
    mixed.markup = '<b>Attack</b>  <i>(optional)</i>'
    mixed.set_max_width_chars(40)
    mixed.set_line_wrap(true)
    warning = compatibility::Label.new
    warning.markup = '<span foreground="#ffbf40" weight="bold" size="large">Cleric-only</span>'
    bonus = compatibility::Label.new('A long service bonus description ' * 8)
    bonus.set_width_request(180)
    bonus.set_max_width_chars(20)
    bonus.set_ellipsize(:end)
    reset = compatibility::Button.new('Reset label')
    reset.signal_connect('clicked') { mixed.text = 'Plain replacement' }
    [mixed, warning, bonus, reset].each { |child| box.add(child) }
    window.add(box)
    WebUIBrowser.check(service: service, page: show(window), scenario: 'priority11-labels')
    expect(mixed.text).to eq('Plain replacement')
  end

  it 'replaces, inserts and deletes literal Unicode text and refuses foreign or out-of-range iterators' do
    buffer = compatibility::TextBuffer.new
    seen = []
    buffer.signal_connect('changed') { seen << buffer.text }
    accent = [233].pack('U')
    buffer.text = "#{accent}\n<literal>"
    expect(buffer.char_count).to eq(11)
    expect(buffer.get_iter_at_line(1).offset).to eq(2)
    buffer.insert(buffer.get_iter_at_offset(1), '!')
    buffer.delete(buffer.get_iter_at_offset(2), buffer.end_iter)
    expect(buffer.get_text).to eq("#{accent}!")
    buffer.text = ''
    expect(seen).to eq(["#{accent}\n<literal>", "#{accent}!\n<literal>", "#{accent}!", ''])
    expect { buffer.insert(compatibility::TextBuffer.new.end_iter, 'wrong') }.to raise_error(compatibility::UnsupportedOperation)
    expect { buffer.get_iter_at_offset(1) }.to raise_error(compatibility::UnsupportedOperation)
    expect { buffer.insert_markup(buffer.end_iter, '<b>lost</b>') }.to raise_error(compatibility::UnsupportedOperation)
  end

  it 'keeps independent buffer ownership and preserves replaced buffers' do
    first = compatibility::TextBuffer.new
    first.text = 'First'
    view = compatibility::TextView.new(first)
    replacement = compatibility::TextBuffer.new
    replacement.text = 'Second'
    view.buffer = replacement
    expect(first.text).to eq('First')
    expect(view.buffer.text).to eq('Second')
    first.text = 'Detached'
    expect(view.buffer.text).to eq('Second')
    expect { compatibility::TextView.new(replacement) }.to raise_error(compatibility::UnsupportedOperation, /bind/)
    expect { replacement.text = 'x' * 65_537 }.to raise_error(compatibility::UnsupportedOperation)
    expect(view.buffer.text).to eq('Second')
  end

  it 'retains bounded read-only log history, replacement and follow-to-end behavior' do
    view = compatibility::TextView.new
    view.buffer.text = 'Before'
    view.editable = false
    expect(view.buffer.text).to eq('Before')
    view.buffer.text = ''
    view.buffer.insert(view.buffer.end_iter, "line\n" * 1001)
    expect(view.buffer.line_count).to eq(1000)
    expect(view.send(:component_type)).to eq(:log)
    expect(view.scroll_to_iter(view.buffer.end_iter, 0.0, true, 0, 0)).to equal(view)
    expect { view.buffer.text = 'x' * 4097 }.to raise_error(compatibility::UnsupportedOperation)
    expect(view.buffer.line_count).to eq(1000)
  end

  it 'keeps editable text and expander state viewer-local and commits them before Save' do
    window = compatibility::Window.new
    expander = compatibility::Expander.new('Options')
    view = compatibility::TextView.new
    view.buffer.text = 'Initial'
    expander.add(view)
    save = compatibility::Button.new('Save')
    observed = Queue.new
    changed = Queue.new
    view.buffer.signal_connect('changed') { view.set_buffer(view.buffer); changed << view.buffer.text }
    expander.signal_connect('notify::expanded') { changed << expander.expanded }
    save.signal_connect('clicked') { observed << [view.buffer.text, expander.expanded]; window.destroy }
    window.add(expander)
    window.add(save)
    page = show(window)
    first, second = connect(page, 'one'), connect(page, 'two')
    input = page.last_render.tree.each.find { |node| node.type == :textarea }
    fold = page.last_render.tree.each.find { |node| node.type == :expander }
    send_event(page, first, input, 'change', value: 'Draft')
    expect(changed.pop(timeout: 2)).to eq('Draft')
    expect(view.buffer.text).to eq('Initial')
    send_event(page, first, fold, 'toggle', open: true)
    expect(changed.pop(timeout: 2)).to be(true)
    wait_for { rendered_node(first, :expander)['props']['open'] }
    expect(rendered_node(second, :expander)['props']['open']).to be(false)
    button = page.last_render.tree.each.find { |node| node.type == :button }
    send_event(page, first, button, 'activate', {}, submission: ['Final text'])
    expect(observed.pop(timeout: 2)).to eq(['Final text', true])
    wait_for { window.destroyed? }
    expect(view.buffer.text).to eq('Final text')
  end

  it 'restores buffer notification context after nested changes and exceptions' do
    buffer = compatibility::TextBuffer.new
    view = compatibility::TextView.new(buffer)
    observed = []
    buffer.signal_connect('changed') do
      observed << buffer.text
      buffer.text = 'Nested' if buffer.text == 'Outer'
      raise 'handler failure' if buffer.text == 'Fail'
    end
    buffer.text = 'Outer'
    expect(observed).to eq(%w[Outer Nested])
    expect { buffer.text = 'Fail' }.to raise_error('handler failure')
    buffer.text = 'Recovered'
    expect(view.buffer.text).to eq('Recovered')
    expect(observed.last).to eq('Recovered')
  end

  it 'refuses browser edits and forged submissions after an editor becomes read-only' do
    window = compatibility::Window.new
    view = compatibility::TextView.new
    view.buffer.text = 'Original'
    save = compatibility::Button.new('Save')
    saved = Queue.new
    save.signal_connect('clicked') { saved << view.buffer.text }
    window.add(view)
    window.add(save)
    page = show(window)
    connection = connect(page, 'reader')
    view.editable = false
    wait_for { rendered_node(connection, :textarea)['props']['read_only'] }
    input = page.last_render.tree.each.find { |node| node.type == :textarea }
    button = page.last_render.tree.each.find { |node| node.type == :button }
    expect(send_event(page, connection, input, 'change', value: 'Forged')).to eq(:refused)
    expect(send_event(page, connection, button, 'activate', {}, submission: ['Forged'])).to eq(:refused)
    expect(saved).to be_empty
    expect(send_event(page, connection, button, 'activate', {}, submission: ['Original'])).to eq(:queued)
    expect(saved.pop(timeout: 2)).to eq('Original')
  end

  it 'reads Pixbuf file metadata through both spellings without creating a page or loading pixels' do
    path = File.join(asset_directory, 'metadata.png')
    File.binwrite(path, [137, 80, 78, 71, 13, 10, 26, 10].pack('C*') + [13].pack('N') + 'IHDR' + [20, 10].pack('NN'))
    [scope::GdkPixbuf::Pixbuf, scope::Gdk::Pixbuf].each do |pixbuf|
      format, width, height = pixbuf.get_file_info(path)
      expect(format.name).to eq('png')
      expect(format).to be_frozen
      expect([width, height]).to eq([20, 10])
      expect(service.registry.pages_for(owner)).to be_empty
    end
    _, width, height = scope::GdkPixbuf::Pixbuf.get_file_info(path)
    image = scope::GdkPixbuf::Pixbuf.new(file: path).scale_simple(width / 2, height / 2)
    expect([image.width, image.height]).to eq([10, 5])
    expect { scope::GdkPixbuf::Pixbuf.get_file_info(nil) }.to raise_error(compatibility::UnsupportedOperation, /get_file_info/)
  end

  it 'authorizes metadata paths before reading bytes and refuses symlink escapes' do
    Dir.mktmpdir('outside-metadata-') do |outside|
      path = File.join(outside, 'outside.png')
      File.binwrite(path, 'unreadable fixture')
      link = File.join(asset_directory, 'linked.png')
      File.symlink(path, link)
      expect(Lich::WebUI::ImageSize).not_to receive(:info)
      [path, link].each do |candidate|
        expect { scope::GdkPixbuf::Pixbuf.get_file_info(candidate) }.to raise_error(Lich::WebUI::Error, /outside/)
      end
    end
  end

  it 'preserves metadata failures for missing, malformed and oversized image files' do
    path = File.join(asset_directory, 'metadata.png')
    expect { scope::GdkPixbuf::Pixbuf.get_file_info(path) }.to raise_error(compatibility::UnsupportedOperation, /operation=file/)
    File.binwrite(path, 'not an image')
    expect { scope::GdkPixbuf::Pixbuf.get_file_info(path) }.to raise_error(ArgumentError, /image header/)
    File.binwrite(path, 'GIF89a' + [0, 10].pack('vv'))
    expect { scope::GdkPixbuf::Pixbuf.get_file_info(path) }.to raise_error(ArgumentError, /dimensions/)
  end

  it 'renders authorized file images, scales without decoding, and clears without a broken source' do
    path = File.join(asset_directory, 'space image.png')
    # PNG signature and IHDR dimensions are enough for the bounded header reader.
    File.binwrite(path, [137, 80, 78, 71, 13, 10, 26, 10].pack('C*') + [13].pack('N') + 'IHDR' + [20, 10].pack('NN'))
    pixbuf = scope::GdkPixbuf::Pixbuf.new(file: path, width: 10, height: 10)
    expect([pixbuf.width, pixbuf.height]).to eq([10, 5])
    scaled = pixbuf.scale_simple(40, 20, :bilinear)
    expect([scaled.width, scaled.height, pixbuf.width]).to eq([40, 20, 10])
    fractional = pixbuf.scale(40.9, 20.1)
    expect([fractional.width, fractional.height]).to eq([40, 20])
    [Float::NAN, Float::INFINITY, -Float::INFINITY, 0.9, 65_536.1, '40'].each do |width|
      expect { pixbuf.scale(width, 20) }.to raise_error(compatibility::UnsupportedOperation)
    end
    expect([pixbuf.width, pixbuf.height]).to eq([10, 5])
    expect { scaled.pixels }.to raise_error(compatibility::UnsupportedOperation)
    expect { pixbuf.scale_simple(0, 5) }.to raise_error(compatibility::UnsupportedOperation)
    window = compatibility::Window.new
    image = compatibility::Image.new(pixbuf: scaled)
    window.add(image)
    page = show(window)
    source = page.last_render.tree.each.find { |node| node.type == :image }.props[:src]
    expect(source).to end_with('/space%20image.png')
    expect(service.file_service.resolve_url(source)).not_to be_nil
    image.clear
    wait_for { page.last_render.tree.each.find { |node| node.type == :image }.props[:src] == '' }
    expect(image.pixbuf).to be_nil
    service.terminate_owner(owner)
    expect(service.file_service.resolve_url(source)).to be_nil
  end

  it 'refuses image paths outside approved roots and never loads a native image library' do
    Dir.mktmpdir('outside-shim-') do |outside|
      path = File.join(outside, 'secret.png')
      File.binwrite(path, 'not read as an image')
      expect { scope::Gdk::Pixbuf.new(path) }.to raise_error(Lich::WebUI::Error, /outside/)
    end
    expect { compatibility::Image.new(file: 'missing.png', pixbuf: Object.new) }.to raise_error(compatibility::UnsupportedOperation)
    expect { scope::GdkPixbuf.const_get(:Loader) }.to raise_error(compatibility::UnsupportedOperation)
  end

  it 'attributes filesystem resolution failures without hiding file-policy refusals' do
    path = File.join(asset_directory, 'missing.png')
    expect { scope::Gdk::Pixbuf.new(path) }
      .to raise_error(compatibility::UnsupportedOperation, /script=pilot\.lic .*operation=file/)
    allow(File).to receive(:realpath).with(path).and_raise(Errno::EACCES)
    expect { scope::Gdk::Pixbuf.new(path) }
      .to raise_error(compatibility::UnsupportedOperation, /operation=file/)
  end

  it 'opens a dynamically created menu only for the originating pointer viewer and dismisses it once' do
    window = compatibility::Window.new
    label = compatibility::Label.new('Choose')
    label.add_events(scope::Gdk::EventMask::BUTTON_PRESS_MASK)
    seen = Queue.new
    menu = nil
    label.signal_connect('button-press-event') do |_widget, event|
      menu = compatibility::Menu.new
      item = compatibility::MenuItem.new('Inspect')
      item.signal_connect('activate') { seen << :activated }
      menu.append(item)
      menu.signal_connect('deactivate') { seen << :dismissed }
      menu.popup(nil, nil, event.button, event.time)
      seen << :opened
    end
    window.add(label)
    page = show(window)
    first, second = connect(page, 'one'), connect(page, 'two')
    node = page.last_render.tree.each.find { |item| item.type == :text }
    send_event(page, first, node, 'pointer_press', x: 120, y: 80, button: 3, time: 1, state: 0)
    expect(seen.pop(timeout: 2)).to eq(:opened)
    wait_for { rendered_node(first, :group)&.dig('props', 'open') }
    expect(rendered_node(first, :group)['props']['popup_position']).to eq([120, 80])
    wait_for { rendered_node(second, :group) }
    expect(rendered_node(second, :group)['props']['open']).to be(false)
    item = page.last_render.tree.each.find { |entry| entry.type == :button }
    send_event(page, first, item, 'activate')
    expect(seen.pop(timeout: 2)).to eq(:activated)
    group = page.last_render.tree.each.find { |entry| entry.type == :group }
    send_event(page, first, group, 'dismiss')
    expect(seen.pop(timeout: 2)).to eq(:dismissed)
    expect { menu.popup_at_pointer }.to raise_error(compatibility::UnsupportedOperation)
    window.destroy
    expect(menu).to be_destroyed
  end

  it 'keeps submenu ownership and ordered check/radio transitions without cross-group mutation' do
    menu = compatibility::Menu.new
    parent = compatibility::MenuItem.new('Nested')
    nested = compatibility::Menu.new
    first = compatibility::RadioMenuItem.new('First', false)
    second = compatibility::RadioMenuItem.new(first, 'Second', false)
    check = compatibility::CheckMenuItem.new('Enabled')
    order = []
    [first, second, check].each do |item|
      nested.append(item)
      item.signal_connect('toggled') { order << [item.label, item.active?] }
    end
    second.signal_connect('activate') { order << :activate }
    parent.submenu = nested
    menu.append(parent)
    second.activate
    expect(order).to eq([['First', false], ['Second', true], :activate])
    expect(check.active?).to be(false)
    expect(nested.toplevel).to equal(menu)
    mnemonic = compatibility::CheckMenuItem.new('Plain', true)
    expect { mnemonic.label = '_Pick' }.to raise_error(compatibility::UnsupportedOperation, /mnemonic/)
    expect(mnemonic.label).to eq('Plain')
    expect { nested.add(menu) }.to raise_error(compatibility::UnsupportedOperation)
    expect { compatibility::Expander.new.add(parent) }.to raise_error(compatibility::UnsupportedOperation)
  end
end
