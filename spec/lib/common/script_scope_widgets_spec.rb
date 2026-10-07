# frozen_string_literal: true

require_relative '../../spec_helper'
require 'timeout'
require_relative '../../../lib/common/script_scope'

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
    expect { eval('Gtk::Builder', scope.script_binding, 'pilot.lic', 12) }
      .to raise_error(StandardError, /script=pilot.lic.*operation=Builder.*pilot.lic:12/)
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

  it 'keeps shim entry and checkbox defaults while accepting their browser values', browser: true do
    skip 'explicit browser run only' unless ENV['NATIVE_BROWSER'] == '1'

    window = compatibility.const_get(:Window).new('Shim entry width')
    entry = compatibility.const_get(:Entry).new
    checkbox = compatibility.const_get(:CheckButton).new('Shim checked')
    content = compatibility.const_get(:Box).new(:vertical)
    content.pack_start(checkbox)
    content.pack_start(entry)
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
    service.start
    puts "SHIM_ENTRY_BROWSER_URL=#{service.launch_url(page: page)}"
    $stdout.flush
    Timeout.timeout(120) { sleep 0.05 until window.destroyed? }
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
    service.start
    puts "SHIM_SEPARATOR_BROWSER_URL=#{service.launch_url(page: page)}"
    $stdout.flush
    Timeout.timeout(120) { sleep 0.05 until window.destroyed? }
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

  it 'renders spell progress with its overlay label and refuses invalid fractions' do
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
    expect { progress.set_fraction(1.1) }.to raise_error(StandardError, /set_fraction/)
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
    expect(duration.send(:component_props)).to include(width: 72)
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
end
