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

  it 'renders authorized file images, scales without decoding, and clears without a broken source' do
    path = File.join(asset_directory, 'space image.png')
    # PNG signature and IHDR dimensions are enough for the bounded header reader.
    File.binwrite(path, [137, 80, 78, 71, 13, 10, 26, 10].pack('C*') + [13].pack('N') + 'IHDR' + [20, 10].pack('NN'))
    pixbuf = scope::GdkPixbuf::Pixbuf.new(file: path, width: 10, height: 10)
    expect([pixbuf.width, pixbuf.height]).to eq([10, 5])
    scaled = pixbuf.scale_simple(40, 20, :bilinear)
    expect([scaled.width, scaled.height, pixbuf.width]).to eq([40, 20, 10])
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
