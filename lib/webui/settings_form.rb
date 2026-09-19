# frozen_string_literal: true

module Lich
  module WebUI
    # Native setup forms share terminal submission and cancellation, not game
    # logic. go2, ecleanse and ewaggle supply their own fields and normalization.
    # No draft is persisted here; the owning script receives one accepted copy.
    class SettingsForm
      attr_reader :page

      def initialize(owner:, id:, title:, values:, fields:, normalize: nil, tabbed: false)
        @owner, @id, @title = owner, id, title
        @values = copy(values)
        @fields = copy(fields)
        @normalize = normalize || proc { |draft| draft }
        @tabbed = tabbed
        @input_revision = 0
        @completion = Future.new
        @error = ''
        keys = @fields.map { |field| field.fetch(:key) }
        raise ArgumentError, 'form field keys must be unique' unless keys.uniq == keys
      end

      def self.edit(**options)
        new(**options).show.wait
      end

      def show
        raise ArgumentError, 'form is already shown' if @page

        form = self
        @page = WebUI.page(owner: @owner, id: @id, title: @title, on: { close: proc { close } }) do |builder|
          form.send(:render, builder)
        end
        WebUI.refresh(@page)
        WebUI.start
        WebUI.open(page: @page)
        self
      rescue StandardError
        close
        raise
      end

      # Called on the owning script thread, never from an event callback.
      def wait
        @completion.await.button
      ensure
        close
      end

      def close
        @completion.cancel
        WebUI.close(@page) if @page
        nil
      end

      private

      def render(builder)
        refs = {}
        form = self
        groups = @fields.group_by { |field| field.fetch(:group, 'Settings') }
        if @tabbed
          builder.tabs(key: 'sections', names: groups.keys, selected: 0, on: { select: proc {} }) do
            form.send(:render_groups, self, groups, refs, tabbed: true)
          end
        else
          render_groups(builder, groups, refs)
        end
        builder.text(key: 'validation', content: @error, tone: :danger)
        render_actions(builder, refs)
        builder.button(key: 'save', label: 'Save & Close', submit: refs.values,
                       on: { activate: proc { |event| save(event.submission, refs) } })
        builder.button(key: 'cancel', label: 'Cancel', on: { activate: proc { close } })
      end

      # Domain forms may add an explicit, non-saving action over the same
      # terminal field references (for example Eloot's tipping preview).
      # They reuse field rendering and lifecycle without exposing viewer drafts.
      def render_actions(_builder, _refs); end

      # Explicit reset/load actions replace the submitted draft. Fresh input
      # identities prevent a viewer's older dirty value overriding that reset.
      def replace_values(values)
        @values = copy(values)
        @input_revision += 1
      end

      # Large native setup screens retain the same terminal submission across
      # viewer-local tabs; switching a tab neither saves nor shares a draft.
      def render_groups(builder, groups, refs, tabbed: false)
        form = self
        groups.each_with_index do |(label, fields), index|
          builder.group(label: label, key: "section-#{index}", slot: tabbed ? label : nil) do
            fields.each do |field|
              key = field.fetch(:key)
              type = field.fetch(:type)
              props = field.reject { |name, _| %i[type group].include?(name) }
              props[:key] = form.send(:input_key, key)
              if type == :text
                component(type, **props)
                next
              end
              props[type == :checkbox ? :checked : :value] = form.send(:field_value, key, type)
              refs[key] = component(type, **props)
            end
          end
        end
      end

      def input_key(key)
        @input_revision.zero? ? key.to_s : "#{key}--revision-#{@input_revision}"
      end

      def field_value(key, type)
        value = @values.fetch(key)
        type == :textarea && value.is_a?(Array) ? value.join("\n") : value
      end

      def save(submission, refs)
        return if @completion.resolved?

        draft = copy(@values)
        refs.each { |key, ref| draft[key] = submission[ref.cid] }
        result = @normalize.call(copy(draft))
        raise ArgumentError, 'form normalization must return settings' unless result.is_a?(Hash)

        @completion.resolve(button: result)
        WebUI.close(@page)
      rescue ArgumentError => error
        @values = draft if draft
        @error = error.message[0, Contract::BOUNDS[:body_text]]
        WebUI.refresh(@page)
      end

      def copy(value)
        case value
        when Hash then value.to_h { |key, item| [key, copy(item)] }
        when Array then value.map { |item| copy(item) }
        when String then value.dup
        else value
        end
      end
    end
  end
end
