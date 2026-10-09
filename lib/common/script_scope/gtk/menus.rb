# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # Bounded viewport coordinates from one authenticated pointer callback.
        PointerEvent = Data.define(:x, :y, :button, :time, :state)

        # Literal menu labels. Mnemonic-bearing labels require keyboard support
        # beyond this adapter; they are refused rather than silently stripped.
        module MenuLabel
          # Label replacements preserve the constructor's explicit mnemonic policy.
          # @return [Widget] self
          def set_label(value) = write(:label, menu_label(value, @use_underline))
          alias label= set_label

          private

          # Validates literal labels and retains the constructor's mnemonic policy.
          # @return [String] unchanged label, never stripped or interpreted as markup
          # @raise [UnsupportedOperation] for invalid input or requested mnemonic syntax
          def menu_label(label, underline)
            session.refuse(self, :label) unless label.is_a?(String) && [true, false].include?(underline)
            session.refuse(self, :mnemonic) if underline && label.include?('_')
            @use_underline = underline
            label
          end
        end

        class MenuItem < Widget
          include MenuLabel
          attr_reader :submenu

          # Creates a literal action or, before publication, a submenu trigger.
          # @param text [String] legacy positional label
          # @param use_underline [Boolean] mnemonic flag; labels containing '_' refuse when true
          # @param label [String] keyword label overriding text
          def initialize(text = '', use_underline = false, label: text)
            super()
            @props[:label] = menu_label(label, use_underline)
          end

          # @return [String] literal action or submenu label
          def label = read(:label)

          # Changes submenu ownership before the control's type is materialized.
          # @param menu [Menu] unparented menu from the same Script session
          # @return [MenuItem] self
          # @raise [UnsupportedOperation] for an owned/foreign menu or a published item
          def set_submenu(menu)
            session.refuse(self, :set_submenu) if @handle || !menu.is_a?(Menu) || !menu.session.equal?(session) || menu.parent
            session.synchronize do
              remove(@submenu) if @submenu
              menu.send(:embed!)
              add(menu)
              @submenu = menu
            end
            self
          end
          alias submenu= set_submenu

          # Executes explicit script activation through the ordered local handlers.
          # @return [MenuItem] self
          # @raise [UnsupportedOperation] for submenu triggers, which open in the browser
          def activate
            session.refuse(self, :activate) if @submenu
            emit_handlers(:activate)
            self
          end

          protected

          # @return [Symbol] submenu container or terminal action
          def component_type = @submenu ? :group : :button
          # @return [Hash] shared submenu presentation only when this item owns a menu
          def component_props = @submenu ? super.merge(menu: :submenu) : super
          # @return [Hash] submenu opening has no script activation callback
          def signal_map = @submenu ? {} : { 'activate' => :activate }
        end

        class SeparatorMenuItem < Widget
          protected

          # @return [Symbol] noninteractive separator in the shared renderer
          def component_type = :divider
        end

        # Check and radio menu items reuse existing viewer-local input state and
        # terminal activation, including complete form submission before callbacks.
        class CheckMenuItem < ToggleButton
          include MenuLabel

          # Creates an initially unchecked menu choice with the literal-label policy.
          # @param text [String] legacy positional label
          # @param use_underline [Boolean] whether mnemonic syntax was requested
          # @param label [String] keyword label overriding text
          def initialize(text = '', use_underline = false, label: text)
            super(label)
            @props[:label] = menu_label(label, use_underline)
          end

          # Toggles first, delivering changed notifications before activation handlers.
          # @return [CheckMenuItem] self
          def activate
            set_active(!active?)
            emit_handlers(:activate)
            self
          end

          protected

          # @return [Hash] existing toggle state with menu presentation
          def component_props = super.merge(appearance: :menu)
          # @return [Hash] state notification and terminal activation are distinct events
          def signal_map = { 'toggled' => :change, 'activate' => :activate }
        end

        class RadioMenuItem < RadioButton
          include MenuLabel

          # Accepts an initial label or an existing group member and label.
          # @param member [RadioButton, String, nil] same-session group member or first label
          # @param label [String, Boolean, nil] label, or mnemonic flag in label-first form
          # @param use_underline [Boolean] whether mnemonic syntax was requested
          def initialize(member = nil, label = nil, use_underline = false)
            if member.is_a?(String)
              use_underline = label unless label.nil?
              label = member
              member = nil
            end
            super(member: member, label: label || '')
            @props[:label] = menu_label(@props[:label], use_underline)
          end

          # Selects exclusively before activation; an already selected item still activates.
          # @return [RadioMenuItem] self
          def activate
            set_active(true)
            emit_handlers(:activate)
            self
          end

          protected

          # @return [Hash] existing radio-group identity and state with menu presentation
          def component_props = super.merge(appearance: :menu)
          # @return [Hash] group transitions precede the terminal activation callback
          def signal_map = { 'toggled' => :change, 'activate' => :activate }
        end

        # Popups are page children with viewer-scoped open state, never OS windows.
        # Submenus remain in the same owner tree for destruction and input commits.
        class Menu < Widget
          # Creates a closed popup; assigning it as a submenu switches to embedded content.
          def initialize
            super
            @embedded = false
            @props[:open] = false
          end

          # Inserts only supported menu entries and preserves caller order.
          # @param item [MenuItem, SeparatorMenuItem, CheckMenuItem, RadioMenuItem] entry
          # @return [Menu] self
          def add(item)
            session.refuse(self, :add) unless [MenuItem, SeparatorMenuItem, CheckMenuItem, RadioMenuItem].any? { |type| item.is_a?(type) }
            super
          end
          alias append add

          # @return [Menu] self after inserting the entry before all existing entries
          def prepend(item) = insert(item, 0)

          # Inserts or reorders a supported entry at a bounded zero-based position.
          # @param item [Widget] supported same-session menu entry
          # @param position [Integer] zero through the current child count
          # @return [Menu] self
          def insert(item, position)
            session.refuse(self, :insert) unless position.is_a?(Integer) && position.between?(0, children.length)
            add(item)
            reorder_child(item, position)
          end

          # Opens only from the matching pointer callback, in that viewer's window.
          # @param parent_shell [nil] detached popup only
          # @param parent_item [nil] detached popup only
          # @param button [Integer] active pointer button
          # @param time [Integer] active pointer time
          # @return [Menu] self
          # @raise [UnsupportedOperation] outside the matching pointer callback
          def popup(parent_shell, parent_item, button, time)
            context = session.pointer_context
            valid = context && parent_shell.nil? && parent_item.nil? && context.last.button == button && context.last.time == time
            session.refuse(self, :popup) unless valid
            popup_at_pointer(context.last)
          end

          # Attaches a popup to the originating window and opens it for one viewer.
          # @param event [PointerEvent, nil] exact event from the callback, or its implicit event
          # @return [Menu] self
          # @raise [UnsupportedOperation] for embedded, foreign-window or nonpointer use
          def popup_at_pointer(event = nil)
            context = session.pointer_context
            session.refuse(self, :popup_at_pointer) unless context && !@embedded && (event.nil? || context.last.equal?(event))
            widget, pointer = context
            root = widget.toplevel
            session.refuse(self, :popup_at_pointer) unless root.is_a?(Window) && (!parent || parent.equal?(root))
            root.add(self) unless parent
            root.children.grep(Menu).each { |menu| menu.popdown unless menu.equal?(self) }
            show_all
            write(:popup_position, [pointer.x, pointer.y])
            write(:open, true)
          end

          # @return [Menu] self after closing only the active viewer's popup
          def popdown = write(:open, false)
          # @return [Boolean] popup state for the current viewer or retained default
          def open? = read(:open)

          protected

          # Selects inline submenu contents before materialization fixes the core type.
          # @raise [UnsupportedOperation] if the menu has already been materialized
          def embed!
            session.refuse(self, :submenu) if @handle
            @embedded = true
          end

          # @return [Symbol] inline contents or a viewer-scoped popup container
          def component_type = @embedded ? :stack : :group
          # @return [Symbol, nil] only standalone popups own open state
          def input_property = @embedded ? nil : :open

          # Removes popup-only fields from submenu contents before core validation.
          # @return [Hash] presentation properties for the chosen menu form
          def component_props
            @embedded ? super.except(:open, :popup_position).merge(gap: 0) : super.merge(menu: :context)
          end

          # Maps legacy popup dismissal names to the single core dismissal event.
          # @return [Hash] embedded contents do not own dismissal signals
          def signal_map
            @embedded ? {} : { 'deactivate' => :dismiss, 'selection-done' => :dismiss, 'hide' => :dismiss }
          end
        end
      end

      module Gdk
        module EventMask
          BUTTON_PRESS_MASK = 1 << 8
        end
        BUTTON_PRESS_MASK = EventMask::BUTTON_PRESS_MASK
      end
    end
  end
end
