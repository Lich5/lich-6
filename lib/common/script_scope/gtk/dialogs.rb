# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # sbounty and sellunder need informational OK dialogs. Their corrected
        # response handlers use the core future; no nested GTK loop or callback
        # thread is introduced. Parent destruction cancels the outstanding modal.
        class MessageDialog < Widget
          def initialize(parent:, flags:, type:, buttons:, message:)
            super()
            valid_flags = Array(flags) - %i[modal destroy_with_parent]
            session.refuse(self, :new) unless parent.is_a?(Window) && parent.session.equal?(session)
            session.refuse(self, :new) unless valid_flags.empty? && %i[info error].include?(type) && buttons == :ok
            @message = String(message)
            @title = type == :error ? 'Error' : 'Information'
            @dialog_parent = parent
            parent.own_dialog(self)
          end

          def signal_connect(name, &block)
            session.refuse(self, "signal:#{name}") unless name.to_s == 'response' && block
            @response = block
            1
          end

          def show_all
            return self if @future || destroyed?

            @future = session.port.modal(title: @title, body: @message,
                                         buttons: [{ id: 'ok', label: 'OK' }], no_viewer: :abort)
            @future.then do |result|
              session.synchronize { @response&.call(self, :ok) if result.button == 'ok' && !destroyed? }
            ensure
              destroy
            end
            self
          end
          alias show show_all

          def run
            session.refuse(self, :run) if session.in_callback?
            show_all
            @future&.await&.button == 'ok' ? :ok : :cancel
          end

          def destroy
            return self if destroyed?

            mark_destroyed
            @dialog_parent.forget_dialog(self)
            @future&.cancel(reason: :owner)
            self
          end
        end

        # Both accepted separator consumers request horizontal section breaks.
        class Separator < Widget
          def initialize(orientation)
            super()
            session.refuse(self, :new) unless orientation == :horizontal
          end

          protected

          def component_type = :divider
        end

        class HSeparator < Separator
          def initialize
            super(:horizontal)
          end
        end
      end
    end
  end
end
