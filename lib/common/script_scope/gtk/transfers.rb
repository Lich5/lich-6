# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        module TargetFlags
          SAME_APP = :same_app
        end

        # A bounded same-application text-row transfer descriptor, not a native target.
        class TargetEntry < ModelObject
          attr_reader :target, :flags, :info

          def initialize(target, flags, info)
            super()
            session.refuse(self, :new) unless target == 'STRING' && flags == TargetFlags::SAME_APP && info == 0
            @target, @flags, @info = target, flags, info
          end
        end

        # Data never comes from an arbitrary browser payload: the source callback
        # produces it from a validated live row in the same viewer/page.
        class SelectionData < ModelObject
          attr_reader :text

          def set(type, text)
            session.style_operation(self, :set) do
              valid = type == Gdk::Selection::TYPE_STRING && text.is_a?(String) && text.valid_encoding? &&
                      text.encoding.ascii_compatible? && text.length <= Lich::WebUI::Contract::BOUNDS[:input_text]
              session.refuse(self, :set) unless valid
              @text = text.dup.freeze
            end
          end

          # Legacy callbacks write literal text through the same bounded data channel.
          def text=(text)
            set(Gdk::Selection::TYPE_STRING, text)
          end
        end

        # Script callbacks own model changes. Completion acknowledges their result;
        # it never performs a second deletion or automatic model transfer.
        class DragContext < ModelObject
          ACTION_MOVE = :move
          def finish(success:, delete:, time:)
            session.refuse(self, :finish) unless [true, false].include?(success) && delete == false && time == Gdk::CURRENT_TIME
          end
        end

        # Legacy module spelling delegates to the same owner-bound TreeView protocol.
        module Drag
          TARGET_SAME_APP = TargetFlags::SAME_APP
          DEST_DEFAULT_ALL = :all

          def self.source_set(widget, mask, targets, action)
            Gtk.session.refuse(self, :source_set) unless widget.is_a?(TreeView)
            widget.drag_source_set(mask, targets, action)
          end

          def self.dest_set(widget, defaults, targets, action)
            Gtk.session.refuse(self, :dest_set) unless widget.is_a?(TreeView)
            widget.drag_dest_set(defaults, targets, action)
          end
        end

        class TreeView
          # Only primary-button, same-app text MOVE transfers are admitted.
          def drag_source_set(mask, targets, action)
            session.style_operation(self, :drag_source_set) do
              session.refuse(self, :drag_source_set) if destroyed?
              normalized = mask == :button1_mask ? Gdk::ModifierType::BUTTON1_MASK : mask
              enable_model_drag_source(normalized, legacy_transfer_targets(targets), action)
            end
          end

          def drag_dest_set(defaults, targets, action)
            session.style_operation(self, :drag_dest_set) do
              session.refuse(self, :drag_dest_set) unless !destroyed? && defaults == :all
              enable_model_drag_dest(legacy_transfer_targets(targets), action)
            end
          end

          # Accepts only the measured primary-button, same-app String MOVE protocol.
          def enable_model_drag_source(mask, targets, action)
            session.refuse(self, :enable_model_drag_source) unless mask == Gdk::ModifierType::BUTTON1_MASK
            configure_transfer(targets, action)
            @drag_source = true
            self
          end

          def enable_model_drag_dest(targets, action)
            configure_transfer(targets, action)
            @drag_destination = true
            self
          end

          # Drag callbacks are paired on a validated drop, never on cancelled drags.
          # No arbitrary formats, desktop/file drops, or cross-window transfers.
          def signal_connect(name, &handler)
            signal = name.to_s.tr('-', '_')
            return super unless %w[drag_data_get drag_data_received].include?(signal)
            session.refuse(self, signal) unless handler && (signal == 'drag_data_get' ? @drag_source : @drag_destination)
            (@drag_handlers ||= Hash.new { |hash, key| hash[key] = [] })[signal] << handler
            @drag_handlers.values.sum(&:length)
          end

          protected

          def dispatch_row_drop(context)
            payload = context.payload
            session.refuse(self, :row_drop) unless @drag_destination
            published_source = context.page.last_render.tree.each.find { |component| component.cid == payload[:source] }
            pending = [toplevel]
            source = nil
            until pending.empty?
              widget = pending.pop
              source = widget if widget.is_a?(TreeView) && widget.send(:transfer_source?, published_source)
              pending.concat(widget.children)
            end
            valid = source.is_a?(TreeView) && source.instance_variable_get(:@drag_source) && source.model&.find_key(payload[:row])
            session.refuse(self, :row_drop) unless valid
            source.select_keys([payload[:row]])
            data, context = SelectionData.new, DragContext.new
            source.send(:emit_drag, 'drag_data_get', context, data, 0, Gdk::CURRENT_TIME)
            return if data.text.nil?
            emit_drag('drag_data_received', context, 0, 0, data, 0, Gdk::CURRENT_TIME)
          end

          def emit_drag(signal, *args)
            (@drag_handlers || {}).fetch(signal, []).dup.each { |handler| handler.call(self, *args) }
          end

          private

          def legacy_transfer_targets(targets)
            valid = targets.is_a?(Array) && targets.size == 1 && targets.first.is_a?(Array) &&
                    targets.first.size == 3 && %w[text/plain STRING].include?(targets.first[0]) &&
                    targets.first[1] == TargetFlags::SAME_APP && targets.first[2] == 0
            session.refuse(self, :drag_targets) unless valid
            [TargetEntry.new('STRING', TargetFlags::SAME_APP, 0)]
          end

          # Column identities are generated by each shim column and cannot be shared
          # between views. Match those published identities, never an adapter CID format.
          def transfer_source?(component)
            @drag_source && @handle && component&.type == :table && !visible_columns.empty? &&
              visible_columns.map(&:key) == component.props[:columns].map { |column| column[:key] }
          end

          def configure_transfer(targets, action)
            valid = targets.is_a?(Array) && targets.length == 1 && targets.first.instance_of?(TargetEntry)
            valid &&= targets.first.session.equal?(session) && action == Gdk::DragAction::MOVE
            session.refuse(self, :model_drag) unless valid && !@handle && selection.mode == :single
            session.degrade(:drag_callbacks, 'same-page text row callbacks run together on accepted drop; cancelled drags do not invoke data-get')
            @props[:transfer_group] = 'gtk-string-move'
          end
        end
      end

      module Gdk
        CURRENT_TIME = 0
        DragContext = Gtk::DragContext

        module Window
          BUTTON1_MASK = :button1
        end

        module ModifierType
          BUTTON1_MASK = :button1
        end

        module DragAction
          MOVE = :move
        end

        module Selection
          TYPE_STRING = :string
        end
      end
    end
  end
end
