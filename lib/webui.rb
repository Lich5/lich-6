# frozen_string_literal: true

require_relative 'webui/contract'
require_relative 'webui/adapter'
require_relative 'webui/browser_launcher'
require_relative 'webui/dispatcher'
require_relative 'webui/errors'
require_relative 'webui/page'
require_relative 'webui/future'
require_relative 'webui/image_size'
require_relative 'webui/settings_form'
require_relative 'webui/modal_coordinator'
require_relative 'webui/protocol'
require_relative 'webui/registry'
require_relative 'webui/runtime'
require_relative 'webui/server'
require_relative 'webui/service'
require_relative 'webui/sensitive_value'
require_relative 'webui/validator'
require_relative 'webui/viewer_store'
require_relative 'webui/websocket'
require_relative 'common/script_death'

module Lich
  module WebUI
    INITIALIZATION_MUTEX = Mutex.new

    class << self
      attr_writer :registry, :service

      def registry
        INITIALIZATION_MUTEX.synchronize { @registry ||= Registry.new }
      end

      def page(owner:, id:, title:, props: {}, on: {}, &render_block)
        page = registry.register(Page.new(owner: owner, id: id, title: title, props: props, on: on, &render_block))
        page.bind_runtime(service.runtime)
      end

      def service
        INITIALIZATION_MUTEX.synchronize do
          if @service&.stopped?
            @service = nil
            @registry = Registry.new
          end
          @registry ||= Registry.new
          @service ||= Service.new(registry: @registry)
        end
      end

      # Hosting is core-owned: compatibility consumers obtain an opaque port
      # without managing servers, transport, page registries or browser windows.
      # Opening follows the first valid render, once per page.
      def adapter(owner:, viewer: nil)
        host = service
        Adapter.new(owner: owner, service: host, viewer: viewer, on_publish: proc do |page|
          host.start
          host.server.broadcast(type: 'pages', pages: host.registry.descriptors)
          BrowserLauncher.open(host.launch_url(page: page))
        end)
      end

      def start
        service.start
      end

      def launch_url(page: nil)
        service.launch_url(page: page)
      end

      def open(page: nil)
        BrowserLauncher.open(launch_url(page: page))
      end

      def refresh(page)
        service.refresh(page)
      end

      # Native consumers close their own page through the core host. Delivery,
      # viewer disposal and address removal remain runtime responsibilities.
      def close(page)
        service.runtime.close_page(page)
      end

      def terminate_owner(owner)
        service.terminate_owner(owner)
      end

      def modal(**options, &content)
        service.modal(**options, &content)
      end

      def reset!
        service = INITIALIZATION_MUTEX.synchronize do
          current = @service
          @service = nil
          @registry = Registry.new
          current
        end
        service&.stop
      end
    end

    # This applies to native script pages as well as imperative consumers.
    # Do not initialize a host merely because a non-UI script has ended.
    Common::ScriptDeath.on_death do |owner|
      current = INITIALIZATION_MUTEX.synchronize { @service }
      current&.terminate_owner(owner) unless current&.stopped?
    end
  end
end
