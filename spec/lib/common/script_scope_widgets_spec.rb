# frozen_string_literal: true

require_relative '../../spec_helper'
require 'timeout'
require_relative '../../../lib/common/script_scope'
require_relative '../../support/webui_browser'

RSpec.describe 'bounded script compatibility pilot' do
  let(:scope) { Lich::Common::ScriptScope }
  let(:owner) { Struct.new(:name).new('pilot.lic') }
  let(:service) { Lich::WebUI::Service.new }
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
    allow(Lich).to receive(:log)
  end

  after do
    Lich::Common::ScriptDeath.run(owner)
    service.stop
  end

  it 'defers Gtk.queue without blocking its caller and preserves nested enqueue order' do
    started, release, returned, delivered = Queue.new, Queue.new, Queue.new, Queue.new
    producer = Thread.new do
      returned << compatibility.queue do
        started << true
        release.pop
        delivered << :first
        compatibility.queue { delivered << :nested }
      end
    end
    expect(started.pop(timeout: 2)).to be(true)
    expect(returned.pop(timeout: 0.2)).to eq(:queued)
    compatibility.queue { delivered << :second }
    release << true
    expect(3.times.map { delivered.pop(timeout: 2) }).to eq(%i[first second nested])
  ensure
    release&.push(true)
    producer&.join(2)
  end

  it 'reports Gtk.queue errors without killing the caller or skipping subsequent work' do
    completed = Queue.new
    [RuntimeError, SyntaxError, SystemExit].each do |error|
      expect(compatibility.queue { raise error, 'script failure' }).to eq(:queued)
    end
    compatibility.queue { completed << true }
    expect(completed.pop(timeout: 2)).to be(true)
    [RuntimeError, SyntaxError, SystemExit].each do |error|
      expect(Lich).to have_received(:log).with(/script=pilot\.lic.*operation=queue.*error=#{error}/)
    end
  end

  it 'cancels pending Gtk.queue blocks on owner termination and refuses late submissions' do
    started, release, stopped, delivered = Queue.new, Queue.new, Queue.new, Queue.new
    compatibility.queue do
      started << true
      release.pop
      service.runtime.terminate_owner(owner)
      stopped << true
    end
    expect(started.pop(timeout: 2)).to be(true)
    compatibility.queue { delivered << :must_not_run }
    release << true
    expect(stopped.pop(timeout: 2)).to be(true)
    expect(delivered).to be_empty
    expect { compatibility.queue {} }.to raise_error(Lich::WebUI::Error, /terminated/)
  ensure
    release&.push(true)
  end

  it 'retains the rejected shim operation without logging arbitrary exception messages' do
    completed = Queue.new
    compatibility.queue { compatibility.const_get(:ProgressBar).new.set_fraction('private value') }
    compatibility.queue { raise 'private exception message' }
    compatibility.queue { completed << true }
    expect(completed.pop(timeout: 2)).to be(true)
    expect(Lich).to have_received(:log).with(/operation=queue.*rejected=class=.*ProgressBar operation=set_fraction/)
    expect(Lich).not_to have_received(:log).with(/private value|private exception message/)
  end

  it 'refuses stopping-owner submissions outside its cleanup thread and never recreates a session' do
    retained = compatibility.session
    allow(owner).to receive(:stopping?).and_return(true)
    expect(compatibility.queue { raise 'must not run' }).to be_nil
    expect(retained.queue { raise 'must not run' }).to be_nil
    Lich::Common::ScriptDeath.run(owner)
    expect(compatibility.queue { raise 'must not run' }).to be_nil
    expect(compatibility.instance_variable_get(:@sessions)).not_to have_key(owner)
  end

  it 'finishes destroy handlers and sibling windows when script cleanup raises' do
    first = compatibility.const_get(:Window).new('First')
    second = compatibility.const_get(:Window).new('Second')
    completed = []
    first.signal_connect('destroy') { raise 'broken cleanup' }
    first.signal_connect('destroy') { completed << :first }
    second.signal_connect('destroy') { completed << :second }

    Lich::Common::ScriptDeath.run(owner)

    expect([first, second]).to all(be_destroyed)
    expect(completed).to eq(%i[first second])
    expect(Lich).to have_received(:log).with(/script=pilot\.lic.*operation=destroy.*RuntimeError/)
  end

  it 'continues session cleanup after a window itself fails to destroy' do
    first = compatibility.const_get(:Window).new('First')
    second = compatibility.const_get(:Window).new('Second')
    allow(first).to receive(:destroy).and_raise(RuntimeError, 'broken window')

    Lich::Common::ScriptDeath.run(owner)

    expect(second).to be_destroyed
    expect(Lich).to have_received(:log).with(/script=pilot\.lic.*operation=destroy.*RuntimeError/)
  end

  it 'retains shim keep-above requests and later changes in the shared page presentation' do
    window = compatibility.const_get(:Window).new('On top')
    window.keep_above = true
    window.show_all
    page = nil
    Timeout.timeout(5) { sleep 0.01 until (page = service.registry.pages_for(owner).first)&.last_render }
    expect(page.last_render.tree.props[:presentation]).to eq(always_on_top: true)
    window.keep_above = false
    Timeout.timeout(5) { sleep 0.01 until page.last_render.tree.props.dig(:presentation, :always_on_top) == false }
    expect { window.keep_above = 'yes' }.to raise_error(scope.const_get(:Gtk)::UnsupportedOperation)
    window.destroy
  end

  %i[detach process_exit].each do |close_path|
    it "saves entry and checkbox drafts through delete_event on #{close_path}" do
      window = compatibility.const_get(:Window).new('Close/save')
      box = compatibility.const_get(:Box).new(:vertical)
      entry = compatibility.const_get(:Entry).new
      check = compatibility.const_get(:CheckButton).new('Enabled')
      entry.text = 'old'
      box.add(entry)
      box.add(check)
      window.add(box)
      saved = Queue.new
      window.signal_connect('delete_event') { saved << [entry.text, check.active?]; false }
      window.show_all
      page = nil
      Timeout.timeout(2) { sleep 0.001 until (page = service.registry.pages_for(owner).first)&.last_render }
      connection = double('connection', viewer_id: 'close-save', alive?: true, send_text: true)
      address = service.registry.address_for(page)
      service.runtime.handle(connection, type: 'attach', page: address)
      page.last_render.tree.each do |component|
        next unless %i[text_input checkbox].include?(component.type)

        service.runtime.handle(connection, type: 'event', page: address, generation: page.generation,
                                           cid: component.cid, event: 'change',
                                           payload: { value: component.type == :checkbox ? true : 'edited' })
      end
      if close_path == :detach
        service.runtime.handle(connection, type: 'detach', page: address, generation: page.generation)
      else
        service.runtime.disconnect(connection)
        service.runtime.browser_closed(page)
      end
      expect(Timeout.timeout(2) { saved.pop }).to eq(['edited', true])
      Timeout.timeout(2) { sleep 0.001 until window.destroyed? }
      expect([entry.text, check.active?]).to eq(['edited', true])
    end
  end

  it 'reports the persisted GTK theme preference and uses it for shim windows' do
    [true, false].each do |dark|
      allow(Lich).to receive(:track_dark_mode).and_return(dark)
      settings = compatibility.const_get(:Settings).default
      expect(settings.gtk_application_prefer_dark_theme?).to be(dark)
      window = compatibility.const_get(:Window).new('Theme')
      window.add(compatibility.const_get(:Label).new(dark ? 'Dark palette' : 'Light palette'))
      window.show_all
      page = nil
      Timeout.timeout(5) { sleep 0.01 until (page = service.registry.pages_for(owner).last)&.last_render }
      expect(page.last_render.tree.props[:theme]).to eq(dark ? 'dark' : 'light')
      window.destroy
    end
  end

  it 'preserves absent, empty and named GTK frame labels in the shared group contract' do
    window = compatibility.const_get(:Window).new('Frames')
    box = compatibility.const_get(:Box).new(:vertical)
    frame_class = compatibility.const_get(:Frame)
    frames = [frame_class.new, frame_class.new(nil), frame_class.new(''), frame_class.new('Named'), frame_class.new]
    frames.last.set_label_widget(compatibility.const_get(:Label).new(''))
    frames.each { |frame| box.add(frame) }
    window.add(box)
    window.show_all
    page = nil
    Timeout.timeout(5) { sleep 0.01 until (page = service.registry.pages_for(owner).first)&.last_render }
    groups = page.last_render.tree.each.select { |node| node.type == :group }
    expect(groups.map { |node| node.props.key?(:label) }).to eq([false, false, true, true, true])
    expect(groups.map { |node| node.props[:label] }).to eq([nil, nil, '', 'Named', ''])
    window.destroy
  end

  it 'resolves GTK 3 and availability only within script bindings' do
    [scope.script_binding, scope.untrusted_binding].each do |binding|
      expect(eval('Gtk::Version::MAJOR', binding)).to eq(3)
      expect(eval("Gtk::Version::STRING.chr == '3'", binding)).to be(true)
      expect(eval('HAVE_GTK', binding)).to be(true)
    end
    # The shim exposes only lexical compatibility constants; it must not
    # introduce GTK constants into the core namespace.
    @core_gtk.each do |namespace, original|
      if original
        expect(namespace.const_get(:Gtk, false)).to equal(original)
        expect(compatibility).not_to equal(original)
      else
        expect(namespace.const_defined?(:Gtk, false)).to be(false)
      end
    end
  end

  it 'refuses unmapped classes, methods and signals with owner and source attribution' do
    expect { eval('Gtk::UnsupportedWidget', scope.script_binding, 'pilot.lic', 12) }
      .to raise_error(StandardError, /script=pilot.lic.*operation=UnsupportedWidget.*pilot.lic:12/)
    expect { eval('Gtk::Entry.new.invented', scope.script_binding, 'pilot.lic', 18) }
      .to raise_error(StandardError, /class=.*Entry.*operation=invented.*pilot.lic:18/)
    expect { eval("Gtk::Entry.new.signal_connect('invented') {}", scope.script_binding, 'pilot.lic', 24) }
      .to raise_error(StandardError, /operation=signal:invented.*pilot.lic:24/)
  end

  it 'emits the deprecation notice once per script session' do
    2.times { compatibility.queue { compatibility.const_get(:Entry).new } }
    expect(Lich).to have_received(:log).with(/legacy GTK compatibility is deprecated/).once
  end

  it 'keeps reads and chained metadata writes valid after window destruction' do
    window = compatibility.const_get(:Window).new
    entry = compatibility.const_get(:Entry).new
    expect(entry.set_tooltip_text('Example').set_width_request(100)).to equal(entry)
    window.add(entry)
    window.show_all
    window.destroy
    entry.text = 'after'
    expect(entry.text).to eq('after')
    expect(entry).to be_destroyed
    expect(window.session.instance_variable_get(:@windows)).to be_empty
  end

  it 'preserves values while hiding content and maps legacy form setter spellings' do
    window = compatibility::Window.new
    grid = compatibility::Grid.new
    label = compatibility::Label.new('Long label')
    entry = compatibility::SearchEntry.new
    expect(label.set_halign(:end).set_line_wrap(true)).to equal(label)
    expect(entry.set_placeholder_text('Find a name').set_text('retained')).to equal(entry)
    entry.set_margin_start(20)
    grid.set_row_spacing(6).set_column_spacing(12)
    grid.attach(label, 0, 0, 1, 1)
    grid.attach(entry, 1, 0, 1, 1)
    window.add(grid)
    window.set_keep_above(true)
    window.show_all
    entry.hide
    handle = entry.instance_variable_get(:@handle)
    expect(entry.session.port.get(handle, :hidden)).to be(true)
    expect(entry.text).to eq('retained')
    entry.show
    expect(entry.session.port.get(handle, :hidden)).to be(false)
    expect(entry.session.port.get(handle, :search)).to be(true)
    expect(entry.session.port.get(handle, :placeholder)).to eq('Find a name')
    expect { window.hide }.to raise_error(compatibility::UnsupportedOperation, /operation=hide/)
    expect(window).not_to be_destroyed
  end

  it 'disables and restores literal legacy tooltips without losing the registered text' do
    tips = compatibility::Tooltips.new.enable
    window = compatibility::Window.new
    entry = compatibility::Entry.new
    window.add(entry)
    expect(tips.set_tip(entry, '<literal tip>', '')).to equal(tips)
    window.show_all
    handle = entry.instance_variable_get(:@handle)
    expect(entry.session.port.get(handle, :tooltip)).to eq('<literal tip>')
    expect(tips.disable).to equal(tips)
    expect(entry.session.port.get(handle, :tooltip)).to eq('')
    tips.set_tip(entry, 'Replacement')
    expect(entry.session.port.get(handle, :tooltip)).to eq('')
    tips.enable
    expect(entry.session.port.get(handle, :tooltip)).to eq('Replacement')
    expect { tips.set_tip(entry, 'Tip', 'private help') }.to raise_error(compatibility::UnsupportedOperation)
    tips.set_tip(entry, nil)
    expect(entry.session.port.get(handle, :tooltip)).to eq('')
  end

  it 'normalizes close signal spelling and stops at the first veto without destroying the window' do
    window = compatibility::Window.new
    order = []
    window.signal_connect('delete-event') { order << :first; false }
    window.signal_connect('delete_event') { order << :veto; true }
    window.signal_connect('delete-event') { order << :unreachable; false }
    window.show_all
    page = nil
    Timeout.timeout(2) { sleep 0.001 until (page = service.registry.pages_for(owner).first)&.last_render }
    service.runtime.browser_closed(page)
    Timeout.timeout(2) { sleep 0.001 until order.include?(:veto) }
    expect(order).to eq(%i[first veto])
    expect(window).not_to be_destroyed
  end

  it 'keeps shim entry and checkbox defaults in legacy boxes while accepting browser values', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    window = compatibility.const_get(:Window).new('Shim entry width')
    entry = compatibility.const_get(:Entry).new
    checkbox = compatibility.const_get(:CheckButton).new('Shim checked')
    content = compatibility.const_get(:VBox).new(false, 5)
    row = compatibility.const_get(:HBox).new(false, 5)
    content.pack_start(checkbox)
    row.pack_start(entry, true, true, 0)
    content.pack_start(row, false, false, 0)
    frame = compatibility.const_get(:Frame).new('')
    frame.add(content)
    entry.signal_connect('activate') { window.destroy }
    window.add(frame)
    window.show_all
    page = nil
    Timeout.timeout(5) { sleep 0.01 until (page = service.registry.pages_for(owner).first)&.last_render }
    expect(page.last_render.tree.props).to include(theme: 'light', density: 'compact')
    input = page.last_render.tree.each.find { |node| node.type == :text_input }
    expect(input.props).to include(change_mode: 'input')
    expect(input.props.keys).not_to include(:width, :min_width, :control_width, :control_width_chars,
                                            :min_width_chars, :max_width_chars)
    expect(page.last_render.tree.each.find { |node| node.type == :checkbox }.props).to include(label: 'Shim checked')
    expect(page.last_render.tree.each.find { |node| node.type == :group }.props).to include(label: '')
    WebUIBrowser.check(service: service, page: page, scenario: 'shim-entry')
    expect(window).to be_destroyed
    expect(entry.text).to eq('shim value')
    expect(checkbox.active?).to be(true)
  end

  it 'renders the accepted horizontal Gtk::Separator with the shared compact divider', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    window = compatibility.const_get(:Window).new('Shim separator')
    content = compatibility.const_get(:Box).new(:vertical)
    content.pack_start(compatibility.const_get(:Label).new('Before'))
    content.pack_start(compatibility.const_get(:Separator).new(:horizontal), expand: false, fill: true)
    entry = compatibility.const_get(:Entry).new
    entry.signal_connect('activate') { window.destroy }
    content.pack_start(entry)
    window.add(content)
    window.show_all
    page = nil
    Timeout.timeout(5) { sleep 0.01 until (page = service.registry.pages_for(owner).first)&.last_render }
    expect(page.last_render.tree.each.count { |node| node.type == :divider }).to eq(1)
    WebUIBrowser.check(service: service, page: page, scenario: 'shim-separator')
    expect(window).to be_destroyed
    expect(entry.text).to eq('shim separator')
  end

  it 'reports repeated packing without duplicating the widget or its controls' do
    box = compatibility.const_get(:Box).new(:vertical)
    child = compatibility.const_get(:Box).new(:horizontal)
    child.add(compatibility.const_get(:Entry).new)
    box.pack_start(child)
    expect(box.pack_start(child)).to equal(box)
    expect(box.children).to eq([child])
    expect(Lich).to have_received(:log).with(/script=pilot.lic.*operation=add.*already packed/).once
    window = compatibility.const_get(:Window).new
    window.add(box)
    expect { window.show_all }.not_to raise_error
  end

  it 'keeps shadow metadata unchanged when the port refuses a visible widget mutation' do
    window = compatibility.const_get(:Window).new
    entry = compatibility.const_get(:Entry).new
    entry.text = 'valid'
    window.add(entry)
    window.show_all
    expect { entry.text = 'x' * 8193 }.to raise_error(Lich::WebUI::Error)
    expect(entry.text).to eq('valid')
  end

  it 'grows a visible horizontal box when another child is packed' do
    window = compatibility.const_get(:Window).new
    box = compatibility.const_get(:Box).new(:horizontal)
    box.pack_start(compatibility.const_get(:Label).new('First'))
    window.add(box)
    window.show_all
    box.pack_end(compatibility.const_get(:Label).new('Second'))
    handle = box.instance_variable_get(:@handle)
    expect(box.session.port.get(handle, :cols)).to eq(2)
  end

  it 'accepts the numeric orientation used by sloot and rejects unknown enum values' do
    window = compatibility.const_get(:Window).new
    vertical = compatibility.const_get(:Box).new(1)
    horizontal = compatibility.const_get(:Box).new(0)
    vertical.add(horizontal)
    window.add(vertical)
    expect { window.show_all }.not_to raise_error
    expect(vertical.send(:component_type)).to eq(:stack)
    expect(horizontal.send(:component_type)).to eq(:grid)
    expect { compatibility.const_get(:Box).new(2) }.to raise_error(StandardError, /operation=new/)
  end

  { HBox: :grid, VBox: :stack }.each do |name, type|
    it "renders legacy #{name} defaults and positional spacing through shared controls" do
      window = compatibility.const_get(:Window).new
      outer = compatibility.const_get(name).new
      inner = compatibility.const_get(name).new(false, 5)
      first, last = %w[First Last].map { |text| compatibility.const_get(:Label).new(text) }
      inner.pack_start(first, false, false, 0)
      inner.pack_end(last, true, true, 0)
      outer.add(inner)
      window.add(outer)
      window.show_all
      page = nil
      Timeout.timeout(2) { sleep 0.001 until (page = service.registry.pages_for(owner).first)&.last_render }
      containers = page.last_render.tree.each.select { |node| node.type == type }
      expect(containers.map { |node| node.props[:gap] }).to eq([0, 5])
      expect(inner.children).to eq([first, last])
      expect(containers.last.children.map { |node| node.props[:content] }).to eq(%w[First Last])
      expect(containers.last.props[:cols]).to eq(2) if name == :HBox
    end

    it "refuses unsupported #{name} homogeneity before creating a page" do
      [true, nil, 0, 'false'].each do |homogeneous|
        expect { compatibility.const_get(name).new(homogeneous, 5) }
          .to raise_error(compatibility::UnsupportedOperation, /class=.*#{name}.*operation=new/)
      end
      expect(service.registry.pages_for(owner)).to be_empty
    end
  end

  it 'renders armor chart markup as plain text and refuses executable or unknown tags' do
    label = compatibility.const_get(:Label).new
    label.set_markup("<b><span color='red' font_desc='Courier Bold 15'>Armor &amp; Ranks</span></b>")
    expect(label.text).to eq('Armor & Ranks')
    expect { label.set_markup('<img src=x onerror=alert(1)>') }.to raise_error(StandardError, /set_markup/)
    expect { label.set_markup('<span onclick="alert(1)">bad</span>') }.to raise_error(StandardError, /set_markup/)
  end

  it 'refuses cross-owner children, implicit reparenting and ancestor cycles before rendering' do
    outer = compatibility.const_get(:Box).new
    inner = compatibility.const_get(:Box).new
    outer.add(inner)
    expect { inner.add(outer) }.to raise_error(StandardError, /operation=add/)
    expect { outer.add(outer) }.to raise_error(StandardError, /operation=add/)
    expect { compatibility.const_get(:Box).new.add(inner) }.to raise_error(StandardError, /operation=add/)

    other_owner = Struct.new(:name).new('other.lic')
    allow(Lich::Common::Script).to receive(:current).and_return(other_owner)
    foreign = compatibility.const_get(:Entry).new
    expect { outer.add(foreign) }.to raise_error(StandardError, /operation=add/)
    Lich::Common::ScriptDeath.run(other_owner)
  end

  it 'keeps disabled input values and maps the measured bold tip without allowing HTML' do
    entry = compatibility.const_get(:Entry).new
    entry.text = 'preserved'
    expect(entry.set_sensitive(false)).to equal(entry)
    expect(entry.sensitive?).to be(false)
    expect(entry.text).to eq('preserved')

    label = compatibility.const_get(:Label).new
    label.set_markup('<span color="blue" weight="bold">Tip &amp; help</span>')
    expect(label.text).to eq('Tip & help')
    expect(label.send(:component_props)[:foreground]).to eq(r: 0, g: 0, b: 255, a: 1.0)
    expect { label.set_markup('<img src=x onerror=alert(1)>') }.to raise_error(StandardError, /set_markup/)
  end

  it 'appends an editable row to a visible table without rebuilding prior widgets' do
    table = compatibility.const_get(:Table).new(1, 3)
    first = compatibility.const_get(:Entry).new
    table.attach(first, 0, 2, 0, 1)
    window = compatibility.const_get(:Window).new
    window.add(table)
    window.show_all
    table.n_rows = 2
    second = compatibility.const_get(:Entry).new
    expect(table.attach(second, 0, 1, 1, 2)).to equal(table)
    expect(table.children).to eq([first, second])
    expect(first.parent).to equal(table)
    expect { table.attach(compatibility.const_get(:Entry).new, -1, 1, 0, 1) }
      .to raise_error(StandardError, /attach/)
  end

  it 'keeps immutable scroll reports separate from requested animation positions' do
    scroll = compatibility.const_get(:ScrolledWindow).new
    adjustment = scroll.vadjustment
    report = { position: 10, upper: 400, page_size: 100 }.freeze
    adjustment.observe(nil, report)
    adjustment.value = 20.5
    expect(adjustment.value).to eq(21)
    expect(report[:position]).to eq(10)
    expect(adjustment.upper - adjustment.page_size).to eq(300)
  end

  it 'keeps GTK combo indices stable across duplicate labels and removal' do
    combo = compatibility.const_get(:ComboBoxText).new
    combo.append_text('One').append_text('One').append_text('Three')
    expect(combo.active).to eq(-1)
    combo.active = 1
    expect(combo.active_text).to eq('One')
    combo.remove(0)
    expect(combo.active).to eq(0)
    expect(combo.active_text).to eq('One')
    combo.remove(0)
    expect(combo.active).to eq(-1)
    expect(combo.active_text).to be_nil
    expect { combo.active = 20 }.to raise_error(StandardError, /active=/)
    combo.remove_all
    expect(combo.active_text).to be_nil
    combo.append_text('Replacement')
    combo.active = 0
    expect(combo.active_text).to eq('Replacement')
  end

  it 'supports the measured ecure numeric range without silently clamping' do
    spin = compatibility.const_get(:SpinButton).new(0, 3, 1)
    spin.value = 2.0
    expect(spin.value).to eq(2.0)
    expect { spin.value = 4 }.to raise_error(StandardError, /value=/)
    window = compatibility.const_get(:Window).new
    window.add(spin)
    expect { window.show_all }.not_to raise_error
  end

  it 'preserves localchat text and validates buffer ranges without interpreting markup' do
    view = compatibility.const_get(:TextView).new
    view.editable = false
    buffer = view.buffer
    buffer.insert(buffer.end_iter, "Friend says, \"<script>hello</script>\"\n")
    expect(buffer.end_iter.offset).to eq(38)
    expect(view.send(:component_props)[:lines]).to eq(['Friend says, "<script>hello</script>"', ''])
    tag = compatibility.const_get(:TextTag).new
    tag.foreground = '#ff0000'
    buffer.tag_table.add(tag)
    expect { buffer.apply_tag(tag, buffer.get_iter_at_offset(0), buffer.end_iter) }.not_to raise_error
    expect { buffer.get_iter_at_offset(-1) }.to raise_error(StandardError, /get_iter_at_offset/)
    other = compatibility.const_get(:TextView).new.buffer
    expect { buffer.insert(other.end_iter, 'foreign') }.to raise_error(StandardError, /insert/)
  end

  it 'renders spell progress with its overlay label and clamps overflow fractions' do
    window = compatibility.const_get(:Window).new
    row = compatibility.const_get(:Paned).new(:horizontal)
    overlay = compatibility.const_get(:Overlay).new
    progress = compatibility.const_get(:ProgressBar).new
    progress.set_fraction(0.5)
    overlay.add(progress)
    overlay.add_overlay(compatibility.const_get(:Label).new('Spell'))
    row.add1(compatibility.const_get(:Label).new('30 seconds'))
    row.add2(overlay)
    window.add(row)
    expect { window.show_all }.not_to raise_error
    { 1.1 => 1.0, -0.1 => 0.0, Float::INFINITY => 1.0, -Float::INFINITY => 0.0 }.each do |input, expected|
      expect(progress.set_fraction(input)).to equal(progress)
      expect(progress.send(:component_props)[:value]).to eq(expected)
    end
    expect { progress.set_fraction('invalid') }.to raise_error(StandardError, /set_fraction/)

    # Indefinite effects can divide a positive remaining time by zero. The
    # existing script must still reach its subsequent duration-label update.
    duration = compatibility.const_get(:Label).new
    finished = Queue.new
    compatibility.queue do
      progress.set_fraction(10_000.0 / 0.0)
      duration.text = 'Indefinite'
      finished << true
    end
    expect(finished.pop(timeout: 2)).to be(true)
    expect(progress.send(:component_props)[:value]).to eq(1.0)
    expect(duration.text).to eq('Indefinite')
  end

  it 'retains the last fraction for NaN and reports the degradation only once' do
    progress = compatibility.const_get(:ProgressBar).new
    progress.set_fraction(0.5)
    2.times { expect(progress.set_fraction(Float::NAN)).to equal(progress) }
    expect(progress.send(:component_props)[:value]).to eq(0.5)
    expect(Lich).to have_received(:log).with(/progress_fraction_nan/).once
  end

  it 'preserves spellson colors and row height without leaking provider style to sibling labels' do
    progress = compatibility.const_get(:ProgressBar).new
    provider = compatibility.const_get(:CssProvider).new
    provider.load(data: 'label { font-weight: bold; } trough {font-weight: bold; min-height: 22px; } progress {font-weight: bold; min-height: 20px; background-image: none; background-color: powderblue;}')
    progress.style_context.add_provider(provider, compatibility.const_get(:StyleProvider)::PRIORITY_USER)
    expect(progress.send(:component_props)).to include(height: 24, fill_color: { r: 176, g: 224, b: 230, a: 1.0 })
    label = compatibility.const_get(:Label).new('Elemental Defense I')
    expect(label.send(:component_props)).to include(align: :center, wrap: false)
    expect(label.send(:component_props)[:emphasis]).not_to eq(:strong)
    expect { provider.load(data: 'progress { background-image: url(https://untrusted); }') }
      .to raise_error(StandardError, /operation=load/)
  end

  it 'uses a real split row and the GTK default light palette without extra window chrome' do
    window = compatibility.const_get(:Window).new
    row = compatibility.const_get(:Paned).new(:horizontal)
    duration = compatibility.const_get(:Label).new('Indefinite').set_width_chars(9)
    row.add1(duration)
    row.add2(compatibility.const_get(:Label).new('Spell'))
    window.add(row)
    window.show_all
    expect(row.send(:component_type)).to eq(:split)
    expect(duration.send(:component_props)).to include(min_width_chars: 9)
    expect(window.send(:component_props)).to include(bare: true, density: :compact)
    expect(window.send(:component_props)).not_to have_key(:theme)
    expect(compatibility.const_get(:Settings).default.gtk_application_prefer_dark_theme?).to be false
  end

  it 'preserves the blue bold literal label used by the second control script boon' do
    label = compatibility.const_get(:Label).new
    label.set_markup('<span color="blue" weight="bold">Tip: (?) &amp; options</span>')
    expect(label.send(:component_props)).to include(content: 'Tip: (?) & options', emphasis: :strong,
                                                    foreground: { r: 0, g: 0, b: 255, a: 1.0 })
  end

  it 'retains actual window measurements for the scripts existing settings cleanup' do
    window = compatibility.const_get(:Window).new
    window.resize(240, 25)
    window.show_all
    Timeout.timeout(2) { sleep 0.001 until service.registry.pages_for(owner).first&.last_render }
    page = service.registry.pages_for(owner).first
    # Runtime captures measurements before dispatching configure. Simulate a
    # kill while that callback is queued; cleanup must still see the new size.
    page.observe_window_geometry(width: 340, height: 144, position: [-10, 28])
    expect(window.allocation).to have_attributes(width: 340, height: 144)
    expect(window.position).to eq([-10, 28])
    window.destroy
    expect(window.allocation).to have_attributes(width: 340, height: 144)
  end

  it 'retains noninteractive sensitivity without sending illegal text properties' do
    entry = compatibility.const_get(:Entry).new
    entry.editable = false
    window = compatibility.const_get(:Window).new
    window.add(entry)
    window.show_all
    expect { entry.sensitive = false }.not_to raise_error
    expect(entry.sensitive?).to be(false)
  end

  it 'places pack_end children in reverse order after pack_start children, including live insertion' do
    box = compatibility.const_get(:Box).new(:vertical)
    room, left, right, heading = %w[Room Left Right Heading].map { |text| compatibility.const_get(:Label).new(text) }
    box.pack_end(room)
    window = compatibility.const_get(:Window).new
    window.add(box)
    window.show_all
    box.pack_end(left)
    box.pack_end(right)
    box.pack_start(heading)
    expect(box.children.map(&:text)).to eq(%w[Heading Right Left Room])
  end

  it 'targets background viewer writes by window, not the last callback in another window' do
    first, second = 2.times.map do
      window = compatibility.const_get(:Window).new
      entry = compatibility.const_get(:Entry).new
      window.add(entry)
      window.show_all
      [window, entry]
    end
    session = first.last.session
    session.callback(Struct.new(:viewer_id).new('viewer-a'), widget: first.last) {}
    session.callback(Struct.new(:viewer_id).new('viewer-b'), widget: second.last) {}
    targets = []
    allow(session.port).to receive(:set) { targets << session.viewer_id }
    first.last.text = 'first window only'
    second.last.text = 'second window only'
    expect(targets).to eq(%w[viewer-a viewer-b])
  end

  it 'retains a queued signal viewer across later signals without attributing unrelated threads' do
    window = compatibility.const_get(:Window).new
    entry = compatibility.const_get(:Entry).new
    window.add(entry)
    window.show_all
    session = entry.session
    reads, writes, unrelated = Queue.new, Queue.new, Queue.new
    allow(session.port).to receive(:get) { session.viewer_id }
    allow(session.port).to receive(:set) { writes << session.viewer_id }
    # Hold execution until another viewer has become this window's latest caller.
    session.synchronize do
      session.callback(Struct.new(:viewer_id).new('viewer-a'), widget: entry) do
        compatibility.queue do
          reads << entry.text
          entry.text = 'reply'
          compatibility.queue { reads << entry.text }
        end
        producer = Thread.new { compatibility.queue { unrelated << session.in_callback? } }
        expect(producer.join(2)).to equal(producer)
      end
      session.callback(Struct.new(:viewer_id).new('viewer-b'), widget: entry) {}
    end
    expect(2.times.map { reads.pop(timeout: 2) }).to eq(%w[viewer-a viewer-a])
    expect(writes.pop(timeout: 2)).to eq('viewer-a')
    expect(unrelated.pop(timeout: 2)).to be(false)
    expect(session.in_callback?).to be(false)
  end

  it 'shows informational dialogs without blocking callbacks and cancels them with the parent' do
    parent = compatibility.const_get(:Window).new
    future = Lich::WebUI::Future.new
    allow(parent.session.port).to receive(:modal).and_return(future)
    dialog = compatibility.const_get(:MessageDialog).new(parent: parent, flags: :modal, type: :error, buttons: :ok, message: 'Invalid price')
    responses = []
    dialog.signal_connect('response') { |_widget, response| responses << response }
    parent.session.callback(Struct.new(:viewer_id).new('viewer-a'), widget: parent) do
      expect { dialog.run }.to raise_error(StandardError, /run/)
      expect(dialog.show_all).to equal(dialog)
    end
    parent.destroy
    expect(future).to be_resolved
    expect(dialog).to be_destroyed
    expect(responses).to be_empty
  end

  it 'retains an informational dialog opened before the first browser attachment' do
    parent = compatibility.const_get(:Window).new
    parent.show_all
    dialog = compatibility.const_get(:MessageDialog).new(parent: parent, flags: :modal, type: :info, buttons: :ok, message: 'Ready')
    responses = []
    dialog.signal_connect('response') { |_widget, response| responses << response }
    dialog.show_all
    expect(dialog).not_to be_destroyed
    expect(service.modals.pending_count).to eq(1)
    modal = service.registry.pages_for(owner).find { |page| page.id.start_with?('adapter-modal-') }
    sent = []
    connection = Object.new
    connection.define_singleton_method(:viewer_id) { 'late-dialog-viewer' }
    connection.define_singleton_method(:send_text) { |payload| sent << JSON.parse(payload) }
    address = service.registry.address_for(modal)
    service.runtime.handle(connection, type: 'attach', page: address, version: Lich::WebUI::Contract::VERSION)
    render = modal.last_render
    component = render.tree.each.find { |item| item.type == :dialog }
    service.runtime.handle(connection, type: 'event', page: address, generation: render.generation,
                           cid: component.cid, event: 'response', payload: { button: 'ok' })
    Timeout.timeout(2) { sleep 0.005 until dialog.destroyed? }
    expect(responses).to eq([:ok])
    expect(service.modals.pending_count).to eq(0)
  end

  it 'releases a dialog waiter when its parent is destroyed before attachment' do
    parent = compatibility.const_get(:Window).new
    parent.show_all
    dialog = compatibility.const_get(:MessageDialog).new(parent: parent, flags: :modal, type: :info, buttons: :ok, message: 'Ready')
    dialog.show_all
    expect(service.modals.pending_count).to eq(1)
    waiter = Thread.new { dialog.run }
    parent.destroy

    expect(Timeout.timeout(2) { waiter.value }).to eq(:cancel)
    expect(service.modals.pending_count).to eq(0)
  ensure
    waiter&.kill&.join
  end

  it 'keeps sellunder grid spacing and width-height attachment semantics' do
    grid = compatibility.const_get(:Grid).new
    grid.column_spacing = 20
    grid.row_spacing = 5
    grid.column_homogeneous = true
    grid.attach(compatibility.const_get(:CheckButton).new('Gemshop'), 0, 0, 1, 1)
    grid.attach(compatibility.const_get(:CheckButton).new('Pawnshop'), 1, 0, 1, 1)
    window = compatibility.const_get(:Window).new
    window.add(grid)
    expect { window.show_all }.not_to raise_error
  end

  it 'updates natural grid and box allocation when expanding children change or are removed' do
    window = compatibility::Window.new
    box = compatibility::Box.new(:horizontal)
    grid = compatibility::Grid.new
    entry = compatibility::Entry.new
    grid.attach(entry, 0, 0, 2, 1)
    button = compatibility::Button.new('Close')
    box.pack_start(grid, expand: false)
    box.pack_end(button, expand: false)
    window.add(box)
    window.show_all
    port = window.session.port
    expect(port.get(grid.materialize, :homogeneous)).to be(false)
    entry.set_hexpand(true)
    expect(port.get(grid.materialize, :expand_columns)).to eq([1, 2])
    expect(port.get(box.materialize, :expand_columns)).to eq([1])
    box.reorder_child(grid, 1)
    expect(port.get(box.materialize, :expand_columns)).to eq([2])
    entry.set_hexpand(false)
    expect(port.get(grid.materialize, :expand_columns)).to eq([])
    expect(port.get(box.materialize, :expand_columns)).to eq([])
    grid.column_homogeneous = true
    expect(port.get(grid.materialize, :homogeneous)).to be(true)
    box.remove(button)
    expect(port.get(box.materialize, :cols)).to eq(1)
    expect { box.pack_end(button, expand: false) }.not_to raise_error
    expect(port.get(box.materialize, :cols)).to eq(2)
  end

  it 'separates window minimum requests from resizing and follows notebook expansion live' do
    window = compatibility::Window.new
    window.set_size_request(650, 675)
    box = compatibility::Box.new(:vertical)
    tabs = compatibility::Notebook.new
    tabs.append_page(compatibility::Label.new('Body'), compatibility::Label.new('General'))
    tabs.set_vexpand(true)
    box.add(tabs)
    window.add(box)
    window.show_all
    port = window.session.port
    expect(port.get(window.materialize, :size)).to eq([650, 675])
    expect(port.get(window.materialize, :min_width)).to eq(650)
    expect(window.send(:component_props)).not_to have_key(:width)
    expect(port.get(window.materialize, :viewport)).to be(true)
    expect(port.get(box.materialize, :fill)).to be(true)
    window.resize(900, 800)
    tabs.set_vexpand(false)
    expect(port.get(window.materialize, :size)).to eq([900, 800])
    expect(port.get(window.materialize, :viewport)).to be(false)
    expect(port.get(box.materialize, :fill)).to be(false)
  end

  it 'finds the top-level window and emits destroy once during repeated cleanup' do
    window = compatibility.const_get(:Window).new
    box = compatibility.const_get(:Box).new
    button = compatibility.const_get(:Button).new('Save')
    box.add(button)
    window.add(box)
    destroyed = []
    window.signal_connect('destroy') { destroyed << true }
    expect(button.toplevel).to equal(window)
    window.destroy
    window.destroy
    expect(destroyed).to eq([true])
  end
  it 'clamps scalar adjustments and preserves decimal precision with ordered value signals' do
    adjustment = compatibility.const_get(:Adjustment).new(0, 0.5, 10, 0.1, 1, 0)
    spin = compatibility.const_get(:SpinButton).new(adjustment, 0.1, 1)
    observed = []
    adjustment.signal_connect('value-changed') { |source| observed << [:adjustment, source.value] }
    spin.signal_connect('value-changed') { |source| observed << [:first, source.value] }
    spin.signal_connect('value_changed') { |source| observed << [:second, source.text] }
    expect(spin.value).to eq(0.5)
    expect(spin.text).to eq('0.5')
    spin.set_value(2.75)
    spin.set_value(2.75)
    expect(observed).to eq([[:first, 2.75], [:second, '2.8'], [:adjustment, 2.75]])
    spin.set_value(20)
    expect(adjustment.value).to eq(10)
    expect(spin.value_as_int).to eq(10)
    expect(spin.set_digits(2)).to equal(spin)
    expect(spin.text).to eq('10.00')
    error = compatibility.const_get(:UnsupportedOperation)
    expect { spin.set_digits(21) }.to raise_error(error)
    expect { spin.set_text('3.0') }.to raise_error(error)
    expect { adjustment.set_value(Float::NAN) }.to raise_error(error)
    expect { compatibility.const_get(:SpinButton).new(adjustment) }.to raise_error(error)
    expect { compatibility.const_get(:SpinButton).new(compatibility.const_get(:Adjustment).new(1, 0, 10, 1, 2, 1)) }.to raise_error(error)
  end

  describe 'adjustment notification context' do
    let(:adjustment) { compatibility.const_get(:Adjustment).new(0, 0, 10, 1, 5, 0) }
    let(:spin) { compatibility.const_get(:SpinButton).new(adjustment) }
    let(:viewer_value) { [5] }
    let(:notified) { [] }

    before do
      # Model callback-local viewer input separately from the real widget's retained value.
      allow(spin).to receive(:value) { viewer_value.first }
      allow(spin).to receive(:apply_adjustment_value).and_wrap_original do |original, number|
        original.call(number)
        viewer_value[0] = number
      end
      spin.signal_connect('value-changed') { notified << spin.value }
    end

    it 'notifies a retained-state change after the viewer notification has finished' do
      adjustment.notify_value_changed
      adjustment.set_value(5)
      adjustment.set_value(5)

      expect(notified).to eq([5, 5])
      allow(spin).to receive(:value).and_call_original
      expect(adjustment.value).to eq(5)
    end

    it 'notifies a viewer reset even when the target equals the retained value' do
      adjustment.notify_value_changed
      adjustment.set_value(0)

      expect(notified).to eq([5, 0])
      expect(viewer_value).to eq([0])
    end

    it 'does not redispatch the value already being notified' do
      spin.signal_connect('value-changed') { adjustment.set_value(spin.value) }
      adjustment.notify_value_changed

      expect(notified).to eq([5])
      allow(spin).to receive(:value).and_call_original
      expect(adjustment.value).to eq(5)
    end

    it 'notifies nested changes even when returning to the outer notification value' do
      nested = false
      spin.signal_connect('value-changed') do
        next if nested

        nested = true
        adjustment.set_value(6)
        adjustment.set_value(5)
      end
      adjustment.notify_value_changed

      expect(notified).to eq([5, 6, 5])
    end

    it 'restores the outer notification context after a nested notification' do
      nested = false
      spin.signal_connect('value-changed') do
        next if nested

        nested = true
        adjustment.notify_value_changed
        adjustment.set_value(5)
      end
      adjustment.notify_value_changed

      expect(notified).to eq([5, 5])
    end

    it 'clears notification context when a handler raises' do
      fail_once = true
      adjustment.signal_connect('value-changed') do
        next unless fail_once

        fail_once = false
        raise 'notification fixture error'
      end

      expect { adjustment.notify_value_changed }.to raise_error(RuntimeError, 'notification fixture error')
      adjustment.set_value(5)
      expect(notified).to eq([5, 5])
    end
  end

  it 'supports legacy radio constructors and emits changed members only after exclusive selection' do
    radio = compatibility.const_get(:RadioButton)
    first = radio.new('First')
    second = radio.new(first.group, 'Second')
    third = radio.new(member: first, label: 'Third')
    expect { radio.new(member: false, label: 'Invalid') }.to raise_error(compatibility.const_get(:UnsupportedOperation))
    expect { radio.new(label: false) }.to raise_error(compatibility.const_get(:UnsupportedOperation))
    seen = []
    [first, second, third].each { |widget| widget.signal_connect('toggled') { |source| seen << [source.label, first.active?, second.active?, third.active?] } }
    second.set_active(true)
    second.set_active(true)
    expect(seen).to eq([['First', false, true, false], ['Second', false, true, false]])
    expect(first.group).to eq([first, second, third])
    second.destroy
    expect(first.group).to eq([first, third])
    third.set_active(true)
    expect(third.active?).to be(true)
    toggle = compatibility.const_get(:ToggleButton).new(label: 'Pressed')
    signals = []
    toggle.signal_connect('toggled') { signals << :toggled }
    toggle.signal_connect('clicked') { signals << :clicked }
    toggle.set_active(true)
    toggle.set_active(true)
    expect(signals).to eq([:toggled])
    expect(compatibility.session.port.get(toggle.materialize, :appearance)).to eq('button')
  end

  it 'ignores radio deactivation without clearing selection or emitting toggled signals' do
    radio = compatibility.const_get(:RadioButton)
    first = radio.new('First')
    seen = []
    first.signal_connect('toggled') { |source| seen << [source.label, source.active?] }
    expect(first.set_active(false)).to equal(first)
    expect(first.active?).to be(true)
    expect(seen).to be_empty

    second = radio.new(first, 'Second')
    second.signal_connect('toggled') { |source| seen << [source.label, source.active?] }
    first.active = false
    expect(second.set_active(false)).to equal(second)
    expect([first.active?, second.active?]).to eq([true, false])
    expect(seen).to be_empty

    second.set_active(true)
    expect([first.active?, second.active?]).to eq([false, true])
    expect(seen).to eq([['First', false], ['Second', true]])
    seen.clear
    second.active = false
    first.set_active(false)
    expect([first.active?, second.active?]).to eq([false, true])
    expect(seen).to be_empty
  end

  it 'shows hidden descendants and runs every descendant destroy handler exactly once' do
    window = compatibility.const_get(:Window).new('Lifecycle')
    box = compatibility.const_get(:VBox).new
    child = compatibility.const_get(:Label).new('Retained')
    box.add(child)
    window.add(box)
    child.hide
    destroyed = []
    child.signal_connect('destroy') { destroyed << :child; raise 'fixture cleanup error' }
    box.signal_connect('destroy') { destroyed << :box }
    window.signal_connect('destroy') { destroyed << :window }
    window.show_all
    expect([window, box, child]).to all(be_visible)
    window.destroy
    child.destroy
    window.destroy
    expect(destroyed).to eq(%i[child box window])
    expect(child.text).to eq('Retained')
  end

  it 'dispatches exclusive radio changes and numeric adjustments with viewer-local reads' do
    window = compatibility.const_get(:Window).new('Controls')
    grid = compatibility.const_get(:Grid).new
    first = compatibility.const_get(:RadioButton).new('First')
    second = compatibility.const_get(:RadioButton).new(first, 'Second')
    spin = compatibility.const_get(:SpinButton).new(compatibility.const_get(:Adjustment).new(0.5, 0.5, 10, 0.1, 1, 0), 0.1, 1)
    [first, second, spin].each_with_index { |widget, row| grid.attach(widget, 0, row, 1, 1) }
    seen = Queue.new
    [first, second].each { |widget| widget.signal_connect('toggled') { |source| seen << [source.label, first.active?, second.active?] } }
    spin.signal_connect('value-changed') { seen << [spin.value, spin.adjustment.value, spin.text] }
    window.add(grid)
    window.show_all
    page = nil
    Timeout.timeout(2) { sleep 0.001 until (page = service.registry.pages_for(owner).first)&.last_render }
    connection = double('connection', viewer_id: 'controls', alive?: true, send_text: true)
    address = service.registry.address_for(page)
    service.runtime.handle(connection, type: 'attach', page: address)
    radio_node = page.last_render.tree.each.find { |node| node.type == :radio_option && node.props[:label] == 'Second' }
    spin_node = page.last_render.tree.each.find { |node| node.type == :number_input }
    service.runtime.handle(connection, type: 'event', page: address, generation: page.generation,
                                       cid: radio_node.cid, event: 'change', payload: { value: true })
    expect(Timeout.timeout(2) { [seen.pop, seen.pop] }).to eq([['First', false, true], ['Second', false, true]])
    service.runtime.handle(connection, type: 'event', page: address, generation: page.generation,
                                       cid: spin_node.cid, event: 'change', payload: { value: 2.75 })
    expect(Timeout.timeout(2) { seen.pop }).to eq([2.75, 2.75, '2.8'])
    expect([first.active?, second.active?, spin.value]).to eq([true, false, 0.5])
  end
  it 'submits shim controls and exercises text, images, menus and expandable content through a browser', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    Dir.mktmpdir('shim-content-browser-') do |directory|
      owner.define_singleton_method(:file_name) { File.join(directory, 'fixture.lic') }
      allow(Lich::WebUI).to receive(:service).and_return(service)
      image_path = File.join(directory, 'pixel.png')
      File.binwrite(image_path, 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='.unpack1('m0'))
      window = compatibility::Window.new('Control conventions')
      column = compatibility::VBox.new(false, 4)
      first = compatibility::RadioButton.new('First')
      second = compatibility::RadioButton.new(member: first, label: 'Second')
      toggle = compatibility::ToggleButton.new(label: 'Enabled')
      spin = compatibility::SpinButton.new(compatibility::Adjustment.new(0.5, 0.5, 10, 0.1, 1, 0), 0.1, 1)
      search = compatibility::SearchEntry.new
      search.set_placeholder_text('Search fixture')
      details = compatibility::Expander.new('Details')
      view = compatibility::TextView.new
      view.buffer.text = 'Initial text'
      details.add(view)
      image = compatibility::Image.new(file: image_path)
      image.set_tooltip_text('Fixture image')
      actions = compatibility::Label.new('Actions')
      menu = compatibility::Menu.new
      check = compatibility::CheckMenuItem.new('Menu enabled')
      nested = compatibility::Menu.new
      radio_first = compatibility::RadioMenuItem.new('Menu first')
      radio_second = compatibility::RadioMenuItem.new(radio_first, 'Menu second')
      nested.append(radio_first)
      nested.append(radio_second)
      choices = compatibility::MenuItem.new('Choices')
      choices.submenu = nested
      clear = compatibility::MenuItem.new('Clear image')
      clear.signal_connect('activate') { image.clear }
      [check, choices, compatibility::SeparatorMenuItem.new, clear].each { |item| menu.append(item) }
      actions.signal_connect('button-press-event') { |_widget, event| menu.popup_at_pointer(event) if event.button == 3 }
      save = compatibility::Button.new('Save')
      save.signal_connect('clicked') { window.destroy }
      [first, second, toggle, spin, search, details, image, actions, save].each { |widget| column.pack_start(widget) }
      window.add(column)
      window.show_all
      page = nil
      Timeout.timeout(5) { sleep 0.01 until (page = service.registry.pages_for(owner).first)&.last_render }
      WebUIBrowser.check(service: service, page: page, scenario: 'shim-controls')
      expect(window).to be_destroyed
      expect([first.active?, second.active?, toggle.active?, spin.value, search.text]).to eq([false, true, true, 2.85, 'query'])
      expect(view.buffer.text).to eq("line one\nline two")
      expect(details.expanded?).to be(false)
      expect(image.pixbuf).to be_nil
      expect([check.active?, radio_first.active?, radio_second.active?]).to eq([true, false, true])
    end
  end
end
