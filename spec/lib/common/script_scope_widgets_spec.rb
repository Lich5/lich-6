# frozen_string_literal: true

require_relative '../../spec_helper'
require_relative '../../../lib/common/script_scope'

RSpec.describe 'bounded script compatibility pilot' do
  let(:scope) { Lich::Common::ScriptScope }
  let(:owner) { Struct.new(:name).new('pilot.lic') }
  let(:service) { Lich::WebUI::Service.new }
  let(:compatibility) { scope.const_get(:Gtk, false) }

  before do
    scope.activate!
    stub_const('Lich::Common::Script', Class.new { def self.current; end })
    allow(Lich::Common::Script).to receive(:current).and_return(owner)
    allow(Lich::WebUI).to receive(:adapter) { |owner:, viewer: nil| Lich::WebUI::Adapter.new(owner: owner, service: service, viewer: viewer) }
    allow(Lich).to receive(:log)
  end

  after do
    Lich::Common::ScriptDeath.run(owner)
    service.stop
  end

  it 'resolves GTK 3 and availability only within script bindings' do
    [scope.script_binding, scope.untrusted_binding].each do |binding|
      expect(eval('Gtk::Version::MAJOR', binding)).to eq(3)
      expect(eval("Gtk::Version::STRING.chr == '3'", binding)).to be(true)
      expect(eval('HAVE_GTK', binding)).to be(true)
    end
    expect(Lich::Common.const_defined?(:Gtk, false)).to be(false)
    expect(Object.const_defined?(:Gtk, false)).to be(false)
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
    expect(Lich).to have_received(:log).with(/arbitrary.*colour/)
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
