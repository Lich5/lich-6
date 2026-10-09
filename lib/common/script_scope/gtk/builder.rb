# frozen_string_literal: true

require 'rexml/document'

module Lich
  module Common
    module ScriptScope
      module Gtk
        # Stable XML identity for Builder objects; it is unrelated to CSS widget names.
        module BuilderIdentity
          # @return [String, nil] declared ID, generated anonymous ID, or nil outside Builder
          attr_reader :builder_name
        end

        [Widget, ModelObject, Adjustment, TextBuffer].each { |type| type.include(BuilderIdentity) }

        # A refused document reports the XML location in addition to script attribution.
        class BuilderError < UnsupportedOperation
          # @return [Array<Hash>] detected XML blockers, excluding property text values
          attr_reader :issues

          def initialize(message, issues: [])
            super(message)
            @issues = issues.map(&:freeze).freeze
          end

          # Bounded structural context for Gtk.queue logging; never includes XML values.
          # @return [String] first blocker and total detected declaration count
          def diagnostic
            first = issues.first || {}
            fields = %i[object xml_class property reason].map do |key|
              "#{key}=#{first[key].to_s.gsub(/[^a-zA-Z0-9_.:\- =;()]/, '?')[0, 160]}"
            end
            "#{fields.join(' ')} blockers=#{issues.length}"
          end
        end

        # Bounded GtkBuilder translation into existing script-owned shim objects.
        # Each load constructs an isolated graph. No handlers or windows are exposed
        # until references, properties, child placement and component schemas validate.
        class Builder < ModelObject
          MAX_BYTES = 1_048_576
          MAX_OBJECTS = 2048
          MAX_DEPTH = 64
          CLASSES = %w[Window Box HBox VBox Grid Table Frame ScrolledWindow Viewport
                       Notebook Expander Label Entry SearchEntry Button ToggleButton
                       CheckButton RadioButton SpinButton ComboBoxText ComboBox TextView
                       TextBuffer Separator HSeparator TreeView TreeViewColumn
                       TreeSelection ListStore TreeStore CellRendererText CellRendererToggle
                       CellRendererCombo Adjustment].to_h { |name| ["Gtk#{name}", Gtk.const_get(name, false)] }.freeze
          COLUMN_TYPES = { 'gchararray' => String, 'gint' => Integer, 'guint' => Integer,
                           'gfloat' => Float, 'gdouble' => Float, 'gboolean' => TrueClass }.freeze
          CONSTRUCTOR_PROPERTIES = {
            'GtkBox' => %w[orientation spacing], 'GtkHBox' => %w[homogeneous spacing], 'GtkVBox' => %w[homogeneous spacing],
            'GtkTable' => %w[n-rows n-columns],
            'GtkAdjustment' => %w[value lower upper step-increment page-increment page-size],
            'GtkSpinButton' => %w[adjustment climb-rate digits], 'GtkFrame' => %w[label], 'GtkExpander' => %w[label],
            'GtkComboBox' => %w[has-entry model], 'GtkComboBoxText' => %w[has-entry model], 'GtkTextView' => %w[buffer],
            'GtkSeparator' => %w[orientation], 'GtkRadioButton' => %w[group label],
            'GtkTreeView' => %w[model], 'GtkCellRendererCombo' => %w[model],
          }.freeze
          ELEMENTS = {
            'interface' => [%w[requires object], []],
            'requires' => [[], %w[lib version]],
            'object' => [%w[property child signal columns data items attributes], %w[class id]],
            'property' => [[], %w[name translatable comments context]],
            'child' => [%w[object packing attributes placeholder], %w[type internal-child]],
            'packing' => [%w[property], []], 'placeholder' => [[], []],
            'columns' => [%w[column], []], 'column' => [[], %w[type]],
            'data' => [%w[row], []], 'row' => [%w[col row], []], 'col' => [[], %w[id translatable]],
            'items' => [%w[item], []], 'item' => [[], %w[id translatable]],
            'attributes' => [%w[attribute], []], 'attribute' => [[], %w[name value]],
            'signal' => [[], %w[name handler swapped after]],
          }.freeze
          COMMON = {
            'can-focus' => [:can_focus=, :boolean],
            'visible' => [:visible, :boolean], 'sensitive' => [:sensitive=, :boolean],
            'width-request' => [:set_width_request, :integer], 'height-request' => [:set_height_request, :integer],
            'border-width' => [:set_border_width, :integer], 'tooltip-text' => [:set_tooltip_text, :text],
            'halign' => [:halign=, :symbol], 'hexpand' => [:set_hexpand, :boolean], 'vexpand' => [:set_vexpand, :boolean],
            'margin-start' => [:set_margin_start, :integer], 'margin-end' => [:set_margin_end, :integer],
            'margin-left' => [:set_margin_left, :integer], 'margin-right' => [:set_margin_right, :integer],
            'margin-top' => [:margin_top, :integer], 'margin-bottom' => [:margin_bottom, :integer],
          }.freeze
          PROPERTIES = {
            Window             => { 'title' => [:title=, :text], 'default-width' => [:default_width=, :integer],
                        'default-height' => [:default_height=, :integer], 'resizable' => [:resizable=, :boolean] },
            Grid               => { 'row-spacing' => [:row_spacing=, :integer], 'column-spacing' => [:column_spacing=, :integer],
                      'column-homogeneous' => [:column_homogeneous=, :boolean] },
            Label              => { 'label' => [:text=, :text], 'wrap' => [:wrap=, :boolean], 'xalign' => [:label_align, :number],
                       'selectable' => [:set_selectable, :boolean], 'width-chars' => [:set_width_chars, :integer] },
            Entry              => { 'text' => [:text=, :text], 'placeholder-text' => [:placeholder_text=, :text],
                       'editable' => [:editable=, :boolean], 'xalign' => [:xalign=, :number], 'width-chars' => [:set_width_chars, :integer] },
            Button             => { 'label' => [:label=, :text], 'receives-default' => [:receives_default=, :boolean] },
            CheckButton        => { 'draw-indicator' => [:draw_indicator=, :boolean], 'receives-default' => [:receives_default=, :boolean] },
            Frame              => { 'label-xalign' => [:label_xalign=, :number], 'shadow-type' => [:shadow_type=, :symbol] },
            ScrolledWindow     => { 'shadow-type' => [:shadow_type=, :symbol] },
            ToggleButton       => { 'label' => [:label=, :text], 'active' => [:set_active, :boolean] },
            RadioButton        => { 'active' => [:set_active, :boolean] },
            SpinButton         => { 'value' => [:set_value, :number], 'digits' => [:digits=, :integer], 'numeric' => [:numeric=, :boolean] },
            ComboBox           => { 'active' => [:active=, :integer], 'entry-text-column' => [:entry_text_column=, :integer] },
            TextView           => { 'editable' => [:editable=, :boolean], 'cursor-visible' => [:cursor_visible=, :boolean],
                          'wrap-mode' => [:wrap_mode=, :symbol] },
            TextBuffer         => { 'text' => [:set_text, :text] },
            Expander           => { 'label' => [:set_label, :text], 'expanded' => [:set_expanded, :boolean] },
            TreeView           => { 'headers-visible' => [:headers_visible=, :boolean] },
            TreeViewColumn     => { 'title' => [:title=, :text], 'resizable' => [:resizable=, :boolean],
                                'visible' => [:visible=, :boolean], 'fixed-width' => [:fixed_width=, :integer],
                                'sort-column-id' => [:sort_column_id=, :integer] },
            TreeSelection      => { 'mode' => [:mode=, :symbol] },
            CellRendererText   => { 'editable' => [:editable=, :boolean] },
            CellRendererToggle => { 'activatable' => [:activatable=, :boolean] },
            CellRendererCombo  => { 'text-column' => [:text_column=, :integer], 'has-entry' => [:has_entry=, :boolean] },
          }.freeze

          # Creates a Builder owned by the current script, including subclass instances.
          def initialize
            super
            @objects, @by_id, @signals = [], {}, []
          end

          # @return [Array<Object>] document-order snapshot, including anonymous objects
          def objects = @objects.dup

          # @param id [String, Symbol] XML identifier
          # @return [Object, nil] the original object, or nil for an unknown identifier
          def get_object(id) = @by_id[id.to_s]
          alias [] get_object

          # Parses bounded local XML without evaluating Ruby or resolving external entities.
          # Failed additions preserve previously loaded IDs and detach all new observers.
          # @param xml [String] complete interface document
          # @return [Builder] self
          # @raise [BuilderError] unsupported or invalid XML, with object/property context
          def add_from_string(xml)
            session.synchronize do
              @location = nil
              fail_at(nil, 'document', 'expected bounded XML text') unless xml.is_a?(String) && xml.bytesize <= MAX_BYTES
              fail_at(nil, 'document', 'DTD and entity declarations are unsupported') if xml.match?(/<!\s*(?:DOCTYPE|ENTITY)\b/i)
              document = REXML::Document.new(xml)
              fail_at(nil, 'document', 'root must be interface') unless document.root&.name == 'interface'
              check_elements(document.root)
              @elements = REXML::XPath.match(document, '//object')
              fail_at(nil, 'objects', 'object limit exceeded') if @objects.length + @elements.length > MAX_OBJECTS
              @pending_ids, @built, @building, @created, @pending_signals, @visible_windows = {}, {}, {}, [], [], []
              @object_elements = {}.compare_by_identity
              @positions = @elements.each_with_index.to_h
              @elements.each do |element|
                fail_at(element, 'class', 'unsupported class') unless CLASSES.key?(element.attributes['class'])
                id = element.attributes['id']
                next unless id
                fail_at(element, 'id', 'empty or duplicate identifier') if id.empty? || @by_id.key?(id) || @pending_ids.key?(id)
                @pending_ids[id] = element
              end
              check_properties
              @elements.each { |element| build(element) }
              @elements.each { |element| load_model(element) }
              @elements.each { |element| bind_model(element) }
              @elements.reverse_each { |element| compose(element) }
              @elements.each { |element| finish(element) }
              @created.each { |object| validate_object(object) }
              @visible_windows.each(&:show)
              @objects.concat(@elements.map { |element| @built.fetch(element) })
              @pending_ids.each { |id, element| @by_id[id] = @built.fetch(element) }
              @signals.concat(@pending_signals)
              self
            rescue BuilderError
              discard_pending
              raise
            rescue REXML::ParseException
              discard_pending
              fail_at(nil, 'document', 'malformed XML')
            rescue StandardError => error
              discard_pending
              detail = error.is_a?(UnsupportedOperation) ? error.message[/operation=([^ ]+)/, 1] : error.class.name.split('::').last
              detail += " field=#{error.field}" if error.is_a?(Lich::WebUI::Error) && error.field
              fail_at(@location&.first, @location&.last || 'document', "rejected by shim: #{detail}")
            ensure
              @elements = @pending_ids = @built = @building = @created = @pending_signals = @visible_windows = nil
              @positions = @object_elements = nil
            end
          end

          # Reads a local file using the same bounded, transactional parser.
          # @param path [String] local XML filename
          # @return [Builder] self
          def add_from_file(path)
            fail_at(nil, 'file', 'expected local filename') unless path.is_a?(String) && !path.include?("\0")
            xml = File.open(path, 'rb') { |file| file.read(MAX_BYTES + 1) }
            add_from_string(xml)
          rescue SystemCallError, IOError
            fail_at(nil, 'file', 'cannot read local XML file')
          end

          # Resolves every handler before connecting any; repeated calls connect only new signals.
          # Fixed-arity methods receive the supported prefix of emitted GTK arguments.
          # Handler return values (including close vetoes) and exceptions are preserved.
          # @yieldparam name [String] declared handler name
          # @yieldreturn [Method, Proc] callback; without a block, resolve on this Builder
          # @return [Builder] self
          def connect_signals
            session.synchronize do
              connections = @signals.map do |object, name, handler, element|
                callable = block_given? ? yield(handler) : method(handler)
                fail_at(element, "signal:#{name}", 'handler must be a Method or Proc') unless callable.is_a?(Method) || callable.is_a?(Proc)
                [object, name, callable]
              rescue NameError
                fail_at(element, "signal:#{name}", "missing handler #{handler}")
              end
              connections.each do |object, name, callable|
                object.signal_connect(name) do |*args|
                  callable.arity >= 0 ? callable.call(*args.take(callable.arity)) : callable.call(*args)
                end
              end
              @signals.clear
              self
            end
          end

          private

          # Reports all unmapped properties in one preflight, before allocating objects.
          # This is not an exhaustive behavior audit: constructor/value failures are
          # subsequently reported at their actual failing phase.
          def check_properties
            issues = []
            @elements.each do |element|
              klass = CLASSES.fetch(element.attributes['class'])
              allowed = CONSTRUCTOR_PROPERTIES.fetch(element.attributes['class'], [])
              allowed += COMMON.keys if klass <= Widget
              PROPERTIES.each { |type, entries| allowed += entries.keys if klass <= type }
              properties(element).each_key do |name|
                next if allowed.include?(name)
                issues << issue(element, name, 'unsupported property; requires an explicit mapping')
              end
            end
            return if issues.empty?
            first = issues.first
            fail_at(@elements.find { |element| (element.attributes['id'] || '(anonymous)') == first[:object] && element.attributes['class'] == first[:xml_class] },
                    first[:property], "#{first[:reason]} (#{issues.length} unmapped declarations)", issues: issues)
          end

          # Rejects unsupported XML syntax instead of silently ignoring unvisited nodes.
          def check_elements(element, depth = 0)
            fail_at(element, 'nesting', 'XML depth limit exceeded') if depth > MAX_DEPTH
            shape = ELEMENTS[element.name]
            fail_at(element, element.name, 'unsupported XML element') unless shape
            element.attributes.each_attribute do |attribute|
              fail_at(element, attribute.name, 'unsupported XML attribute') unless shape.last.include?(attribute.name)
            end
            if element.name == 'requires'
              valid = element.attributes['lib'] == 'gtk+' && element.attributes['version'].to_s.match?(/\A3\.(?:[0-9]|1[0-9]|2[0-4])\z/)
              fail_at(element, 'requires', 'only GTK 3 through 3.24 is supported') unless valid
            end
            element.elements.each do |child|
              fail_at(child, child.name, "not supported inside #{element.name}") unless shape.first.include?(child.name)
              check_elements(child, depth + 1)
            end
            if element.name == 'object'
              %w[columns data items attributes].each do |name|
                fail_at(element, name, 'duplicate section') if element.elements.to_a(name).length > 1
              end
            elsif element.name == 'child'
              %w[packing attributes].each do |name|
                fail_at(element, name, 'duplicate section') if element.elements.to_a(name).length > 1
              end
            end
            if !%w[property col item attribute].include?(element.name) && element.texts.any? { |text| !text.value.strip.empty? }
              fail_at(element, 'text', 'unexpected text outside a value element')
            end
          end

          # Preserves all text characters; only explicitly numeric/boolean properties coerce.
          def convert(value, kind, element, name)
            @location = [element, name]
            case kind
            when :text then value
            when :symbol then value.strip.tr('-', '_').to_sym
            when :integer then Integer(value, 10)
            when :number
              number = Float(value)
              fail_at(element, name, 'number must be finite') unless number.finite?
              number
            when :boolean
              case value.strip.downcase
              when 'true', 'yes', '1' then true
              when 'false', 'no', '0' then false
              else fail_at(element, name, 'expected boolean')
              end
            end
          rescue ArgumentError
            fail_at(element, name, "expected #{kind}")
          end

          def properties(element)
            element.elements.to_a('property').each_with_object({}) do |property, result|
              name = property.attributes['name'].to_s.tr('_', '-')
              fail_at(element, name, 'empty or duplicate property') if name.empty? || result.key?(name)
              result[name] = property.texts.map(&:value).join
            end
          end

          # References are load-local: no failed load can bind or mutate an older graph.
          def reference(id, element, name)
            target = @pending_ids[id]
            fail_at(element, name, "unresolved load-local reference #{id}") unless target
            build(target)
          end

          # Construction order follows dependencies, while objects preserves XML order.
          def build(element)
            return @built[element] if @built.key?(element)
            fail_at(element, 'reference', 'cyclic construction dependency') if @building[element]
            @building[element] = true
            @location = [element, 'constructor']
            klass = CLASSES.fetch(element.attributes['class'])
            props = properties(element)
            object = construct(klass, props, element)
            fail_at(element, 'internal-child', 'internal object already declared') if @object_elements.key?(object)
            @created << object
            @object_elements[object] = element
            anonymous = "__anonymous_#{@objects.length + @positions.fetch(element) + 1}"
            anonymous += '_' while @pending_ids.key?(anonymous) || @by_id.key?(anonymous)
            object.instance_variable_set(:@builder_name, element.attributes['id'] || anonymous)
            @built[element] = object
            object.hide if object.is_a?(Widget) && !object.is_a?(Window) && !object.is_a?(ComboEntry)
            props.each { |name, value| apply_property(object, name, value, element) unless name == 'can-focus' }
            # Focus acceptance depends on the completed configuration (e.g. editable),
            # not the order Glade happened to serialize the properties.
            apply_property(object, 'can-focus', props['can-focus'], element) if props.key?('can-focus')
            @building.delete(element)
            object
          end

          def construct(klass, props, element)
            case klass.name.split('::').last
            when 'Box' then klass.new(convert(props.delete('orientation') || 'horizontal', :symbol, element, 'orientation'), convert(props.delete('spacing') || '0', :integer, element, 'spacing'))
            when 'HBox', 'VBox' then klass.new(convert(props.delete('homogeneous') || 'false', :boolean, element, 'homogeneous'), convert(props.delete('spacing') || '0', :integer, element, 'spacing'))
            when 'Table' then klass.new(convert(props.delete('n-rows') || '1', :integer, element, 'n-rows'), convert(props.delete('n-columns') || '1', :integer, element, 'n-columns'))
            when 'Adjustment'
              values = %w[value lower upper step-increment page-increment page-size].map do |name|
                convert(props.delete(name) || '0', :number, element, name)
              end
              klass.new(*values)
            when 'SpinButton'
              adjustment = reference(props.delete('adjustment'), element, 'adjustment')
              klass.new(adjustment, convert(props.delete('climb-rate') || '0', :number, element, 'climb-rate'), convert(props.delete('digits') || '0', :integer, element, 'digits'))
            when 'ListStore', 'TreeStore'
              columns = element.elements.to_a('columns/column').map do |column|
                COLUMN_TYPES[column.attributes['type']] || fail_at(element, 'columns', 'unsupported scalar column type')
              end
              klass.new(*columns)
            when 'Frame' then klass.new(props.delete('label'))
            when 'Expander' then klass.new(props.delete('label') || '')
            when 'Button' then klass.new(label: props.delete('label') || '', use_underline: false)
            when 'ToggleButton', 'CheckButton' then klass.new(label: props.delete('label') || '')
            when 'ComboBox', 'ComboBoxText' then klass.new(entry: convert(props.delete('has-entry') || 'false', :boolean, element, 'has-entry'))
            when 'TextView' then klass.new(props.key?('buffer') ? reference(props.delete('buffer'), element, 'buffer') : nil)
            when 'Separator' then klass.new(convert(props.delete('orientation') || 'horizontal', :symbol, element, 'orientation'))
            when 'TreeSelection'
              child, parent = element.parent, element.parent.parent
              fail_at(element, 'internal-child', 'selection must belong to a TreeView') unless child.attributes['internal-child'] == 'selection' && parent.attributes['class'] == 'GtkTreeView'
              build(parent).selection
            when 'Entry'
              if element.parent.attributes['internal-child'] == 'entry'
                owner = build(element.parent.parent)
                fail_at(element, 'internal-child', 'entry requires an editable combo') unless owner.is_a?(ComboBox) && owner.child
                owner.child
              else
                klass.new
              end
            when 'RadioButton'
              group = props.key?('group') ? reference(props.delete('group'), element, 'group') : nil
              klass.new(group, label: props.delete('label') || '')
            else klass.new
            end
          end

          # Bind populated models before renderer mappings select a non-default column.
          # Construction references (buffers, adjustments and radio groups) resolve earlier.
          def bind_model(element)
            props = properties(element)
            return unless props.key?('model')
            @location = [element, 'model']
            @built.fetch(element).model = reference(props['model'], element, 'model')
          end

          def apply_property(object, name, value, element)
            return if %w[model active entry-text-column].include?(name) && (object.is_a?(ComboBox) || name == 'model')
            @location = [element, name]
            mapping = PROPERTIES.filter_map { |type, entries| entries[name] if object.is_a?(type) }.last
            mapping ||= COMMON[name] if object.is_a?(Widget)
            fail_at(element, name, 'unsupported property; requires an explicit mapping') unless mapping
            method, kind = mapping
            converted = convert(value, kind, element, name)
            case method
            when :visible
              if object.is_a?(Window)
                @visible_windows << object if converted
              else
                converted ? object.show : object.hide
              end
            when :margin_top, :margin_bottom
              side = method == :margin_top ? :top : :bottom
              current = object.instance_variable_get(:@props)[:margin]
              margins = current.is_a?(Hash) ? current : %i[top right bottom left].to_h { |key| [key, current || 0] }
              object.send(:write, :margin, margins.merge(side => converted))
            when :label_align then object.set_alignment(converted, 0.5)
            else object.public_send(method, converted)
            end
          end

          # Parent-specific child roles never fall back to an arbitrary empty container.
          def compose(element)
            object = @built.fetch(element)
            @location = [element, 'children']
            children = element.elements.to_a('child')
            pages = []
            children.each do |child|
              objects = child.elements.to_a('object')
              placeholders = child.elements.to_a('placeholder')
              valid = objects.length == 1 && placeholders.empty?
              valid ||= objects.empty? && placeholders.length == 1 && child.attributes.empty? && child.elements.size == 1
              fail_at(element, 'child', 'expected exactly one object or an unadorned placeholder') unless valid
              next if objects.empty?
              target = @built.fetch(objects.first)
              internal, role = child.attributes['internal-child'], child.attributes['type']
              if internal
                valid = internal == 'selection' && object.is_a?(TreeView) && target.equal?(object.selection)
                valid ||= internal == 'entry' && object.is_a?(ComboBox) && target.equal?(object.child)
                fail_at(element, 'internal-child', 'unsupported internal child') unless valid && !role && !child.elements['packing'] && !child.elements['attributes']
                next
              end
              if child.elements['attributes'] && !object.is_a?(TreeViewColumn) && !object.is_a?(ComboBox)
                fail_at(element, 'attributes', 'cell bindings require a renderer parent')
              end
              packing = child.elements['packing'] ? properties(child.elements['packing']) : {}
              if object.is_a?(Notebook)
                fail_at(element, 'packing', 'unsupported notebook packing') unless (packing.keys - %w[tab-fill position]).empty?
                if packing.key?('position')
                  expected = object.children.length
                  fail_at(element, 'position', 'notebook position must match document order') unless convert(packing['position'], :integer, element, 'position') == expected
                end
                # Tabs do not expand in this bounded surface, so either fill request
                # has the same natural allocation. Expanded tab packing is still refused.
                convert(packing['tab-fill'], :boolean, element, 'tab-fill') if packing.key?('tab-fill')
                if role == 'tab'
                  fail_at(element, 'tab', 'tab requires a preceding page and plain label') unless pages.last && target.is_a?(Label)
                  fail_at(element, 'tab attributes', 'caption styling is not supported') if objects.first.elements['attributes']
                  object.append_page(pages.pop, target)
                else
                  fail_at(element, 'child', 'notebook pages require paired tab labels') unless role.nil? && pages.empty?
                  pages << target
                end
              elsif (object.is_a?(Frame) || object.is_a?(Expander)) && role == 'label'
                fail_at(element, 'label', 'frame label must be plain text') unless target.is_a?(Label)
                fail_at(element, 'packing', 'caption packing is unsupported') unless packing.empty?
                fail_at(element, 'label attributes', 'caption styling is not supported') if objects.first.elements['attributes']
                object.is_a?(Frame) ? object.set_label_widget(target) : object.set_label(target.text)
              else
                fail_at(element, 'child type', 'unsupported child role') if role
                attach(object, target, packing, child)
              end
            end
            fail_at(element, 'tab', 'page is missing a tab label') unless pages.empty?
          end

          def attach(parent, child, packing, element)
            @location = [element, 'packing']
            case parent
            when Grid, Table
              allowed = parent.instance_of?(Grid) ? %w[left-attach top-attach width height] : %w[left-attach right-attach top-attach bottom-attach]
              fail_at(element, 'packing', 'unsupported grid placement') unless (packing.keys - allowed).empty?
              values = allowed.map { |name| convert(packing.fetch(name, %w[left-attach top-attach].include?(name) ? '0' : '1'), :integer, element, name) }
              # Legacy attach initializes padding through margin; retain explicit XML margins.
              margin = child.instance_variable_get(:@props)[:margin]
              parent.attach(child, *values)
              child.send(:write, :margin, margin) unless margin.nil?
            when Box
              fail_at(element, 'packing', 'unsupported box placement') unless (packing.keys - %w[expand fill padding pack-type position]).empty?
              ending = packing.fetch('pack-type', 'start')
              fail_at(element, 'pack-type', 'expected start or end') unless %w[start end].include?(ending)
              parent.public_send(ending == 'end' ? :pack_end : :pack_start, child,
                                 expand: convert(packing.fetch('expand', 'true'), :boolean, element, 'expand'),
                                 fill: convert(packing.fetch('fill', 'true'), :boolean, element, 'fill'),
                                 padding: convert(packing.fetch('padding', '0'), :integer, element, 'padding'))
              parent.reorder_child(child, convert(packing['position'], :integer, element, 'position')) if packing.key?('position')
            when TreeView
              fail_at(element, 'child', 'expected a column without packing') unless child.is_a?(TreeViewColumn) && packing.empty?
              parent.append_column(child)
            when TreeViewColumn, ComboBox
              fail_at(element, 'child', 'expected one renderer without packing') unless child.is_a?(CellRendererText) && packing.empty?
              attributes = element.elements.to_a('attributes/attribute')
              fail_at(element, 'attributes', 'only one renderer binding is supported') if attributes.length > 1
              parent.pack_start(child, true)
              attributes.each do |attribute|
                fail_at(element, 'attributes', 'renderer binding uses text, not a value attribute') if attribute.attributes['value']
                parent.add_attribute(child, attribute.attributes['name'], convert(attribute.text.to_s, :integer, element, 'column'))
              end
            when Window, Frame, ScrolledWindow, Viewport, Expander
              fail_at(element, 'packing', 'packing unsupported on this container') unless packing.empty?
              parent.add(child)
            else fail_at(element, 'child', 'object cannot contain this child')
            end
          end

          # Applies values that require completed children/models, then records signals.
          def finish(element)
            object = @built.fetch(element)
            props = properties(element)
            if object.is_a?(ComboBox)
              element.elements.each('items/item') do |item|
                fail_at(element, 'item id', 'named combo items are unsupported') if item.attributes['id']
                object.append_text(item.texts.map(&:value).join)
              end
              %w[entry-text-column active].each do |name|
                next unless props.key?(name)
                method, kind = PROPERTIES[ComboBox].fetch(name)
                object.public_send(method, convert(props[name], kind, element, name))
              end
            elsif element.elements['items']
              fail_at(element, 'items', 'items require a combo')
            end
            element.elements.each('attributes/attribute') do |attribute|
              @location = [element, 'attributes']
              valid = object.is_a?(Label) && attribute.attributes['name'] == 'style' && %w[normal italic].include?(attribute.attributes['value'])
              fail_at(element, 'attributes', 'unsupported text attribute') unless valid
              object.send(:write, :font_style, attribute.attributes['value'])
            end
            element.elements.each('signal') { |signal| prepare_signal(object, element, signal) }
          end

          # Store data exists before a forward-referencing combo applies its active index.
          def load_model(element)
            object = @built.fetch(element)
            @location = [element, 'model data']
            if object.is_a?(ListStore)
              element.elements.each('data/row') { |row| populate(object, row) }
            elsif element.elements['data'] || element.elements['columns']
              fail_at(element, 'model data', 'columns/data require a store')
            end
          end

          def populate(model, element, parent = nil)
            row = model.is_a?(TreeStore) ? model.append(parent) : model.append
            seen = []
            element.elements.each('col') do |column|
              index = convert(column.attributes['id'].to_s, :integer, element, 'column id')
              fail_at(element, 'column id', 'duplicate cell') if seen.include?(index)
              seen << index
              kind = { String => :text, Integer => :integer, Float => :number, TrueClass => :boolean }.fetch(model.get_column_type(index))
              row[index] = convert(column.texts.map(&:value).join, kind, element, 'cell')
            end
            element.elements.each('row') do |child|
              fail_at(element, 'row', 'nested rows require TreeStore') unless model.is_a?(TreeStore)
              populate(model, child, row)
            end
          end

          def prepare_signal(object, element, signal)
            name = signal.attributes['name'].to_s.tr('-', '_')
            handler = signal.attributes['handler'].to_s
            %w[after swapped].each do |flag|
              fail_at(element, "signal:#{name}", "#{flag}=true is unsupported") if convert(signal.attributes[flag] || 'false', :boolean, element, flag)
            end
            supported = if object.is_a?(ComboEntry) then ['changed']
                        elsif object.is_a?(Widget)
                          object.send(:signal_map).keys.map { |key| key.tr('-', '_') } + ['destroy']
                        elsif object.is_a?(Adjustment) then %w[changed value_changed]
                        elsif object.is_a?(TreeSelection) then ['changed']
                        elsif object.is_a?(CellRendererText) then [object.signal_name]
                        else []
                        end
            fail_at(element, "signal:#{name}", 'unsupported signal or invalid handler name') unless supported.include?(name) && handler.match?(/\A[a-zA-Z_]\w*[!?]?\z/)
            @pending_signals << [object, name, handler, element]
          end

          def validate_object(object)
            return unless object.is_a?(Widget) && !object.is_a?(ComboEntry)
            element = @object_elements.fetch(object)
            @location = [element, 'component properties']
            Lich::WebUI::Validator.new.validate_component!(object.send(:component_type), object.send(:component_props), owner: 'shim', page_id: nil, cid: nil)
          end

          # No script handlers have been connected on rejected graphs, so teardown cannot
          # invoke user code. Every widget is visited, including unattached label objects.
          def discard_pending
            @created&.reverse_each do |object|
              session.cleanup(object) { object.destroy } if object.is_a?(Widget) && !object.is_a?(ComboEntry)
              object.release if object.is_a?(TreeViewColumn)
            end
          end

          def issue(element, operation, reason)
            node = element
            node = node.parent while node.is_a?(REXML::Element) && node.name != 'object'
            { object: node.is_a?(REXML::Element) ? node.attributes['id'] || '(anonymous)' : '(document)',
              xml_class: node.is_a?(REXML::Element) ? node.attributes['class'] : nil, property: operation, reason: reason }
          end

          def fail_at(element, operation, reason, issues: nil)
            detail = issue(element, operation, reason)
            begin
              session.refuse(self, :Builder)
            rescue UnsupportedOperation => error
              message = "#{error.message} object=#{detail[:object]} xml_class=#{detail[:xml_class]} property=#{operation} reason=#{reason}"
              raise BuilderError.new(message, issues: issues || [detail])
            end
          end
        end
      end
    end
  end
end
