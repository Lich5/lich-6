# frozen_string_literal: true

require 'securerandom'
require_relative 'component'

module Lich
  module WebUI
    # Per-page viewer attachments and viewer-local state.
    class ViewerStore
      RECONNECT_WINDOW = 60
      Snapshot = Data.define(:page, :viewer_id, :render, :values)

      class Attachment
        attr_accessor :connection_id, :render, :delivered_generation, :expires_at
        attr_reader :viewer_id, :resume_token, :address, :page, :values

        # Creates independent viewer identity, resume capability, and local state for a page.
        # The resume token is server-generated; no render is delivered yet.
        def initialize(connection_id:, address:, page:)
          @connection_id = connection_id
          @viewer_id = "attachment-#{SecureRandom.hex(16)}".freeze
          @resume_token = "resume-#{SecureRandom.hex(16)}".freeze
          @address = address.freeze
          @page = page
          @values = {}
          @render = nil
          @delivered_generation = nil
          @expires_at = nil
        end
      end

      # Creates connection/resume indexes with an injectable monotonic expiry clock.
      # @param clock [#call] elapsed seconds used for reconnect deadlines
      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @by_connection = {}
        @by_resume = {}
        @mutex = Mutex.new
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

          attachment.render = render
          attachment.delivered_generation = render.generation
          previous = attachment.values.select { |(_cid, property), value| property == :checked && value }.keys
          seed_values!(attachment, render.tree)
          render.tree.each.select { |node| node.type == :radio_option }.group_by { |node| node.props[:group] }.each_value do |members|
            selected = members.select { |node| attachment.values[[node.cid, :checked]] }
            next if selected.length < 2

            retained = selected.find { |node| previous.include?([node.cid, :checked]) } || selected.first
            select_radio_option!(attachment, retained)
          end
        end
      end

      # Applies a validated interaction to the corresponding viewer-local control state.
      # Password values are intentionally excluded from this persistent state map.
      # @return [void]
      def update(attachment, component, event, payload)
        @mutex.synchronize do
          case [component.type, event]
          when [:radio_option, :change]
            select_radio_option!(attachment, component) if payload[:value]
            attachment.values[[component.cid, :checked]] = payload[:value]
          when [:toggle, :change], [:checkbox, :change] then attachment.values[[component.cid, :checked]] = payload[:value]
          when [:radio, :change] then attachment.values[[component.cid, :selected]] = payload[:value]
          when [:text_input, :change], [:textarea, :change], [:number_input, :change], [:slider, :change], [:select, :change]
            attachment.values[[component.cid, :value]] = payload[:value]
          when [:tabs, :select] then attachment.values[[component.cid, :selected]] = payload[:index]
          when [:group, :dismiss] then attachment.values[[component.cid, :open]] = false
          when [:expander, :toggle] then attachment.values[[component.cid, :open]] = payload[:open]
          when [:split, :move] then attachment.values[[component.cid, :position]] = payload[:position]
          when [:table, :selection_change] then attachment.values[[component.cid, :selected]] = payload[:rows]
          when [:table, :sort_change]
            attachment.values[[component.cid, :sort]] = { column: payload[:column], direction: payload[:direction] }.freeze
          when [:table, :row_toggle]
            attachment.values[[component.cid, "expanded:#{payload[:row]}"]] = payload[:expanded]
          end
        end
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
      # @return [Snapshot] independent values with an immutable render definition
      def snapshot(attachment)
        @mutex.synchronize do
          raise Error, 'viewer has no delivered render' unless attachment.render

          Snapshot.new(attachment.page, attachment.viewer_id, attachment.render, attachment.values.dup)
        end
      end

      # Captures the sole retained viewer when an owned OS window exits without pagehide.
      # Multiple viewers are deliberately not guessed; expired viewers are excluded.
      # @param page [Page] page whose native host exited
      # @return [Snapshot, nil] last delivered state, when unambiguous
      def closing_snapshot(page)
        @mutex.synchronize do
          expire_locked!
          candidates = @by_resume.values.select { |attachment| attachment.page.equal?(page) && attachment.render }
          if candidates.one?
            attachment = candidates.first
            Snapshot.new(page, attachment.viewer_id, attachment.render, attachment.values.dup)
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
      def seed_values!(attachment, component)
        schema = Contract.schema(component.type)
        schema[:properties].each do |name, definition|
          next unless definition[:scope] == :viewer && component.props.key?(name)

          key = [component.cid, name]
          attachment.values[key] = component.props[name] unless attachment.values.key?(key)
          # Option removal invalidates only viewers selecting the removed item.
          # Other viewers retain their own choice; no callback is fabricated.
          if component.type == :select && name == :value &&
             component.props[:options].none? { |option| option[:value] == attachment.values[key] }
            attachment.values[key] = component.props[name]
          end
        end
        component.children.each { |child| seed_values!(attachment, child) }
      end

      # Overlays viewer properties and row expansion while excluding secret/ephemeral fields.
      # @return [Hash] recursively serialized control
      def serialize_component(component, values)
        props = component.props.each_with_object({}) do |(name, value), result|
          definition = Contract.schema(component.type)[:properties][name]
          next if definition && %i[sensitive_write_only ephemeral_client].include?(definition[:scope])
          next if name == :value && (component.type == :password_input || component.props[:sensitive] == true)

          result[name] = definition && definition[:scope] == :viewer ? values.fetch([component.cid, name], value) : value
        end
        # Optional viewer properties (for example a naturally sized split's
        # position) may first exist after interaction, with no source default.
        Contract.schema(component.type)[:properties].each do |name, definition|
          next if component.props.key?(name) || definition[:scope] != :viewer
          next if name == :value && (component.type == :password_input || component.props[:sensitive] == true)

          props[name] = values[[component.cid, name]] if values.key?([component.cid, name])
        end
        if component.type == :table
          props[:rows] = props[:rows].map do |row|
            expanded = values.fetch([component.cid, "expanded:#{row[:key]}"], row[:expanded])
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
        attachment.render = nil
        attachment.delivered_generation = nil
      end

      # Deletes only mappings to this exact attachment object, including superseded aliases.
      # @return [void]
      def remove_connection_mapping!(attachment)
        @by_connection.delete_if { |_key, candidate| candidate.equal?(attachment) }
      end
    end
  end
end
