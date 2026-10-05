# frozen_string_literal: true

require_relative 'future'
require_relative 'page'

module Lich
  module WebUI
    # Owns modal registration and the response/timeout/termination race.
    class ModalCoordinator
      Pending = Data.define(:owner, :page, :future, :timer)

      def initialize(registry:, runtime:, viewers_present:, pages_changed:, logger: nil)
        @registry = registry
        @runtime = runtime
        @viewers_present = viewers_present
        @pages_changed = pages_changed
        @logger = logger || proc { |_level, _message| }
        @pending = {}.compare_by_identity
        @mutex = Mutex.new
      end

      def open(owner:, id:, title:, buttons:, no_viewer:, body: nil, default_button: nil,
               timeout: nil, credential: false, props: {}, page_props: {}, on_response: nil, &content)
        raise ArgumentError, 'credential modals cannot wait for a viewer' if credential && no_viewer.to_s == 'wait'

        props = props.merge(
          title: title, body: body, buttons: buttons, no_viewer: no_viewer,
          default_button: default_button, timeout: timeout,
        ).compact
        props = Validator.new.validate_component!(
          :dialog, props, owner: owner_label(owner), page_id: id, cid: "page:#{id}/dialog:modal"
        )
        page_props = Validator.new.validate_component!(
          :page, page_props.merge(title: title), owner: owner_label(owner), page_id: id, cid: "page:#{id}"
        )
        future = Future.new
        unless @viewers_present.call(owner)
          return resolve_absent_viewer(future, props) unless props[:no_viewer] == 'wait'
        end

        # Custom native forms use the same terminal submission validation as
        # buttons. A response handler may retain the modal while a warning is
        # pending, but must resolve/cancel its completion without blocking.
        response = proc do |event|
          if on_response
            on_response.call(event, future)
          else
            future.resolve(button: event.payload[:button])
          end
        rescue StandardError
          future.cancel(reason: :error)
          raise
        end
        page = nil
        page = Page.new(owner: owner, id: id, title: title, props: page_props,
                        on: { close: proc { future.cancel(reason: :cancelled) } }) do
          dialog(
            key: 'modal', **props,
            on: { response: response }
          ) do |dialog|
            if content
              # Existing one-argument modal blocks keep their calling convention.
              on_response ? instance_exec(self, dialog, &content) : instance_exec(self, &content)
            end
          end
        end
        @registry.register(page, modal: true)
        registered = true
        page.bind_runtime(@runtime)
        timer = timeout && Thread.new do
          sleep(timeout)
          future.resolve(reason: :timeout)
        end
        @mutex.synchronize { @pending[future] = Pending.new(owner, page, future, timer) }
        future.then { |result| complete(future, result) }
        cleanup_installed = true
        @pages_changed.call
        future
      rescue StandardError
        future&.cancel(reason: :error)
        unless cleanup_installed
          timer&.kill
          @runtime.close_page(page, reason: :error) if registered
        end
        raise
      end

      def terminate_owner(owner)
        futures = @mutex.synchronize do
          @pending.values.select { |pending| pending.owner.equal?(owner) }.map(&:future)
        end
        futures.each { |future| future.cancel(reason: :terminated) }
        futures.length
      end

      def pending_count
        @mutex.synchronize { @pending.length }
      end

      private

      def resolve_absent_viewer(future, props)
        if props[:no_viewer] == 'default'
          future.resolve(button: props[:default_button], reason: :no_viewer)
        else
          future.resolve(reason: :no_viewer)
        end
        future
      end

      def complete(future, result)
        pending = @mutex.synchronize { @pending.delete(future) }
        return unless pending

        pending.timer&.kill unless pending.timer.equal?(Thread.current)
        reason = result.reason || :response
        @runtime.close_page(pending.page, reason: reason)
        @pages_changed.call
      rescue StandardError => error
        @logger.call(:warning, "WebUI modal cleanup failed=#{error.class}")
      end

      def owner_label(owner)
        return owner.webui_owner_id if owner.respond_to?(:webui_owner_id)
        return owner.name if owner.respond_to?(:name) && owner.name

        "#{owner.class}:#{owner.object_id}"
      end
    end
  end
end
