# frozen_string_literal: true

require_relative 'dispatcher'
require_relative 'protocol'
require_relative 'submission'
require_relative 'viewer_store'
require_relative 'native_host'
require_relative 'window_presentation'

module Lich
  module WebUI
    # Server-routed page attachment, viewer state, submission, and callback runtime.
    class Runtime
      EventContext = Data.define(:viewer_id, :page, :component, :event, :payload, :submission)
      PRESENTATION_SUPPORT = {
        always_on_top: false, borderless: false, opacity: true, scrollbars: true,
      }.freeze

      # Connects page delivery and callback dispatch to optional host services.
      # @param registry [Registry] server-owned page registry
      # @param dispatcher [Dispatcher, nil] callback queue; nil creates a dispatcher
      # @param viewers [ViewerStore] viewer-local state and resume index
      # @param validator [Validator] component and event validator
      # @param file_service [FileService, nil] image-route resolver
      # @param logger [#call, nil] diagnostic sink accepting level and message
      # @param on_page_closed [#call, nil] callback releasing a page's owned window
      # @param window_host [#call, nil] lookup from a Page to its BrowserWindow
      # @param viewers_changed [#call, nil] notification after an owner's viewer loss
      def initialize(registry:, dispatcher: nil, viewers: ViewerStore.new,
                     validator: Validator.new, file_service: nil, logger: nil, on_page_closed: nil, window_host: nil, viewers_changed: nil)
        @registry = registry
        @on_page_closed = on_page_closed
        @window_host = window_host
        @viewers_changed = viewers_changed
        @window_close_mutex = Mutex.new
        @window_closes = ObjectSpace::WeakMap.new
        @viewers = viewers
        @validator = validator
        @file_service = file_service
        @logger = logger || proc { |_level, _message| }
        @dispatcher = dispatcher || Dispatcher.new(logger: @logger)
        @connections = {}
        @connections_mutex = Mutex.new
        @refresh_mutex = Mutex.new
        @refresh_state = {}.compare_by_identity
        @closed_owners = ObjectSpace::WeakMap.new
        @stopping = false
        @degradation_mutex = Mutex.new
        @degradations = {}.compare_by_identity
      end

      # Combines browser facilities with presentation available on the current OS.
      # Opacity support may be content-only; per-window metadata identifies native alpha.
      # @param _page [Page, nil] reserved for page-specific host selection
      # @return [Hash{Symbol => Boolean}] supported presentation properties
      def presentation_support(_page = nil)
        support = NativeHost.platform ? PRESENTATION_SUPPORT.merge(always_on_top: true, borderless: true) : PRESENTATION_SUPPORT
        support.merge(WindowPresentation.support).freeze
      end

      def degradations(page)
        @degradation_mutex.synchronize { Array(@degradations[page]).map(&:dup).freeze }
      end

      def handle(connection, message)
        case message[:type]
        when 'attach' then attach(connection, message)
        when 'detach' then detach(connection, message)
        when 'event' then event(connection, message)
        end
      rescue Protocol::Refusal => error
        log(:warning, "WebUI event refusal=#{error.reason}")
        connection.send_text(
          Protocol.refusal(reason: error.reason, message: 'Message refused', page: message[:page], cid: message[:cid],
                           event: message[:event], request: message[:request])
        )
        # Refusal must precede the replacement tree so the browser can associate
        # its one permitted retry with the exact rejected intent.
        send_render(connection, fetch_attachment(connection, message[:page])) if error.reason == :stale_generation
        :refused
      rescue Error => error
        log(:warning, "WebUI event refusal=#{error.class}")
        connection.send_text(
          Protocol.refusal(reason: :contract, message: 'Message refused', page: message[:page], cid: message[:cid],
                           event: message[:event], request: message[:request])
        )
        :refused
      end

      # Retains resumable attachments and rechecks modals after active viewers leave.
      # Enqueues every detach before notifying each owner identity once.
      # @param connection [Object] disconnected transport with a viewer_id
      # @return [void]
      def disconnect(connection)
        @connections_mutex.synchronize { @connections.delete(connection.viewer_id) }
        owners = {}.compare_by_identity
        @viewers.transient_disconnect(connection.viewer_id).each do |attachment|
          enqueue_lifecycle(attachment, :detach)
          owners[attachment.page.owner] = true
        end
        owners.each_key { |owner| @viewers_changed&.call(owner) }
      end

      # A different script's open window cannot present this owner's modal.
      # Transiently disconnected attachments are retained for resume, not counted.
      def viewers_present?(owner)
        @registry.pages_for(owner).any? { |page| !@viewers.attachments_for(page).empty? }
      end

      def read(page, cid, property, viewer: nil)
        component = page_component(page, cid)
        name = component_property(component, property)
        scope = property_scope(component, name)
        case scope
        when :sensitive_write_only
          raise SensitiveReadError.new(
            'sensitive values are write-only', owner: owner_label(page.owner), page_id: page.id,
            cid: component.cid, field: name
          )
        when :viewer
          attachment = contextual_attachment(page, component, viewer)
          @viewers.property(attachment, component, name)
        else
          page.fetch_shared_value(component.cid, name, component.props[name])
        end
      rescue KeyError
        raise UnknownPropertyError.new(
          "unknown property #{property.inspect}", owner: owner_label(page.owner), page_id: page.id,
          cid: cid, field: property
        )
      end

      def write(page, cid, property, value, viewer: nil)
        component = page_component(page, cid)
        name = component_property(component, property)
        scope = property_scope(component, name)
        if %i[sensitive_write_only ephemeral_client].include?(scope)
          raise SensitiveReadError.new(
            'sensitive and ephemeral values cannot be set through bulk state',
            owner: owner_label(page.owner), page_id: page.id, cid: component.cid, field: name
          )
        end
        validated = @validator.validate_property!(
          component.type, name, value, props: component.props,
          owner: owner_label(page.owner), page_id: page.id, cid: component.cid
        )
        if scope == :viewer
          attachment = contextual_attachment(page, component, viewer)
          @viewers.set_property(attachment, component, name, validated)
        else
          page.write_shared_value(component.cid, name, validated)
        end
        schedule_refresh(page)
        nil
      rescue KeyError
        raise UnknownPropertyError.new(
          "unknown property #{property.inspect}", owner: owner_label(page.owner), page_id: page.id,
          cid: cid, field: property
        )
      end

      # Renders and delivers a page only while its owner accepts work.
      # @param page [Page] page to refresh
      # @return [Integer] evaluated render generation
      # @raise [Error] if its owner terminated or the host stopped
      def refresh(page)
        @registry.ensure_active!(page.owner)
        page.bind_runtime(self)
        render = validated_render(page)
        @viewers.attachments_for(page).each do |attachment|
          connection = @connections_mutex.synchronize { @connections[attachment.connection_id] }
          next unless connection&.alive?

          @viewers.deliver(attachment, render)
          send_render(connection, attachment)
        end
        render.generation
      end

      # Closes admission before waiting for previously accepted work and releasing pages.
      # @param owner [Object] terminating owner identity
      # @return [Array<Page>] removed pages
      def terminate_owner(owner)
        @registry.terminate_owner(owner)
        cancel_renders(owner)
        pages = @registry.pages_for(owner)
        @dispatcher.shutdown_owner(owner)
        @registry.unregister_owner(owner)
        pages.each do |page|
          @on_page_closed&.call(page)
          @viewers.attachments_for(page).each do |attachment|
            connection = @connections_mutex.synchronize { @connections[attachment.connection_id] }
            connection&.send_text(Protocol.page_closed(address: attachment.address, reason: :owner))
          end
          @viewers.destroy_page(page)
        end
        @degradation_mutex.synchronize { pages.each { |page| @degradations.delete(page) } }
        pages
      end

      # An owned app process exiting is a real window close. A WebSocket loss
      # remains a reconnectable detach and must never terminate the script.
      def watch_window(page)
        @window_close_mutex.synchronize { @window_closes[page] = false }
      end

      def browser_closed(page)
        @registry.address_for(page)
        callback = page.lifecycle_bindings[:close]
        return unless callback && claim_window_close(page)

        context = EventContext.new(nil, page, page.last_render&.tree, :close, { reason: :user }.freeze, nil)
        @dispatcher.enqueue(
          owner: page.owner, page_id: page.id, viewer_id: nil,
          cid: page.last_render&.tree&.cid, event: :close, coalescable: false
        ) { callback.call(context) }
      rescue Error
        nil # Owner termination already removed the page or its dispatcher.
      end

      # Removes a page and its attachments, then reevaluates owner modal availability.
      # @param page [Page] page to remove
      # @param reason [Symbol] reason sent to attached viewers
      # @return [Page, nil] removed page, or nil if already absent
      def close_page(page, reason: :owner)
        address = @registry.address_for(page)
        @registry.unregister(page.owner, page.id)
        @on_page_closed&.call(page)
        @viewers.attachments_for(page).each do |attachment|
          connection = @connections_mutex.synchronize { @connections[attachment.connection_id] }
          connection&.send_text(Protocol.page_closed(address: address, reason: reason))
        end
        @viewers.destroy_page(page)
        @degradation_mutex.synchronize { @degradations.delete(page) }
        @viewers_changed&.call(page.owner)
        page
      rescue Error
        nil
      end

      # Refuses registration before draining the host's dispatcher and render workers.
      # @return [void]
      def shutdown
        @registry.stop
        @dispatcher.shutdown
        cancel_renders
      end

      # Internal core render scheduling, shared by native page updates and the
      # imperative adapter. A key has at most one worker, with changes coalesced
      # until its next render. The adapter's public port stays at ten operations.
      # The short adapter delay batches construction without blocking its caller.
      def schedule_render(key, owner:, delay: 0.01, &render)
        @refresh_mutex.synchronize do
          raise Error, 'render owner is terminated' if @stopping || @closed_owners[owner]

          state = (@refresh_state[key] ||= {
            dirty: false, thread: nil, owner: owner, work: render, delay: delay, cancelled: false
          })
          if state[:thread]&.alive?
            state[:dirty] = true
            return
          end
          state[:thread] = Thread.new { refresh_loop(key, state) }
        end
        nil
      end

      private

      def attach(connection, message)
        @connections_mutex.synchronize { @connections[connection.viewer_id] = connection }
        page = fetch_page(message[:page])
        page.bind_runtime(self)
        attachment = @viewers.attach(
          connection_id: connection.viewer_id, address: message[:page], page: page,
          resume_token: message[:resume]
        )
        render = validated_render(page)
        @viewers.deliver(attachment, render)
        send_render(connection, attachment)
        enqueue_lifecycle(attachment, :attach)
        :attached
      end

      # Removes an explicit viewer attachment and rechecks its owner's modal policies.
      # @param connection [Object] authenticated transport
      # @param message [Hash] validated detach envelope
      # @return [Symbol] :detached after removal
      # @api private
      def detach(connection, message)
        attachment = fetch_attachment(connection, message[:page])
        jobs = []
        if message[:geometry]
          # Final window measurements and close travel together, so a pending
          # meter render cannot invalidate the last size just as Chrome exits.
          payload = @validator.validate_event!(:page, :configure, message[:geometry], props: attachment.render.tree.props,
                                               owner: owner_label(attachment.page.owner), page_id: attachment.page.id,
                                               cid: attachment.render.tree.cid)
          attachment.page.observe_window_geometry(payload)
          jobs << lifecycle_job(attachment, :configure, payload)
        else
          stale!(connection, attachment) unless message[:generation] == attachment.delivered_generation
        end
        # A close handler can unregister the page immediately on its worker.
        # Capture all contexts before dispatch can clear the attachment render.
        jobs << lifecycle_job(attachment, :close, reason: :user)
        jobs << lifecycle_job(attachment, :detach)
        jobs.compact.each(&:call)
        @viewers.close(connection_id: connection.viewer_id, address: message[:page])
        @viewers_changed&.call(attachment.page.owner)
        :detached
      end

      # Validates and transfers a submission to the dispatcher with explicit disposal.
      # @api private
      # @param connection [Object] authenticated viewer connection
      # @param message [Hash] decoded event and submission values
      # @return [Symbol] :queued after dispatch accepts ownership
      # @raise [Protocol::Refusal] for invalid events or queue overflow
      def event(connection, message)
        attachment = fetch_attachment(connection, message[:page])
        stale!(connection, attachment) unless message[:generation] == attachment.delivered_generation
        component = find_component!(attachment, message[:cid])
        payload = @validator.validate_event!(
          component.type, message[:event], message[:payload] || {}, props: component.props,
          owner: owner_label(attachment.page.owner), page_id: attachment.page.id, cid: component.cid
        )
        callback = attachment.render.bindings[[component.cid, message[:event].to_sym]]
        raise Protocol::Refusal.new(:unbound, 'component event has no server binding') unless callback

        if component.type == :table && message[:event].to_sym == :row_drop
          source = find_component!(attachment, payload[:source])
          unless source.type == :table && component.props[:transfer_group] &&
                 source.props[:transfer_group] == component.props[:transfer_group] &&
                 source.props[:rows].any? { |row| row[:key] == payload[:row] }
            raise Protocol::Refusal.new(:payload, 'row transfer is outside its declared table group')
          end
        end

        snapshot = build_submission(attachment, component, message)
        attachment.page.observe_window_geometry(payload) if component.type == :page && message[:event].to_sym == :configure
        @viewers.update(attachment, component, message[:event].to_sym, payload)
        event_schema = Contract.schema(component.type)[:events].fetch(message[:event].to_sym)
        context = EventContext.new(
          attachment.viewer_id, attachment.page, component, message[:event].to_sym, payload, snapshot
        )
        @dispatcher.enqueue(
          owner: attachment.page.owner, page_id: attachment.page.id,
          viewer_id: attachment.viewer_id, cid: component.cid, event: context.event,
          coalescable: !event_schema[:terminal] && !event_schema[:lifecycle],
          cleanup: -> { snapshot&.discard_sensitive! }
        ) do
          callback.call(context)
        end
        dispatched = true
        # A control already displays its own draft. Redrawing on blur needlessly
        # changes generation before the following Save arrives. Structural
        # choices still need a render; callbacks schedule their own other edits.
        schedule_refresh(attachment.page) if event_schema[:structural]
        clear_sensitive_client(connection, snapshot)
        :queued
      rescue Dispatcher::OverflowError
        @viewers.close(connection_id: connection.viewer_id, address: message[:page])
        connection.close
        raise Protocol::Refusal.new(:overflow, 'viewer event queue overflow')
      ensure
        snapshot&.discard_sensitive! unless dispatched
      end

      def build_submission(attachment, terminal, message)
        raw_values = message.fetch(:submission, [])
        event_schema = Contract.schema(terminal.type)[:events].fetch(message[:event].to_sym)
        unless event_schema[:terminal]
          raise Protocol::Refusal.new(:submission_scope, 'submission requires a terminal event') unless raw_values.empty?

          return nil
        end
        scope = attachment.render.submissions.fetch(terminal.cid, [])
        unless raw_values.length == scope.length
          raise Protocol::Refusal.new(:submission_scope, 'submission value count does not match server scope')
        end

        components = scope.map { |cid| find_component!(attachment, cid) }
        validated = components.each_with_index.map do |component, index|
          value = @validator.validate_input_value!(
            component.type, raw_values[index], props: component.props,
            owner: owner_label(attachment.page.owner), page_id: attachment.page.id, cid: component.cid
          )
          [component, value]
        end
        values = validated.to_h do |component, value|
          if sensitive?(component)
            [component.cid, SensitiveValue.viewer(value)]
          else
            @viewers.set_input(attachment, component, value)
            [component.cid, value]
          end
        end
        Submission.new(viewer_id: attachment.viewer_id, values: values)
      ensure
        scrub_sensitive_raw!(components, raw_values) if defined?(components) && components
      end

      def scrub_sensitive_raw!(components, raw_values)
        components.each_with_index do |component, index|
          next unless sensitive?(component)
          next unless raw_values[index].is_a?(String) && !raw_values[index].frozen?

          raw_values[index].replace("\0" * raw_values[index].bytesize)
          raw_values[index].clear
        end
      end

      def clear_sensitive_client(connection, snapshot)
        sensitive_cids = snapshot&.sensitive_cids || []
        return if sensitive_cids.empty?

        connection.send_text(JSON.generate(type: 'clear_sensitive', cids: sensitive_cids))
      end

      def stale!(_connection, _attachment)
        raise Protocol::Refusal.new(:stale_generation, 'stale generation')
      end

      # Sends the delivered tree, event bindings and native-presentation ownership.
      # @param connection [#send_text] authenticated viewer connection
      # @param attachment [ViewerStore::Attachment] current viewer/page association
      # @return [Object] transport send result
      # @api private
      def send_render(connection, attachment)
        bindings = attachment.render.bindings.keys.group_by(&:first).transform_values do |pairs|
          pairs.map(&:last).map(&:to_s)
        end
        connection.send_text(
          Protocol.render(
            address: attachment.address, generation: attachment.delivered_generation,
            tree: serialize_for_client(attachment), facilities: attachment.render.facilities,
            bindings: bindings, submissions: attachment.render.submissions,
            resume: attachment.resume_token,
            window_presentation: @window_host&.call(attachment.page)&.presentation_support || {}
          )
        )
      end

      def find_component!(attachment, cid)
        component = attachment.render.tree.each.find { |candidate| candidate.cid == cid }
        return component if component

        raise Protocol::Refusal.new(:component_id, 'component is not registered for delivered page')
      end

      def serialize_for_client(attachment)
        tree = @viewers.serialize(attachment)
        rewrite_popup_addresses(tree, attachment.page.owner)
      end

      def rewrite_popup_addresses(component, owner)
        if component[:type] == 'composite' && component.dig(:props, :popup)
          popup = component[:props][:popup]
          target = @registry.fetch(owner, popup[:page])
          component[:props] = component[:props].merge(popup: popup.merge(page: @registry.address_for(target)))
        end
        component[:children].each { |child| rewrite_popup_addresses(child, owner) }
        component
      end

      def sensitive?(component)
        component.type == :password_input || component.props[:sensitive] == true
      end

      def owner_label(owner)
        return owner.webui_owner_id if owner.respond_to?(:webui_owner_id)
        return owner.name if owner.respond_to?(:name) && owner.name

        "#{owner.class}:#{owner.object_id}"
      end

      def page_component(page, cid)
        render = page.last_render || page.render
        component = render.tree.each.find { |candidate| candidate.cid == cid.to_s }
        return component if component

        raise Error.new('component is not registered', owner: owner_label(page.owner), page_id: page.id, cid: cid)
      end

      # Validates served images and popup ownership before applying native presentation.
      # @param page [Page] page whose authored render is evaluated
      # @return [Page::Render] render accepted for delivery
      # @raise [Error] if an image route or popup page is unavailable
      # @api private
      def validated_render(page)
        render = page.render
        record_presentation_degradations(page, render)
        render.tree.each do |component|
          sources = case component.type
                    when :image then [component.props[:src]]
                    when :composite
                      component.props[:layers].filter_map do |layer|
                        [layer[:src], layer[:mask]] if layer[:kind] == 'image'
                      end.flatten.compact
                    else []
                    end
          sources.each do |source|
            next if @file_service&.resolve_url(source)

            raise Error.new(
              'image source is not a registered served file', owner: owner_label(page.owner),
              page_id: page.id, cid: component.cid, field: :src
            )
          end
          next unless component.type == :composite && component.props[:popup]

          @registry.fetch(page.owner, component.props[:popup][:page])
        end
        @window_host&.call(page)&.present(render)
        render
      end

      # Records unsupported presentation requests after facility overrides are applied.
      # @param page [Page] owner of the diagnostic record
      # @param render [Page::Render] evaluated page properties and facilities
      # @return [void]
      # @api private
      def record_presentation_degradations(page, render)
        requested = (render.tree.props[:presentation] || {}).merge(render.facilities[:presentation] || {})
        refusals = requested.each_key.filter_map do |property|
          next if presentation_support(page).fetch(property)

          {
            facility: :presentation, property: property,
            reason: :unsupported_by_browser_host,
          }.freeze
        end
        @degradation_mutex.synchronize { @degradations[page] = refusals.freeze }
      end

      def fetch_page(address)
        @registry.fetch_address(address)
      rescue Error
        raise Protocol::Refusal.new(:page_gone, 'page is no longer registered', page_id: address)
      end

      def fetch_attachment(connection, address)
        fetch_page(address)
        @viewers.fetch(connection_id: connection.viewer_id, address: address)
      rescue Protocol::Refusal
        raise
      rescue Error
        raise Protocol::Refusal.new(:viewer_gone, 'viewer is no longer attached', page_id: address)
      end

      # pagehide and the process monitor can both observe one user close.
      # Unmanaged browser viewers retain their existing per-viewer semantics.
      def claim_window_close(page)
        @window_close_mutex.synchronize do
          return true unless @window_closes.key?(page)
          return false if @window_closes[page]

          @window_closes[page] = true
        end
      end

      def enqueue_lifecycle(attachment, event, payload = {})
        lifecycle_job(attachment, event, payload)&.call
      end

      def lifecycle_job(attachment, event, payload = {})
        callback = attachment.page.lifecycle_bindings[event]
        return unless callback
        return if event == :close && !claim_window_close(attachment.page)

        component = attachment.render.tree
        context = EventContext.new(
          attachment.viewer_id, attachment.page, component, event, payload.freeze, nil
        )
        proc do
          @dispatcher.enqueue(
            owner: context.page.owner, page_id: context.page.id,
            viewer_id: context.viewer_id, cid: component.cid, event: event, coalescable: false
          ) { callback.call(context) }
        end
      end

      def component_property(component, property)
        key = property.to_sym
        return key unless key == :value

        case component.type
        when :toggle, :checkbox then :checked
        when :radio then :selected
        else :value
        end
      end

      def property_scope(component, name)
        schema = Contract.schema(component.type)
        return :sensitive_write_only if name == :value && sensitive?(component)

        definition = schema.fetch(:properties)[name]
        return definition[:scope] if definition
        return schema[:value_scope] if name == :value && schema[:value]

        raise KeyError, name
      end

      def contextual_attachment(page, component, viewer)
        selected = @dispatcher.current_context&.viewer_id || viewer
        viewer_id = selected.respond_to?(:viewer_id) ? selected.viewer_id : selected
        unless viewer_id
          raise AmbiguousViewerError.new(
            'viewer-local access requires callback context or an explicit viewer',
            owner: owner_label(page.owner), page_id: page.id, cid: component.cid
          )
        end

        @viewers.attachment_for_viewer(page, viewer_id.to_s)
      end

      def schedule_refresh(page)
        schedule_render(page, owner: page.owner, delay: 0) { refresh(page) }
      end

      def refresh_loop(key, state)
        loop do
          sleep(state[:delay]) if state[:delay].positive?
          break if @refresh_mutex.synchronize { state[:cancelled] }

          state[:work].call
          repeat = @refresh_mutex.synchronize do
            dirty = state[:dirty]
            state[:dirty] = false
            @refresh_state.delete(key) unless dirty
            dirty
          end
          break unless repeat
        end
      rescue StandardError => error
        log(:error, "WebUI refresh failed owner=#{owner_label(state[:owner])} error=#{error.class}")
      ensure
        @refresh_mutex.synchronize do
          @refresh_state.delete(key) if @refresh_state[key].equal?(state)
        end
      end

      # Join already admitted renders before unregistering pages. Otherwise an
      # adapter could publish a page immediately after its owner was removed.
      def cancel_renders(owner = nil)
        threads = @refresh_mutex.synchronize do
          owner ? @closed_owners[owner] = true : @stopping = true
          @refresh_state.values.filter_map do |state|
            next if owner && !state[:owner].equal?(owner)

            state[:cancelled] = true
            state[:thread]
          end
        end
        threads.each { |thread| thread.join unless thread.equal?(Thread.current) }
      end

      def log(level, message)
        @logger.call(level, message)
      rescue StandardError
        nil
      end
    end
  end
end
