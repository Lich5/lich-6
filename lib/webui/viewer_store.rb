# frozen_string_literal: true

require 'securerandom'
require 'monitor'
require_relative 'component'
require_relative 'protocol'
require_relative 'value_helpers'

module Lich
  module WebUI
    # Per-page viewer attachments and viewer-local state.
    class ViewerStore
      RECONNECT_WINDOW = 60
      WIDGET_ADMISSION_WINDOW = 30
      RELEASE_ADMISSION_WINDOW = 30
      Admission = Data.define(:render, :widget_revision, :accepted_at)
      ReleaseAdmission = Data.define(:render, :epoch, :cid, :accepted_at)
      ReleaseEpoch = Struct.new(:signature, :generation, :started_at)
      Snapshot = Data.define(:page, :viewer_id, :render, :values, :input_requests)

      class Attachment
        attr_accessor :connection_id, :render, :delivered_generation, :expires_at
        attr_accessor :widget_signature, :widget_generation, :widget_started_at, :widget_revision, :widget_request
        attr_reader :viewer_id, :resume_token, :address, :page, :values, :delivered_read_only, :input_requests
        attr_reader :release_epochs
        attr_accessor :release_request

        # Creates independent viewer identity, resume capability, and local state for a page.
        # The resume token is server-generated; no render is delivered yet.
        def initialize(connection_id:, address:, page:)
          @connection_id = connection_id
          @viewer_id = "attachment-#{SecureRandom.hex(16)}".freeze
          @resume_token = "resume-#{SecureRandom.hex(16)}".freeze
          @address = address.freeze
          @page = page
          @values = {}
          @input_requests = {}
          @delivered_read_only = {}
          @render = nil
          @delivered_generation = nil
          @expires_at = nil
          @widget_signature = @widget_generation = @widget_started_at = @widget_request = nil
          @widget_revision = 0
          @release_epochs = {}
          @release_request = nil
        end
      end

      # Creates connection/resume indexes with an injectable monotonic expiry clock.
      # @param clock [#call] elapsed seconds used for reconnect deadlines
      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @by_connection = {}
        @by_resume = {}
        @mutex = Monitor.new
      end

      # Attaches one viewer per connection/page pair, or resumes a disconnected one.
      # @param connection_id [String] authenticated connection identifier
      # @param address [String] registered page address
      # @param page [Page] page receiving the viewer
      # @param resume_token [String, nil] previous attachment's reconnect token
      # @return [Attachment] the new or resumed viewer
      # @raise [Error] if this connection already views the page or resume is invalid
      def attach(connection_id:, address:, page:, resume_token: nil)
        @mutex.synchronize do
          expire_locked!
          raise Error, 'viewer is already attached' if @by_connection.key?([connection_id, address])

          attachment = resume_token && @by_resume[resume_token]
          if attachment
            raise Error, 'resume token belongs to another page' unless attachment.address == address
            raise Error, 'viewer is already attached' unless attachment.expires_at

            remove_connection_mapping!(attachment)
            attachment.connection_id = connection_id
            attachment.expires_at = nil
          else
            attachment = Attachment.new(connection_id: connection_id, address: address, page: page)
            @by_resume[attachment.resume_token] = attachment
          end
          @by_connection[[connection_id, address]] = attachment
          attachment
        end
      end

      # Finds a live connection/page attachment after expiring stale resume entries.
      # @return [Attachment]
      # @raise [Error] when the connection is not attached to that page
      def fetch(connection_id:, address:)
        @mutex.synchronize do
          expire_locked!
          @by_connection.fetch([connection_id, address])
        end
      rescue KeyError
        raise Error, 'viewer is not attached to page'
      end

      # Removes connection routing while retaining state for the bounded resume window.
      # @return [Array<Attachment>] disconnected attachments for lifecycle notifications
      def transient_disconnect(connection_id)
        @mutex.synchronize do
          attachments = @by_connection.each_value.select { |attachment| attachment.connection_id == connection_id }.uniq
          attachments.each do |attachment|
            attachment.expires_at = @clock.call + RECONNECT_WINDOW
            retire_widget_admission!(attachment)
          end
          @by_connection.delete_if { |(candidate, _address), _attachment| candidate == connection_id }
          attachments
        end
      end

      # Destroys one attachment immediately, including its resume capability and values.
      # @return [Attachment, nil] removed attachment
      def close(connection_id:, address:)
        @mutex.synchronize do
          attachment = @by_connection.delete([connection_id, address])
          destroy_locked!(attachment) if attachment
          attachment
        end
      end

      # Destroys all live and resumable attachments for this exact page instance.
      # @return [void]
      def destroy_page(page)
        @mutex.synchronize do
          @by_resume.values.select { |attachment| attachment.page.equal?(page) }.uniq.each do |attachment|
            destroy_locked!(attachment)
          end
        end
      end

      # Snapshots active page attachments; disconnected resume entries do not count.
      # @return [Array<Attachment>]
      def attachments_for(page)
        @mutex.synchronize do
          expire_locked!
          @by_resume.values.select { |attachment| attachment.page.equal?(page) && !attachment.expires_at }.uniq
        end
      end

      # Resolves an active viewer within an exact page instance.
      # @return [Attachment]
      # @raise [Error] for absent, expired, or disconnected viewers
      def attachment_for_viewer(page, viewer_id)
        @mutex.synchronize do
          expire_locked!
          @by_resume.values.find do |attachment|
            attachment.page.equal?(page) && attachment.viewer_id == viewer_id && !attachment.expires_at
          end
        end || raise(Error.new('viewer is not attached to page', page_id: page.id))
      end

      # Reads a viewer override, falling back to the delivered component property.
      # @return [Object] current value
      def property(attachment, component, name)
        @mutex.synchronize { attachment.values.fetch([component.cid, name], component.props[name]) }
      end

      # Stores an already-validated viewer-local override under the store lock.
      # @return [Object] stored value
      def set_property(attachment, component, name, value)
        @mutex.synchronize do
          select_radio_option!(attachment, component) if component.type == :radio_option && name == :checked && value
          attachment.values[[component.cid, name]] = value
        end
      end

      # Validates and seeds a new control only while its viewer and CID are live.
      # Checking identity, resolving the delivered component and writing under
      # one lock prevents concurrent detach/delivery from reviving stale state.
      # @yield [Component] current component; return the validated property value
      # @return [Object, nil] stored value, or nil for a departed/undelivered target
      def seed_property(attachment, cid, name)
        @mutex.synchronize do
          next unless @by_resume[attachment.resume_token].equal?(attachment) && !attachment.expires_at
          component = attachment.render&.tree&.each&.find { |candidate| candidate.cid == cid }
          next unless component

          value = yield component
          select_radio_option!(attachment, component) if component.type == :radio_option && name == :checked && value
          attachment.values[[cid, name]] = value
        end
      end

      # Accepts only the read-only text actually sent to this viewer. A later
      # server write remains authoritative and is never overwritten by submission.
      # This delivery record is protocol evidence, not another editable draft.
      # Browsers normalize textarea line breaks and strip them in single-line
      # inputs. Compare that representation; server text and callbacks stay exact.
      # @return [String] current server value for the terminal callback snapshot
      # @raise [Protocol::Refusal] if the client changed the delivered text
      def read_only_submission(attachment, component, value)
        @mutex.synchronize do
          unless attachment.delivered_read_only.key?(component.cid) &&
                 read_only_browser_value(component.type, attachment.delivered_read_only[component.cid]) == read_only_browser_value(component.type, value)
            raise Protocol::Refusal.new(:payload, 'read-only text cannot be changed by submission')
          end
          attachment.values.fetch([component.cid, :value], component.props[:value])
        end
      end

      # Records the newest render accepted for one viewer and seeds its values.
      # Refresh and attach can finish out of order. An older render must not
      # replace the tree, lower the event generation, or invalidate selections.
      # Equal generations may be redelivered; existing viewer values survive.
      #
      # @param attachment [Attachment] viewer receiving the page render
      # @param render [Page::Render] validated render for the attachment's page
      # @return [void]
      def deliver(attachment, render)
        @mutex.synchronize do
          current = attachment.delivered_generation
          next if current && render.generation < current

          signature = widget_signature(render)
          now = @clock.call
          update_release_epochs(attachment, render, now)
          changed = signature != attachment.widget_signature
          if changed || !attachment.widget_started_at || now - attachment.widget_started_at >= WIDGET_ADMISSION_WINDOW
            attachment.widget_revision += 1 if changed
            attachment.widget_signature = signature
            attachment.widget_generation = signature && render.generation
            attachment.widget_started_at = now
          end
          previous_components = attachment.render ? attachment.render.tree.each.to_h { |node| [node.cid, node] } : {}
          attachment.render = render
          attachment.delivered_generation = render.generation
          previous = attachment.values.select { |(_cid, property), value| property == :checked && value }.keys
          seed_values!(attachment, render.tree, previous_components)
          live_inputs = render.tree.each.select { |node| node.type == :text_input && !node.props[:sensitive] }.to_h { |node| [node.cid, true] }
          attachment.input_requests.keep_if { |cid, _request| live_inputs.key?(cid) }
          render.tree.each.select { |node| node.type == :radio_option }.group_by { |node| node.props[:group] }.each_value do |members|
            selected = members.select { |node| attachment.values[[node.cid, :checked]] }
            next if selected.length < 2

            retained = selected.find { |node| previous.include?([node.cid, :checked]) } || selected.first
            select_radio_option!(attachment, retained)
          end
        end
      end

      # Serializes event validation and queue admission with delivery/detachment.
      # The yielded runtime work may enqueue callbacks, but never runs script code.
      # Only unchanged transfer/release authority can outlive a paint generation;
      # compressed epochs are retained per viewer, never a render history.
      # @yieldparam admission [Admission, ReleaseAdmission] captured gesture authority
      # @return [Object] runtime admission result, or :queued for a duplicate request
      # @raise [Protocol::Refusal] for obsolete generations or a departed viewer
      def admit_event(attachment, message)
        @mutex.synchronize do
          unless live_attachment?(attachment)
            raise Protocol::Refusal.new(:attachment, 'viewer is no longer attached')
          end
          widget_drop = message[:event].to_s == 'widget_drop'
          return admit_release(attachment, message) { |admission| yield admission } if %w[pointer_release pointer_motion].include?(message[:event].to_s)

          generation = message[:generation]
          current = attachment.delivered_generation
          compatible = widget_drop && attachment.widget_generation && generation.is_a?(Integer) &&
                       generation.between?(attachment.widget_generation, current) &&
                       @clock.call - attachment.widget_started_at < WIDGET_ADMISSION_WINDOW &&
                       attachment.render.submissions.fetch(message[:cid], []).empty?
          unless generation == current || compatible
            raise Protocol::Refusal.new(:stale_generation, 'stale generation')
          end
          request = message[:request] if widget_drop && message[:request].is_a?(Integer)
          return :queued if request && attachment.widget_request && request <= attachment.widget_request

          admission = Admission.new(widget_drop ? attachment.render : nil, attachment.widget_revision, @clock.call)
          result = yield admission
          attachment.widget_request = request if request && result == :queued
          result
        end
      end

      # Checks queued transfers without holding the store lock during script code.
      # The captured callback/render retain admission-time identity; later state
      # changes retire queued work instead of selecting a replacement source.
      def widget_admission_current?(attachment, admission)
        @mutex.synchronize do
          live_attachment?(attachment) && attachment.widget_revision == admission.widget_revision &&
            @clock.call - admission.accepted_at < WIDGET_ADMISSION_WINDOW
        end
      end

      # Rechecks the exact release surface epoch before queued user code runs.
      # @param attachment [Attachment] original admitting viewer
      # @param admission [ReleaseAdmission] captured surface epoch and queue time
      # @return [Boolean] whether the queued callback still has live authority
      def release_admission_current?(attachment, admission)
        @mutex.synchronize do
          live_attachment?(attachment) && attachment.release_epochs[admission.cid].equal?(admission.epoch) &&
            @clock.call - admission.accepted_at < RELEASE_ADMISSION_WINDOW
        end
      end

      # Applies a validated interaction to the corresponding viewer-local control state.
      # Password values are intentionally excluded from this persistent state map.
      # Request IDs acknowledge accepted live text input, never grant routing authority.
      # They are captured with values so an older delivery cannot erase newer typing.
      # @return [void]
      def update(attachment, component, event, payload, request = nil)
        @mutex.synchronize do
          if request && component.type == :text_input && event == :change && !component.props[:sensitive]
            attachment.input_requests[component.cid] = request
          end
          case [component.type, event]
          when [:overlay, :pointer_press], [:overlay, :pointer_motion], [:overlay, :pointer_release]
            if component.props[:pointer_tracking]
              attachment.values[[component.cid, :pointer_position]] = payload.slice(:x, :y, :state).freeze
              # Start the bounded drag lifetime at press, not at an earlier paint.
              if event == :pointer_press && payload[:button] == 1 && (epoch = attachment.release_epochs[component.cid])
                epoch.started_at = @clock.call
              end
            end
          when [:radio_option, :change]
            select_radio_option!(attachment, component) if payload[:value]
            attachment.values[[component.cid, :checked]] = payload[:value]
          when [:toggle, :change], [:checkbox, :change] then attachment.values[[component.cid, :checked]] = payload[:value]
          when [:radio, :change] then attachment.values[[component.cid, :selected]] = payload[:value]
          when [:text_input, :change], [:text_input, :blur], [:textarea, :change], [:textarea, :blur], [:number_input, :change], [:slider, :change], [:select, :change]
            attachment.values[[component.cid, :value]] = payload[:value]
          when [:tabs, :select] then attachment.values[[component.cid, :selected]] = payload[:index]
          when [:group, :dismiss] then attachment.values[[component.cid, :open]] = false
          when [:expander, :toggle] then attachment.values[[component.cid, :open]] = payload[:open]
          when [:split, :move] then attachment.values[[component.cid, :position]] = payload[:position]
          when [:table, :selection_change] then attachment.values[[component.cid, :selected]] = payload[:rows]
          when [:table, :cursor_change]
            attachment.values[[component.cid, :cursor]] = payload.dup.freeze
          when [:table, :sort_change]
            attachment.values[[component.cid, :sort]] = { column: payload[:column], direction: payload[:direction] }.freeze
          when [:table, :row_toggle]
            expanded = attachment.values.fetch([component.cid, :expanded]) { component.props[:rows].select { |row| row[:expanded] }.map { |row| row[:key] } }
            attachment.values[[component.cid, :expanded]] = payload[:expanded] ? expanded | [payload[:row]] : expanded - [payload[:row]]
          end
        end
      end

      # Reads the accepted input before a terminal submission replaces it.
      # @return [Object] current viewer-local input value
      def input_value(attachment, component)
        property(attachment, component, input_property(component.type))
      end

      # Maps a validated submission value to the control's supported input property.
      # @return [void]
      def set_input(attachment, component, value)
        property = input_property(component.type)
        set_property(attachment, component, property, value) if property
      end

      # Selects one member and returns changed peers followed by the selected member.
      # @return [Array<Array(Component, Boolean)>] only actual boolean transitions
      # @raise [Error] before a render has been delivered
      def select_radio_option(attachment, component)
        @mutex.synchronize do
          raise Error, 'viewer has no delivered render' unless attachment.render

          changed = attachment.render.tree.each.filter_map do |peer|
            next unless peer.type == :radio_option && peer.props[:group] == component.props[:group]

            checked = peer.cid == component.cid
            [peer, checked] if attachment.values.fetch([peer.cid, :checked], peer.props[:checked]) != checked
          end
          select_radio_option!(attachment, component)
          changed.sort_by { |_peer, checked| checked ? 1 : 0 }
        end
      end

      # Copies one coherent render and its nonsensitive viewer values for queued work.
      # The snapshot is not attached or resumable and cannot receive browser events.
      # @param attachment [Attachment] viewer whose delivered state is captured
      # @param for_delivery [Boolean] record read-only values from this wire snapshot;
      #   lifecycle snapshots must not change what the browser is allowed to submit
      # @return [Snapshot] independent values with an immutable render definition
      def snapshot(attachment, for_delivery: false)
        @mutex.synchronize do
          raise Error, 'viewer has no delivered render' unless attachment.render

          if for_delivery
            attachment.delivered_read_only.clear
            attachment.render.tree.each do |component|
              next unless %i[text_input textarea].include?(component.type) && component.props[:read_only] && !component.props[:sensitive]

              attachment.delivered_read_only[component.cid] = attachment.values.fetch([component.cid, :value], component.props[:value])
            end
          end
          Snapshot.new(attachment.page, attachment.viewer_id, attachment.render, attachment.values.dup, attachment.input_requests.dup)
        end
      end

      # Captures the sole retained viewer when an owned OS window exits without pagehide.
      # Multiple viewers are deliberately not guessed; expired viewers are excluded.
      # @param page [Page] page whose native host exited
      # @param retire [Boolean] retire the exited viewer after copying its closing state
      # @return [Snapshot, nil] last delivered state, when unambiguous
      def closing_snapshot(page, retire: false)
        @mutex.synchronize do
          expire_locked!
          candidates = @by_resume.values.select { |attachment| attachment.page.equal?(page) && attachment.render }
          if candidates.one?
            attachment = candidates.first
            snapshot = Snapshot.new(page, attachment.viewer_id, attachment.render, attachment.values.dup, attachment.input_requests.dup)
            destroy_locked!(attachment) if retire
            snapshot
          end
        end
      end

      # Overlays viewer-local values onto the delivered tree for wire serialization.
      # @return [Hash] viewer-specific component tree
      # @raise [Error] before a render has been delivered
      def serialize(attachment)
        @mutex.synchronize do
          render = attachment.render
          raise Error, 'viewer has no delivered render' unless render

          serialize_component(render.tree, attachment.values)
        end
      end

      private

      # Checks connection identity as well as transient-disconnect state.
      # Caller holds the store monitor; no resume token alone authorizes events.
      # @param attachment [Attachment] candidate live viewer
      # @return [Boolean] whether this exact attachment remains routed
      def live_attachment?(attachment)
        @by_connection[[attachment.connection_id, attachment.address]].equal?(attachment) && !attachment.expires_at
      end

      # Clears transfer/release epochs on disconnect or permanent destruction.
      # @param attachment [Attachment] viewer whose queued authority is retired
      # @return [Integer] advanced transfer revision
      def retire_widget_admission!(attachment)
        attachment.release_epochs.clear
        attachment.release_request = nil
        attachment.widget_signature = attachment.widget_generation = attachment.widget_started_at = attachment.widget_request = nil
        attachment.widget_revision += 1
      end

      # One epoch per currently bound release surface; removed surfaces retain no
      # history. Equal paints keep authority for at most 30 seconds. The caller
      # holds the same monitor used for delivery and event validation.
      # @param attachment [Attachment] viewer receiving the render
      # @param render [Page::Render] newest coherent component tree and bindings
      # @param now [Numeric] monotonic delivery time
      # @return [Hash] current release signatures, keyed by component identity
      def update_release_epochs(attachment, render, now)
        signatures = release_signatures(render)
        attachment.release_epochs.keep_if { |cid, _epoch| signatures.key?(cid) }
        signatures.each do |cid, signature|
          epoch = attachment.release_epochs[cid]
          if !epoch || epoch.signature != signature
            attachment.release_epochs[cid] = ReleaseEpoch.new(signature, render.generation, now)
          elsif now - epoch.started_at >= RELEASE_ADMISSION_WINDOW
            epoch.generation = render.generation
            epoch.started_at = now
          end
        end
      end

      # Captures target subtrees and ancestor layout/state, excluding unrelated
      # sibling text paints. Shared immutable projections keep storage linear in
      # the tree plus the ancestry of each bound release surface.
      # @param render [Page::Render] validated tree and binding authority
      # @return [Hash] per-surface projections without viewer input snapshots
      def release_signatures(render)
        return {} unless render.bindings.any? { |(_cid, event), _callback| event == :pointer_release }

        bindings = render.bindings.each_with_object({}) do |((cid, event), callback), grouped|
          (grouped[cid] ||= {})[event] = callback
        end
        signatures = {}
        project = lambda do |node, ancestors|
          boundary = [node.cid, node.type, node.props, node.slot, node.placement, node.children.map(&:cid)]
          children = node.children.map { |child| project.call(child, ancestors + [boundary]) }
          subtree = [boundary, bindings[node.cid], render.submissions[node.cid], children]
          if bindings[node.cid]&.key?(:pointer_release)
            # A tracking canvas releases its own drag, not a child hit target.
            # Marker paints and scrolling may change during that drag; ownership,
            # visibility and the exact callbacks still delimit release authority.
            signatures[node.cid] = if node.type == :overlay && node.props[:pointer_tracking]
                                     [node.cid, bindings[node.cid], render.submissions[node.cid],
                                      (ancestors + [boundary]).map { |item| [item[0], item[1], item[2].slice(:hidden, :disabled, :pointer_tracking, :pointer_events), item[3]] }]
                                   else
                                     [subtree, ancestors, render.facilities]
                                   end
          end
          subtree
        end
        project.call(render.tree, [])
        signatures
      end

      # Admits only unchanged release surfaces, never submitted forms or arbitrary
      # stale event families. Request high-water marks prevent duplicate callbacks
      # across surface replacement and time-window renewal.
      # @param attachment [Attachment] live viewer protected by the store monitor
      # @param message [Hash] correlated release envelope, still subject to validation
      # @yieldparam admission [ReleaseAdmission] coherent callback render and epoch
      # @return [Object] validation/enqueue result, or :queued for a duplicate
      # @raise [Protocol::Refusal] for a generation outside the surface epoch
      def admit_release(attachment, message)
        epoch = attachment.release_epochs[message[:cid]]
        generation = message[:generation]
        current = attachment.delivered_generation
        compatible = epoch && generation.is_a?(Integer) && generation.between?(epoch.generation, current) &&
                     @clock.call - epoch.started_at < RELEASE_ADMISSION_WINDOW &&
                     attachment.render.submissions.fetch(message[:cid], []).empty?
        unless generation == current || compatible
          raise Protocol::Refusal.new(:stale_generation, 'stale generation')
        end
        request = message[:request] if message[:request].is_a?(Integer)
        return :queued if request && attachment.release_request && request <= attachment.release_request

        admission = ReleaseAdmission.new(attachment.render, epoch, message[:cid], @clock.call)
        result = yield admission
        attachment.release_request = request if request && result == :queued
        result
      end

      # Transfer descendants retain all authored properties/bindings, so geometry
      # or meaning changes invalidate old measured insertion intent. Ancestors
      # retain their state and child order; unrelated sibling text paints do not.
      # Shared immutable property references keep the retained projection bounded
      # by the already validated component tree; no viewer input values are copied.
      # @param render [Page::Render] validated tree and transfer bindings
      # @return [Array, nil] transfer projection, or nil without transfer surfaces
      def widget_signature(render)
        bindings = render.bindings.each_with_object({}) do |((cid, event), callback), grouped|
          (grouped[cid] ||= {})[event] = callback
        end
        project = lambda do |node, inside|
          transfer = inside || node.props[:drag_source] || node.props[:drag_destination]
          children = node.children.filter_map { |child| project.call(child, transfer) }
          next if !transfer && children.empty?

          [node.cid, node.type, node.props, node.slot, node.placement, node.children.map(&:cid),
           transfer ? bindings[node.cid] : nil, render.submissions[node.cid], children]
        end
        tree = project.call(render.tree, false)
        [tree, render.facilities] if tree
      end

      # Single-line HTML inputs strip line breaks; textareas normalize them.
      # Compare browser representations without modifying authoritative text.
      # @return [String] the validated value's browser representation
      def read_only_browser_value(type, value)
        type == :text_input ? value.delete("\r\n") : normalize_text_line_breaks(value)
      end

      # Nontext values retain their identity; schema validation owns rejection.
      # @return [Object] text with LF line breaks, or the unchanged nontext value
      def normalize_text_line_breaks(value)
        value.is_a?(String) ? ValueHelpers.normalize_text_line_breaks(value) : value
      end

      # Clears only peers in the same delivered page and viewer before selecting a member.
      # Must be called under the store mutex; no synthetic callbacks are dispatched here.
      # @return [void]
      def select_radio_option!(attachment, component)
        attachment.render.tree.each do |peer|
          next unless peer.type == :radio_option && peer.props[:group] == component.props[:group]

          attachment.values[[peer.cid, :checked]] = peer.cid == component.cid
        end
      end

      # Seeds only absent viewer fields and repairs removed select choices without fabricating events.
      # Requires the store mutex; existing unrelated viewer edits remain intact.
      # @return [void]
      def seed_values!(attachment, component, previous_components = {})
        schema = Contract.schema(component.type)
        schema[:properties].each do |name, definition|
          next unless definition[:scope] == :viewer && component.props.key?(name)

          key = [component.cid, name]
          attachment.values[key] = component.props[name] unless attachment.values.key?(key)
          # Option removal invalidates only viewers selecting the removed item.
          # Other viewers retain their own choice; no callback is fabricated.
          if component.type == :select && name == :value
            old_options = previous_components[component.cid]&.props&.fetch(:options, []) || []
            was_option = old_options.any? { |option| option[:value] == attachment.values[key] }
            if (!component.props[:editable] || was_option) && component.props[:options].none? { |option| option[:value] == attachment.values[key] }
              attachment.values[key] = component.props[:empty_value] || component.props[name]
            end
          end
        end
        reconcile_table!(attachment.values, component, previous_components[component.cid]) if component.type == :table
        reconcile_tabs!(attachment.values, component, previous_components[component.cid]) if component.type == :tabs
        component.children.each { |child| seed_values!(attachment, child, previous_components) }
      end

      # Preserve each viewer's selected tab identity when preceding pages retire.
      # Removing the selected page chooses the next page, or the previous last page.
      def reconcile_tabs!(values, component, previous)
        return unless component.props[:headers]

        field = [component.cid, :selected]
        index = values.fetch(field, component.props[:selected] || 0)
        values[field] = Contract.remap_tab_index(previous&.props&.[](:headers), component.props[:headers], index, component.props[:names].length)
      end

      # Removes only identities retired from this table; another viewer's choices are untouched.
      # @param values [Hash] this attachment's overrides, under the store lock
      # @param component [Component] replacement table
      # @param previous [Component, nil] previously delivered table, for new-row defaults
      # @return [void]
      # @api private
      def reconcile_table!(values, component, previous)
        props, cid = component.props, component.cid
        keys = props[:rows].map { |row| row[:key] }
        selected = values.fetch([cid, :selected], props[:selected] || []) & keys
        selected = [] if props[:selection] == 'none'
        selected = selected.first(1) unless props[:selection] == 'multi'
        selected = keys.first(1) if props[:selection] == 'browse' && selected.empty?
        values[[cid, :selected]] = selected
        initial = props[:expanded] || props[:rows].select { |row| row[:expanded] }.map { |row| row[:key] }
        previous_keys = previous&.props&.fetch(:rows, [])&.map { |row| row[:key] } || []
        # New identities receive their defaults; retained rows keep the viewer's choice.
        values[[cid, :expanded]] = (values.fetch([cid, :expanded], initial) & keys) | (initial & (keys - previous_keys))
        cursor = values.fetch([cid, :cursor], props[:cursor] || {})
        cursor = {} unless keys.include?(cursor[:row])
        columns = props[:columns].map { |column| column[:key] }
        cursor = cursor.reject { |name, value| name == :column && !columns.include?(value) }
        values[[cid, :cursor]] = cursor
      end

      # Overlays viewer properties and row expansion while excluding secret/ephemeral fields.
      # @return [Hash] recursively serialized control
      def serialize_component(component, values)
        props = component.props.each_with_object({}) do |(name, value), result|
          definition = Contract.schema(component.type)[:properties][name]
          next if definition && %i[sensitive_write_only ephemeral_client].include?(definition[:scope])
          next if name == :value && ValueHelpers.sensitive_value?(component)

          result[name] = definition && definition[:scope] == :viewer ? values.fetch([component.cid, name], value) : value
        end
        # Optional viewer properties (for example a naturally sized split's
        # position) may first exist after interaction, with no source default.
        Contract.schema(component.type)[:properties].each do |name, definition|
          next if component.props.key?(name) || definition[:scope] != :viewer
          next if name == :value && ValueHelpers.sensitive_value?(component)

          props[name] = values[[component.cid, name]] if values.key?([component.cid, name])
        end
        if component.type == :table
          props[:rows] = props[:rows].map do |row|
            expanded = values.key?([component.cid, :expanded]) ? values[[component.cid, :expanded]].include?(row[:key]) : row[:expanded]
            row.merge(expanded: expanded)
          end
        end
        result = { type: component.type.to_s, cid: component.cid, props: props, children: component.children.map { |child| serialize_component(child, values) } }
        result[:slot] = component.slot if component.slot
        result[:placement] = component.placement unless component.placement.empty?
        result
      end

      def input_property(type)
        case type
        when :toggle, :checkbox, :radio_option then :checked
        when :radio then :selected
        when :text_input, :textarea, :number_input, :slider, :select then :value
        end
      end

      # Destroys expired disconnected attachments while the store mutex is held.
      # @return [void]
      def expire_locked!
        now = @clock.call
        @by_resume.values.select { |attachment| attachment.expires_at && attachment.expires_at <= now }.uniq.each do |attachment|
          destroy_locked!(attachment)
        end
      end

      # Clears connection/resume indexes, values, and render references under the store mutex.
      # @return [void]
      def destroy_locked!(attachment)
        return unless attachment

        remove_connection_mapping!(attachment)
        @by_resume.delete(attachment.resume_token)
        attachment.values.clear
        attachment.input_requests.clear
        attachment.delivered_read_only.clear
        attachment.render = nil
        attachment.delivered_generation = nil
        retire_widget_admission!(attachment)
      end

      # Deletes only mappings to this exact attachment object, including superseded aliases.
      # @return [void]
      def remove_connection_mapping!(attachment)
        @by_connection.delete_if { |_key, candidate| candidate.equal?(attachment) }
      end
    end
  end
end
