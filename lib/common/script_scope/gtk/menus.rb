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
          def initialize(text = '', use_underline = false, label: text)
            super()
            @props[:label] = menu_label(label, use_underline)
          end

          def label = read(:label)

          # Changes submenu ownership before the control's type is materialized.
          # @return [MenuItem] self
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
          def activate
            session.refuse(self, :activate) if @submenu
            emit_handlers(:activate)
            self
          end

          protected

          def component_type = @submenu ? :group : :button
          def component_props = @submenu ? super.merge(menu: :submenu) : super
          def signal_map = @submenu ? {} : { 'activate' => :activate }
        end

        class SeparatorMenuItem < Widget
          protected

          def component_type = :divider
        end

        # Check and radio menu items reuse existing viewer-local input state and
        # terminal activation, including complete form submission before callbacks.
        class CheckMenuItem < ToggleButton
          include MenuLabel

          def initialize(text = '', use_underline = false, label: text)
            super(label)
            @props[:label] = menu_label(label, use_underline)
          end

          def activate
            set_active(!active?)
            emit_handlers(:activate)
            self
          end

          protected

          def component_props = super.merge(appearance: :menu)
          def signal_map = { 'toggled' => :change, 'activate' => :activate }
        end

        class RadioMenuItem < RadioButton
          include MenuLabel

          # Accepts an initial label or an existing group member and label.
          def initialize(member = nil, label = nil, use_underline = false)
            if member.is_a?(String)
              use_underline = label unless label.nil?
              label = member
              member = nil
            end
            super(member: member, label: label || '')
            @props[:label] = menu_label(@props[:label], use_underline)
          end

          def activate
            set_active(true)
            emit_handlers(:activate)
            self
          end

          protected

          def component_props = super.merge(appearance: :menu)
          def signal_map = { 'toggled' => :change, 'activate' => :activate }
        end

        # Popups are page children with viewer-scoped open state, never OS windows.
        # Submenus remain in the same owner tree for destruction and input commits.
        class Menu < Widget
          def initialize
            super
            @embedded = false
            @props[:open] = false
          end

          # Inserts only supported menu entries and preserves caller order.
          def add(item)
            session.refuse(self, :add) unless [MenuItem, SeparatorMenuItem, CheckMenuItem, RadioMenuItem].any? { |type| item.is_a?(type) }
            super
          end
          alias append add

          def prepend(item) = insert(item, 0)

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
          def popup(parent_shell, parent_item, button, time)
            context = session.pointer_context
            valid = context && parent_shell.nil? && parent_item.nil? && context.last.button == button && context.last.time == time
            session.refuse(self, :popup) unless valid
            popup_at_pointer(context.last)
          end

          # Attaches a popup to the originating window and opens it for one viewer.
          # @return [Menu] self
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

          def popdown = write(:open, false)
          def open? = read(:open)

          protected

          def embed!
            session.refuse(self, :submenu) if @handle
            @embedded = true
          end

          def component_type = @embedded ? :stack : :group
          def input_property = @embedded ? nil : :open

          def component_props
            @embedded ? super.except(:open, :popup_position).merge(gap: 0) : super.merge(menu: :context)
          end

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
