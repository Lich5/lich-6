# frozen_string_literal: true

require_relative '../../spec_helper'
require 'timeout'
require_relative '../../../lib/common/script_scope'

RSpec.describe 'bounded model, tree and combo compatibility' do
  let(:scope) { Lich::Common::ScriptScope }
  let(:owner) { Struct.new(:name).new('models.lic') }
  let(:service) { Lich::WebUI::Service.new }
  let(:gtk) { scope.const_get(:Gtk, false) }

  before do
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

  def wait_for(&block)
    Timeout.timeout(3) { sleep 0.005 until block.call }
  end

  def show(*widgets)
    window = gtk::Window.new
    widgets.each { |widget| window.add(widget) }
    window.show_all
    page = nil
    wait_for { (page = service.registry.pages_for(owner).first)&.last_render }
    [window, page]
  end

  def connect(page, id)
    connection = Struct.new(:viewer_id, :messages).new(id, [])
    def connection.alive? = true
    def connection.send_text(text) = messages << JSON.parse(text)
    service.runtime.handle(connection, type: 'attach', page: service.registry.address_for(page))
    connection
  end

  def nodes(connection)
    tree = connection.messages.reverse.find { |message| message['type'] == 'render' }.fetch('tree')
    flatten = ->(node) { [node] + Array(node['children']).flat_map { |child| flatten.call(child) } }
    flatten.call(tree)
  end

  def send_event(page, connection, type, event, payload, submission: nil)
    render = connection.messages.reverse.find { |message| message['type'] == 'render' }
    node = nodes(connection).find { |candidate| candidate['type'] == type.to_s }
    message = { type: 'event', page: service.registry.address_for(page), generation: render['generation'], cid: node['cid'], event: event, payload: payload }
    message[:submission] = submission if submission
    service.runtime.handle(connection, message)
  end

  def table(model)
    view = gtk::TreeView.new(model)
    view.append_column(gtk::TreeViewColumn.new('Name', gtk::CellRendererText.new, text: 0))
    view
  end

  it 'moves independent iterators without mutating rows and invalidates deleted handles' do
    store = gtk::ListStore.new(String, Integer)
    first = store.append
    first[0], first[1] = 'Alpha', 10
    second = store.append
    second[0], second[1] = 'Beta', 2
    walk = store.iter_first
    expect(walk.next!).to be(true)
    walk[0] = 'Changed'
    expect(first[0]).to eq('Alpha')
    expect(second[0]).to eq('Changed')
    store.set_sort_column_id(1, :ascending)
    expect(second.path.to_s).to eq('0')
    expect(first.path.to_s).to eq('1')
    deleting = store.get_iter('0')
    expect(store.remove(deleting)).to be(true)
    expect(deleting).to eq(first)
    expect { second[0] }.to raise_error(gtk::UnsupportedOperation, /iterator/)
    expect(deleting.next!).to be(false)
    expect(store.iter_is_valid?(deleting)).to be(false)
    expect(store.each.map { |_model, path, iter| [path.to_s, iter[0]] }).to eq([['0', 'Alpha']])
  end

  it 'keeps sibling paths and removes complete subtrees while preserving unrelated identities' do
    store = gtk::TreeStore.new(String)
    root = store.append
    root[0] = 'Parent'
    other = store.append
    other[0] = 'Other'
    child = store.append(root)
    child[0] = 'Child'
    grandchild = store.append(child)
    store.prepend(root)[0] = 'Before'
    expect(child.path.to_s).to eq('0:1')
    expect(grandchild.path.to_s).to eq('0:1:0')
    expect(store.iter_parent(grandchild)).to eq(child)
    expect(store.iter_n_children(root)).to eq(2)
    expect(store.iter_after(child)).to be_nil
    expect(store.remove(root)).to be(true)
    expect(root).to eq(other)
    expect(store.rows.map { |iter| iter[0] }).to eq(['Other'])
    expect(store.iter_is_valid?(grandchild)).to be(false)
  end

  it 'rejects malformed paths, foreign handles, unsupported types and aliased mutable strings' do
    store = gtk::ListStore.new(String, TrueClass)
    row = store.append
    text = +'original'
    row[0] = text
    text.replace('external')
    row[0].replace('copy')
    expect(row[0]).to eq('original')
    expect { row[-1] }.to raise_error(gtk::UnsupportedOperation)
    expect { row[1] = 'false' }.to raise_error(gtk::UnsupportedOperation)
    expect { gtk::ListStore.new(Object) }.to raise_error(gtk::UnsupportedOperation)
    expect { store.get_iter('-1') }.to raise_error(gtk::UnsupportedOperation)
    expect { store.get_iter('0:garbage') }.to raise_error(gtk::UnsupportedOperation)
    expect { store.remove(gtk::ListStore.new(String).append) }.to raise_error(gtk::UnsupportedOperation)
    expect { store.set_sort_func(0) {} }.to raise_error(gtk::UnsupportedOperation)
    expect(store.get_iter('20')).to be_nil
    store.clear
    expect(store.append.key).not_to eq(row.key)
  end

  it 'resolves sorted rows and paths without a whole-store search for each lookup' do
    store = gtk::ListStore.new(String, Integer)
    original = Array.new(40) { store.append }
    prepended = store.prepend
    inserted = store.insert(2)
    expected = [prepended, original.first, inserted, *original.drop(1)]
    # Every sort key is equal: descending must preserve explicit insert positions,
    # and its tie-breaker must not search the backing array for each comparison.
    store.set_sort_column_id(1, :descending)
    backing_rows = store.instance_variable_get(:@rows)
    %i[find select index any?].each { |method| expect(backing_rows).not_to receive(method) }
    expect(store.rows).to eq(expected)
    expected.each_with_index do |iter, index|
      expect(iter.path.to_s).to eq(index.to_s)
      expect(store.find_key(iter.key)).to eq(iter)
      expect(store.iter_is_valid?(iter)).to be(true)
      expect(iter[1]).to eq(0)
    end
  end

  it 'populates an unseen view without reading cells and reconciles retained row identities' do
    model = gtk::TreeStore.new(String)
    view = table(model)
    view.selection.mode = :browse
    expect(model).not_to receive(:get_value)
    first = model.append
    model.append(first)[0] = 'Child'
    last = model.append
    first[0] = 'Parent'
    expect(view.selection.selected).to eq(first)
    model.remove(model.find_key(first.key))
    expect(view.selection.selected).to eq(last)
    expect(view.instance_variable_get(:@handle)).to be_nil
  end

  it 'retains unseen combo and cell-editor bounds without projecting table cells' do
    model = gtk::ListStore.new(String)
    row = model.append
    row[0] = 'Small'
    table(model)
    combo = gtk::ComboBox.new(model)
    expect { row[0] = 'x' * 513 }.to raise_error(Lich::WebUI::SchemaViolationError)
    expect(row[0]).to eq('Small')
    combo.destroy

    values = gtk::ListStore.new(String)
    values.append[0] = 'Small'
    renderer = gtk::CellRendererCombo.new
    renderer.model = model
    renderer.editable = true
    view = gtk::TreeView.new(values)
    view.append_column(gtk::TreeViewColumn.new('Choice', renderer, text: 0))
    expect(values).not_to receive(:get_value)
    expect { row[0] = 'x' * 513 }.to raise_error(Lich::WebUI::SchemaViolationError)
    expect(row[0]).to eq('Small')
  end

  it 'restores indexed identities, subtree order and sort state after rejected mutations' do
    model = gtk::TreeStore.new(String)
    root = model.append
    root[0] = 'Zulu'
    child = model.append(root)
    child[0] = 'Child'
    other = model.prepend
    other[0] = 'Alpha'
    model.set_sort_column_id(0, :descending)
    expected = model.rows.map { |iter| [iter.key, iter.path.to_s, iter[0]] }
    observer = double(session: model.session, model_changed!: nil)
    allow(observer).to receive(:model_will_change!).and_raise('rejected candidate')
    model.watch(observer)
    [-> { root[0] = 'Changed' }, -> { model.prepend(root) },
     -> { model.remove(root) }, -> { model.clear },
     -> { model.set_sort_column_id(0, :ascending) }].each do |change|
      expect(&change).to raise_error('rejected candidate')
      expect(model.rows.map { |iter| [iter.key, iter.path.to_s, iter[0]] }).to eq(expected)
      expect(model.iter_parent(child)).to eq(root)
      expect(model.iter_is_valid?(root)).to be(true)
    end
    model.unwatch(observer)
    model.set_sort_column_id(-2)
    expect(model.rows).to eq([other, root, child])
  end

  it 'projects a live mutation once and never reuses a rejected candidate on repaint' do
    model = gtk::ListStore.new(String)
    row = model.append
    row[0] = 'Small'
    view = table(model)
    combo = gtk::ComboBox.new(model)
    _window, page = show(view, combo)
    viewer = connect(page, 'projection')
    projections = 0
    allow(view).to receive(:row_definitions).and_wrap_original do |original|
      projections += 1
      original.call
    end
    row[0] = 'Accepted'
    expect(projections).to eq(1)
    expect { row[0] = 'x' * 513 }.to raise_error(Lich::WebUI::SchemaViolationError)
    view.model_changed!
    wait_for do
      nodes(viewer).find { |node| node['type'] == 'table' }['props']['rows'].first['cells'].values == ['Accepted']
    end
    expect(row[0]).to eq('Accepted')
  end

  it 'uses real combo model rows, duplicate labels and live label-column updates' do
    model = gtk::ListStore.new(String, String)
    first, second = model.append, model.append
    first[0], first[1] = 'hidden one', 'Same'
    second[0], second[1] = 'hidden two', 'Same'
    combo = gtk::ComboBox.new(model)
    renderer = gtk::CellRendererText.new
    combo.pack_start(renderer, true)
    combo.add_attribute(renderer, :text, 1)
    combo.active_iter = second
    expect(combo.active).to eq(1)
    expect(combo.active_iter[0]).to eq('hidden two')
    model.remove(first)
    expect(combo.active).to eq(0)
    expect(combo.active_text).to eq('Same')
    second[1] = 'Renamed'
    expect(combo.active_text).to eq('Renamed')
    replacement = gtk::ListStore.new(String, String)
    combo.model = replacement
    expect(combo.active).to eq(-1)
    expect(combo.active_iter).to be_nil
    second[1] = 'Old model only'
    expect(combo.send(:component_props)[:options]).to eq([{ value: 'none', label: '' }])
  end

  it 'supports legacy text-only and editable forms without adding a second input' do
    combo = gtk::ComboBox.new(true)
    combo.append_text('One')
    combo.active = 0
    expect(combo.model.get_iter('0')).to eq(combo.active_iter)
    editable = gtk::ComboBoxText.new(entry: true)
    editable.append_text('Choice')
    editable.active = 0
    expect(editable.child.text).to eq('Choice')
    editable.child.text = 'Custom'
    expect(editable.active).to eq(-1)
    expect(editable.child.text).to eq('Custom')
    expect(editable.active_text).to eq('Custom')
    editable.active = -1
    expect(editable.child.text).to eq('')
    _window, page = show(editable)
    expect(page.last_render.tree.each.count { |node| node.type == :select }).to eq(1)
    expect(page.last_render.tree.each.none? { |node| node.type == :text_input }).to be(true)
  end

  it 'keeps viewer selection and expansion separate and prunes rows removed from a shared model' do
    model = gtk::TreeStore.new(String)
    root = model.append
    root[0] = 'Parent'
    child = model.append(root)
    child[0] = 'Child'
    view = table(model)
    view.selection.mode = :multiple
    observed = Queue.new
    view.selection.signal_connect('changed') { observed << view.selection.selected_rows.first.map(&:to_s) }
    view.signal_connect('row-expanded') { |_view, iter, path| observed << [iter.key, path.to_s] }
    _window, page = show(view)
    first, second = connect(page, 'one'), connect(page, 'two')
    send_event(page, first, :table, 'selection_change', { rows: [root.key, child.key] })
    expect(observed.pop(timeout: 2)).to eq(['0', '0:0'])
    send_event(page, first, :table, 'row_toggle', { row: root.key, expanded: true })
    expect(observed.pop(timeout: 2)).to eq([root.key, '0'])
    service.runtime.refresh(page)
    wait_for { nodes(first).find { |node| node['type'] == 'table' }['props']['expanded'] == [root.key] }
    expect(nodes(second).find { |node| node['type'] == 'table' }['props']['selected']).to eq([])
    model.remove(model.get_iter('0:0'))
    wait_for { nodes(first).find { |node| node['type'] == 'table' }['props']['rows'].length == 1 }
    expect(nodes(first).find { |node| node['type'] == 'table' }['props']['selected']).to eq([root.key])
    expect(nodes(second).find { |node| node['type'] == 'table' }['props']['expanded']).to eq([])
  end

  it 'lets scripts reject text edits and toggle the old boolean exactly once' do
    model = gtk::ListStore.new(String, TrueClass)
    row = model.append
    row[0] = 'Keep'
    view = gtk::TreeView.new(model)
    text, toggle = gtk::CellRendererText.new, gtk::CellRendererToggle.new
    text.editable = true
    name = gtk::TreeViewColumn.new('Name', text, text: 0)
    flag = gtk::TreeViewColumn.new('Flag', toggle, active: 1)
    view.append_column(name)
    view.append_column(flag)
    observed = Queue.new
    text.signal_connect('edited') { |_cell, path, value| observed << [path, value, model.get_iter(path)[0]] }
    toggle.signal_connect('toggled') { |_cell, path| model.get_iter(path)[1] = !model.get_iter(path)[1]; observed << model.get_iter(path)[1] }
    _window, page = show(view)
    viewer = connect(page, 'editor')
    send_event(page, viewer, :table, 'cell_edit', { row: row.key, column: name.key, value: 'Rejected' })
    expect(observed.pop(timeout: 2)).to eq(['0', 'Rejected', 'Keep'])
    expect(row[0]).to eq('Keep')
    send_event(page, viewer, :table, 'cell_edit', { row: row.key, column: flag.key, value: true })
    expect(observed.pop(timeout: 2)).to be(true)
    expect(row[1]).to be(true)
  end

  it 'publishes a shared model into two views and detaches replacement/destruction observers' do
    first = gtk::ListStore.new(String)
    row = first.append
    row[0] = 'Shared'
    a, b = table(first), table(first)
    window, page = show(a, b)
    viewer = connect(page, 'shared')
    second = gtk::ListStore.new(String)
    second.append[0] = 'Replacement'
    a.model = second
    row[0] = 'Changed'
    wait_for do
      nodes(viewer).select { |node| node['type'] == 'table' }.map { |node| node['props']['rows'].first['cells'].values.first } == ['Replacement', 'Changed']
    end
    window.destroy
    expect(first.instance_variable_get(:@observers)).to be_empty
    expect(second.instance_variable_get(:@observers)).to be_empty
    expect { row[0] = 'After close' }.not_to raise_error
  end

  it 'rejects an incompatible model update before changing any attached view' do
    model = gtk::ListStore.new(String)
    row = model.append
    row[0] = 'Small'
    view = table(model)
    combo = gtk::ComboBox.new(model)
    _window, page = show(view, combo)
    viewer = connect(page, 'limits')
    expect { row[0] = 'x' * 513 }.to raise_error(Lich::WebUI::SchemaViolationError)
    expect(row[0]).to eq('Small')
    expect(nodes(viewer).find { |node| node['type'] == 'select' }['props']['options'].last['label']).to eq('Small')
    expect(nodes(viewer).find { |node| node['type'] == 'table' }['props']['rows'].first['cells'].values).to eq(['Small'])
    combo.destroy
    expect { row[0] = 'x' * 513 }.not_to raise_error
  end

  it 'keeps editable free text distinct from IDs and preserves it while choices change' do
    combo = gtk::ComboBoxText.new(entry: true)
    combo.append_text('Choice')
    combo.child.text = 'none'
    expect(combo.child.text).to eq('none')
    expect(combo.active_iter).to be_nil
    combo.child.text = combo.model.iter_first.key
    expect(combo.active_iter).to be_nil
    _window, page = show(combo)
    a, b = connect(page, 'a'), connect(page, 'b')
    changed = Queue.new
    combo.signal_connect('changed') { changed << combo.child.text }
    send_event(page, a, :select, 'change', { value: 'text:Custom' })
    expect(changed.pop(timeout: 2)).to eq('Custom')
    send_event(page, b, :select, 'change', { value: combo.model.iter_first.key })
    expect(changed.pop(timeout: 2)).to eq('Choice')
    combo.model.remove(combo.model.iter_first)
    wait_for { nodes(b).find { |node| node['type'] == 'select' }['props']['options'].length == 1 }
    expect(nodes(a).find { |node| node['type'] == 'select' }['props']['value']).to eq('text:Custom')
    # A removed choice clears, while a literal entry survives that same model update.
    expect(nodes(b).find { |node| node['type'] == 'select' }['props']['value']).to eq('none')
  end

  [
    ['matching text', ['Choice', 'Choice'], 'Choice', 0],
    ['empty text', ['Choice'], '', -1],
    ['an empty option label', ['', 'Choice'], '', 0],
    ['an existing duplicate-label selection', ['Choice', 'Choice'], 1, 1],
    ['an existing empty selection', ['Choice'], -1, -1]
  ].each do |description, labels, initial, expected_index|
    it "preserves #{description} when closing an editable combo before publication" do
      combo = gtk::ComboBoxText.new(entry: true)
      labels.each { |label| combo.append_text(label) }
      initial.is_a?(String) ? combo.child.text = initial : combo.active = initial

      combo.child.editable = false

      expect(combo.active).to eq(expected_index)
      expect(combo.child.text).to eq(expected_index == -1 ? '' : labels[expected_index])
      _window, page = show(combo)
      viewer = connect(page, 'closed-combo')
      props = nodes(viewer).find { |node| node['type'] == 'select' }.fetch('props')
      expect(props['editable']).to be(false)
      expect(props).not_to have_key('free_text_prefix')
      expect(props['value']).to eq(expected_index == -1 ? 'none' : combo.model.rows[expected_index].key)
      expect { combo.child.editable = true }.to raise_error(gtk::UnsupportedOperation)
    end
  end

  it 'refuses unmatched text before changing combo editability or its value' do
    combo = gtk::ComboBoxText.new(entry: true)
    combo.append_text('Choice')
    combo.child.text = 'Unknown'
    before = combo.send(:component_props).dup

    expect { combo.child.editable = false }.to raise_error(gtk::UnsupportedOperation, /entry_editable=/)

    expect(combo.send(:component_props)).to eq(before)
    expect(combo.child.text).to eq('Unknown')
    expect(combo.active).to eq(-1)
    _window, page = show(combo)
    viewer = connect(page, 'still-editable')
    expect(nodes(viewer).find { |node| node['type'] == 'select' }['props']).to include(
      'editable' => true, 'free_text_prefix' => 'text:', 'value' => 'text:Unknown'
    )
  end

  it 'can reopen a closed combo before publication and assign free text' do
    combo = gtk::ComboBoxText.new(entry: true)
    combo.append_text('Choice')
    combo.child.text = 'Choice'
    combo.child.editable = false
    combo.child.editable = true
    expect(combo.active).to eq(0)
    combo.child.text = 'Custom'
    _window, page = show(combo)
    viewer = connect(page, 'reopened-combo')
    expect(nodes(viewer).find { |node| node['type'] == 'select' }['props']).to include(
      'editable' => true, 'free_text_prefix' => 'text:', 'value' => 'text:Custom'
    )
  end

  it 'targets programmatic expansion and cursor updates to the callback viewer and retains them on Save' do
    model = gtk::TreeStore.new(String)
    root = model.append
    child = model.append(root)
    root[0], child[0] = 'Parent', 'Child'
    view = table(model)
    action = gtk::Button.new('Expand')
    saved = Queue.new
    action.signal_connect('clicked') do
      view.expand_all
      view.set_cursor('0:0', view.columns.first)
      saved << [view.cursor.first.to_s, view.row_expanded?('0')]
    end
    window, page = show(view, action)
    a, b = connect(page, 'a'), connect(page, 'b')
    send_event(page, a, :button, 'activate', {}, submission: [])
    expect(saved.pop(timeout: 2)).to eq(['0:0', true])
    wait_for { nodes(a).find { |node| node['type'] == 'table' }['props']['cursor']['row'] == child.key }
    expect(nodes(b).find { |node| node['type'] == 'table' }['props']['cursor']).to eq({})
    expect(nodes(b).find { |node| node['type'] == 'table' }['props']['expanded']).to eq([])
    # The next terminal callback commits the viewer's final table state before destruction.
    action.signal_connect('clicked') { window.destroy }
    send_event(page, a, :button, 'activate', {}, submission: [])
    saved.pop(timeout: 2)
    wait_for { window.destroyed? }
    expect(view.selection.selected).to eq(child)
    expect(view.cursor.first.to_s).to eq('0:0')
    expect(view.row_expanded?('0')).to be(true)
  end

  it 'sorts numeric model columns while activation resolves the stable row and actual column' do
    model = gtk::ListStore.new(String, Integer)
    ten, two = model.append, model.append
    ten[0], ten[1], two[0], two[1] = 'Ten', 10, 'Two', 2
    view = table(model)
    number = gtk::TreeViewColumn.new('Number', gtk::CellRendererText.new, text: 1)
    number.sort_column_id = 1
    view.append_column(number)
    activated = Queue.new
    view.signal_connect('row-activated') { |_view, path, column| activated << [path.to_s, column] }
    _window, page = show(view)
    viewer = connect(page, 'sort')
    send_event(page, viewer, :table, 'sort_change', { column: number.key, direction: 'asc' })
    wait_for { model.iter_first == two }
    wait_for { nodes(viewer).find { |node| node['type'] == 'table' }['props']['rows'].first['key'] == two.key }
    send_event(page, viewer, :table, 'row_activate', { row: ten.key, column: number.key }, submission: [])
    expect(activated.pop(timeout: 2)).to eq(['1', number])
    expect(ten[1]).to eq(10)
  end

  it 'binds choice editors to live models without committing before the edited handler' do
    values = gtk::ListStore.new(String)
    values.append[0] = 'Old'
    options = gtk::ListStore.new(String)
    options.append[0] = 'New'
    renderer = gtk::CellRendererCombo.new
    renderer.model = options
    renderer.text_column = 0
    renderer.has_entry = false
    renderer.editable = true
    view = gtk::TreeView.new(values)
    column = gtk::TreeViewColumn.new('Choice', renderer, text: 0)
    view.append_column(column)
    observed = Queue.new
    renderer.signal_connect('edited') { |_renderer, path, text| observed << [values.get_iter(path)[0], text]; values.get_iter(path)[0] = text }
    window, page = show(view)
    viewer = connect(page, 'choices')
    send_event(page, viewer, :table, 'cell_edit', { row: values.iter_first.key, column: column.key, value: 'New' })
    expect(observed.pop(timeout: 2)).to eq(['Old', 'New'])
    options.append[0] = 'Later'
    wait_for { nodes(viewer).find { |node| node['type'] == 'table' }['props']['columns'].first['editor']['options'].last['label'] == 'Later' }
    window.destroy
    expect(options.instance_variable_get(:@observers)).to be_empty
  end

  it 'implements browse selection and refuses foreign ownership and unsupported presentation' do
    model = gtk::ListStore.new(String)
    row = model.append
    view = table(model)
    view.selection.mode = :browse
    expect(view.selection.selected).to eq(row)
    view.selection.unselect_all
    expect(view.selection.selected).to eq(row)
    view.selection.mode = :none
    expect(view.selection.selected).to be_nil
    expect { view.selection.select_iter(row) }.to raise_error(gtk::UnsupportedOperation)
    expect { view.set_cursor('0', nil, true) }.to raise_error(gtk::UnsupportedOperation)
    expect { gtk::TreeViewColumn.new('Rich', gtk::CellRendererText.new, markup: 0) }.to raise_error(gtk::UnsupportedOperation)
    foreign = gtk::ListStore.new(String)
    foreign.instance_variable_set(:@session, Object.new)
    expect { view.model = foreign }.to raise_error(gtk::UnsupportedOperation)
    expect { gtk::ComboBox.new(foreign) }.to raise_error(gtk::UnsupportedOperation)
    expect(view.model).to equal(model)
  end

  it 'returns selected paths before their model and iterates selections in model order' do
    model = gtk::ListStore.new(String)
    first, second = model.append, model.append
    first[0], second[0] = 'Alpha', 'Beta'
    view = table(model)
    view.selection.mode = :multiple
    view.selection.select_iter(second)
    view.selection.select_iter(first)
    paths, selected_model = view.selection.selected_rows
    expect(paths.map(&:to_s)).to eq(%w[0 1])
    expect(selected_model).to equal(model)
    expect(view.selection.selected_each.map { |_store, _path, iter| iter[0] }).to eq(%w[Alpha Beta])
    model.set_sort_column_id(0, :descending)
    expect(view.selection.selected_each.map { |_store, _path, iter| iter[0] }).to eq(%w[Beta Alpha])
  end

  it 'allows a mixed-column combo model to be configured before requiring its text mapping' do
    model = gtk::ListStore.new(Integer, String)
    row = model.append
    row[0], row[1] = 7, 'Seven'
    combo = gtk::ComboBox.new(model)
    expect { combo.materialize }.to raise_error(gtk::UnsupportedOperation, /text_column/)
    renderer = gtk::CellRendererText.new
    combo.pack_start(renderer, true)
    combo.set_attributes(renderer, text: 1)
    combo.active_iter = row
    expect(combo.active_text).to eq('Seven')
    expect(combo.active_iter[0]).to eq(7)
    expect { show(combo) }.not_to raise_error
  end
end
