# frozen_string_literal: true

require_relative '../../webui'
require_relative '../frontend_editor'

module Lich
  module Common
    class WebUILauncher
      # Native frontend editor. Presentation and validation are adapted from
      # Nisugi's PR #1652; persistence and discovery run on the launcher worker.
      # The render path consumes cached data and never performs discovery or IO.
      class FrontendTab
        CAPABILITIES_PER_ROW = 3

        def initialize(data_dir:, locator:, executor:, on_change:, on_catalog_change: proc {})
          @data_dir = data_dir
          @frontend_locator = locator
          @executor = executor
          @on_change = on_change
          @on_catalog_change = on_catalog_change
          @mutex = Mutex.new
          @closed = false
          @busy = false
          @state = { frontend_creating: false, frontend_error: nil, frontend_revision: 0 }
          load_snapshot
        end

        # Closing cancels queued work. An atomic save already begun may finish,
        # but its completion cannot refresh a closed launcher.
        def close
          @mutex.synchronize { @closed = true }
        end

        # The Frontends tab: the catalog on top, an editor for the selected row
        # below. Mirrors GUI::FrontendManagerTab, which #1558 added to the GTK
        # launcher -- detection is shown as status only, and nothing here ever
        # launches a frontend or touches account associations.
        # @api private
        def render(ui)
          state = @mutex.synchronize { @state.dup }
          launcher = self
          draft = state[:frontend_draft]
          # A new record gets new component identities. Otherwise viewer-local
          # input values from the prior record override the new server defaults.
          ui.stack(key: "frontends-body-#{state[:frontend_revision]}", gap: 8) do
            launcher.__send__(:render_frontend_catalog, self, state)
            launcher.__send__(:render_frontend_editor, self, state, draft)
          end
        end

        def render_frontend_catalog(ui, state)
          launcher = self
          rows = state[:frontends].map do |row|
            { key: row[:id], cells: { 'label' => row[:label], 'type' => row[:type],
                                      'status' => row[:status], 'launch' => row[:launch].to_s,
                                      'arguments' => row[:arguments].to_s } }
          end
          selected = state[:frontend_creating] ? [] : Array(state[:frontend_draft]&.fetch(:id, nil))
          ui.group(label: 'Frontends', key: 'frontends-table-section') do
            table(key: 'frontends-table', max_height: 260, columns: [
                    { key: 'label', label: 'Frontend' }, { key: 'type', label: 'Type' },
                    { key: 'status', label: 'Status' },
                    { key: 'launch', label: 'Executable / command' },
                    { key: 'arguments', label: 'Additional arguments' },
                  ], rows: rows, selection: :single, selected: selected,
                  on: { selection_change: ->(event) { launcher.select_frontend(event) } })
          end
        end

        def render_frontend_editor(ui, state, draft)
          launcher = self
          # With no row selected there is nothing to edit, but Add Custom and
          # Reload must still be reachable -- otherwise an empty catalog, or a
          # failed load, would leave no way back.
          unless draft
            ui.group(label: 'Frontend Settings', key: 'frontend-editor-section') do
              text(content: 'Select a frontend to edit, or choose Add Custom.')
              columns(key: 'frontend-actions', count: 3, weights: [0, 0, 1], gap: 6) do
                button(slot: '0', key: 'frontends-add', label: 'Add Custom',
                       on: { activate: ->(_event) { launcher.begin_new_frontend } })
                button(slot: '1', key: 'frontends-reload', label: 'Reload',
                       on: { activate: ->(_event) { launcher.reload_frontends } })
                text(slot: '2', key: 'frontend-actions-spacer', content: ' ')
              end
            end
            return
          end

          built_in = draft[:built_in]
          ui.group(label: built_in ? "#{draft[:label]} (built-in)" : 'Frontend Settings',
                   key: 'frontend-editor-section') do
            text(content: state[:frontend_error], tone: :danger) if state[:frontend_error]
            fields = launcher.__send__(:render_frontend_fields, self, state, draft, built_in)
            if built_in && !draft[:detected_command].to_s.empty?
              text(key: 'frontend-detected', content: "Detected: #{draft[:detected_command]}", tone: :neutral)
            end
            capability_boxes = launcher.__send__(:render_frontend_capabilities, self, draft, built_in)
            # One row under the editor, in GTK's order, rather than Save alone at
            # the bottom and the other three stranded above the table.
            columns(key: 'frontend-actions', count: 5, weights: [0, 0, 0, 0, 1], gap: 6) do
              button(slot: '0', key: 'frontends-add', label: 'Add Custom',
                     on: { activate: ->(_event) { launcher.begin_new_frontend } })
              button(slot: '1', key: 'frontend-save', label: 'Save', variant: :primary,
                     submit: fields + capability_boxes,
                     on: { activate: ->(event) { launcher.save_frontend(event) } })
              button(slot: '2', key: 'frontends-delete', label: 'Delete Custom', variant: :danger,
                     disabled: !launcher.__send__(:frontend_deletable?, state),
                     on: { activate: ->(_event) { launcher.delete_frontend } })
              button(slot: '3', key: 'frontends-reload', label: 'Reload',
                     on: { activate: ->(_event) { launcher.reload_frontends } })
              text(slot: '4', key: 'frontend-actions-spacer', content: ' ')
            end
          end
        end

        # GTK lays this editor out as rows: a fixed-width label on the left and
        # the field filling the rest. Emitting the inputs as a flat sequence put
        # every label on its own line above its field and roughly doubled the
        # height of the form, so each row is its own two-column grid. The label
        # still belongs to the input -- it is the input's own `label` prop, not
        # a separate text node -- so the control keeps its accessible name.
        # @api private
        def render_frontend_fields(ui, state, draft, built_in)
          [
            [:id, 'Stable ID', draft[:id].to_s, !state[:frontend_creating], 64, nil],
            [:label, 'Label', draft[:label].to_s, built_in, 128, nil],
            [:command, built_in ? 'Executable override' : 'Command', draft[:command].to_s, false, 512, nil],
            [:directory, 'Working directory', draft[:directory].to_s, built_in, 512, nil],
            [:arguments, 'Additional arguments', draft[:arguments].to_s, false, 512,
             'Shell quoting, for example: --flag "two words"'],
          ].map do |name, label, value, disabled, max_length, placeholder|
            options = { key: "frontend-#{name}", label: label, value: value,
                        disabled: disabled, max_length: max_length }
            # An absent placeholder is absent, not nil: the contract types it as
            # a String and refuses nil rather than treating it as unset.
            options[:placeholder] = placeholder if placeholder
            ui.text_input(**options)
          end
        end

        # A built-in declares its own protocol capabilities; only a custom
        # frontend may choose them.
        # @api private
        def render_frontend_capabilities(ui, draft, built_in)
          selected = Array(draft[:capabilities]).map(&:to_s)
          boxes = []
          # GTK lays these out three across; one per line turned six checkboxes
          # into six rows and pushed Save off the bottom of the form.
          Frontend.capability_vocabulary.each_slice(CAPABILITIES_PER_ROW).with_index do |row, index|
            ui.columns(key: "frontend-capability-row-#{index}", count: CAPABILITIES_PER_ROW,
                       weights: Array.new(CAPABILITIES_PER_ROW, 1), gap: 8) do
              row.each_with_index do |capability, column|
                boxes << checkbox(slot: column.to_s, key: "frontend-capability-#{capability}",
                                  label: capability.to_s, checked: selected.include?(capability.to_s),
                                  disabled: built_in)
              end
            end
          end
          boxes
        end

        # Selection is resolved against the server's cached catalog, never a
        # browser-provided record or a filesystem lookup on the event thread.
        def select_frontend(event)
          id = event.payload.fetch(:rows).first
          update_draft do
            @state.merge!(frontend_creating: false, frontend_error: nil,
                          frontend_draft: @fields.fetch(id).dup)
          end
        end

        def begin_new_frontend
          update_draft do
            @state.merge!(frontend_creating: true, frontend_error: nil, frontend_draft: {
              id: '', label: '', built_in: false, command: '', detected_command: '',
              directory: '', arguments: '', capabilities: []
            })
          end
        end

        # A submitted disabled input is still untrusted. Existing identity is
        # pinned to the selected server record; only a new record supplies an id.
        def save_frontend(event)
          fields = frontend_fields_from(event)
          queue_edit do |snapshot|
            creating = snapshot[:frontend_creating]
            unless creating || fields[:id] == snapshot.fetch(:frontend_draft).fetch(:id)
              raise ArgumentError, 'Frontend selection changed. Select it again before saving.'
            end
            FrontendSettings.load!(data_dir: @data_dir)
            builtins, custom, id = FrontendEditor.apply(FrontendSettings.current, fields, creating: creating)
            FrontendSettings.replace!(data_dir: @data_dir, builtins: builtins, custom: custom)
            load_snapshot(selected: id)
          end
        end

        def delete_frontend
          queue_edit do |snapshot|
            id = snapshot.fetch(:frontend_draft).fetch(:id)
            FrontendSettings.load!(data_dir: @data_dir)
            builtins, custom = FrontendEditor.remove(FrontendSettings.current, id)
            FrontendSettings.replace!(data_dir: @data_dir, builtins: builtins, custom: custom)
            load_snapshot
          end
        end

        def reload_frontends
          queue_edit do |snapshot|
            FrontendSettings.load!(data_dir: @data_dir)
            load_snapshot(selected: snapshot[:frontend_draft]&.fetch(:id))
          end
        end

        private

        def update_draft
          accepted = @mutex.synchronize do
            next false if @closed || @busy
            yield
            @state[:frontend_revision] += 1
            true
          end
          @on_change.call if accepted
        end

        # Serialize mutations with the rest of the launcher. The short lock
        # admits or cancels work; no IO occurs while holding the UI state lock.
        def queue_edit
          snapshot = @mutex.synchronize do
            next if @closed || @busy
            @busy = true
            @state.dup
          end
          return unless snapshot

          @executor.post do
            next if @mutex.synchronize { @closed }
            begin
              yield snapshot
              @on_catalog_change.call
            rescue StandardError => error
              @mutex.synchronize { @state[:frontend_error] = error.message }
            ensure
              @mutex.synchronize { @busy = false }
              @on_change.call unless @mutex.synchronize { @closed }
            end
          end
        end

        def load_snapshot(selected: nil)
          @frontend_locator.refresh! if @frontend_locator.respond_to?(:refresh!)
          rows = FrontendEditor.rows(locator: @frontend_locator)
          fields = rows.to_h { |row| [row[:id], FrontendEditor.editor_fields(row[:id], locator: @frontend_locator)] }
          @mutex.synchronize do
            @fields = fields
            @state[:frontend_revision] += 1
            @state.merge!(frontends: rows, frontend_creating: false, frontend_error: nil,
                          frontend_draft: fields[selected] || fields.values.first)
          end
        end

        def frontend_deletable?(state)
          draft = state[:frontend_draft]
          draft && !state[:frontend_creating] && !draft[:built_in] && !draft[:id].empty?
        end

        def frontend_fields_from(event)
          submission = event.submission
          values = submission.cids.to_h { |cid| [cid, submission.fetch(cid)] }
          field = ->(suffix) { values.find { |cid, _| cid.end_with?(suffix) }&.last }
          fields = %i[id label command directory arguments].to_h do |name|
            [name, field.call("text_input:frontend-#{name}").to_s]
          end
          fields[:capabilities] = Frontend.capability_vocabulary.filter_map do |capability|
            capability.to_s if field.call("checkbox:frontend-capability-#{capability}") == true
          end
          fields
        end
      end
    end
  end
end
