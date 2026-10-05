# frozen_string_literal: true

module Lich
  module WebUI
    # Native setup forms share terminal submission and cancellation, not game
    # logic. go2, ecleanse and ewaggle supply their own fields and normalization.
    # No draft is persisted here; the owning script receives one accepted copy.
    class SettingsForm
      attr_reader :page

      def initialize(owner:, id:, title:, values:, fields:, normalize: nil, tabbed: false, layout: nil, props: {})
        @owner, @id, @title = owner, id, title
        @values = copy(values)
        @fields = copy(fields)
        @normalize = normalize || proc { |draft| draft }
        @tabbed = tabbed
        @layout = layout
        @props = { bare: true, theme: :light, density: :compact }.merge(props)
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
        @page = WebUI.page(owner: @owner, id: @id, title: @title, props: @props, on: { close: proc { close } }) do |builder|
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
        if @layout
          # The script supplies native layout only. Field values, submission
          # scope and cancellation stay in this shared form lifecycle.
          @layout.call(builder,
                       ->(parent, key, **overrides) { render_field(parent, @fields.find { |field| field[:key] == key }, refs, **overrides) },
                       ->(parent, **props) { render_save(parent, refs, **props) })
          builder.text(key: 'validation', content: @error, tone: :danger) unless @error.empty?
          return
        end
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
        render_save(builder, refs)
        builder.button(key: 'cancel', label: 'Cancel', on: { activate: proc { close } })
      end

      # Domain forms may add an explicit, non-saving action over the same
      # terminal field references (for example Eloot's tipping preview).
      # They reuse field rendering and lifecycle without exposing viewer drafts.
      def render_actions(_builder, _refs); end

      def render_save(builder, refs, label: 'Save & Close', **props)
        builder.button(key: 'save', label: label, **props, submit: refs.values,
                       on: { activate: proc { |event| save(event.submission, refs) } })
      end

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
              form.send(:render_field, self, field, refs)
            end
          end
        end
      end

      def render_field(builder, field, refs, **overrides)
        return unless field # Some original controls are absent outside GS.

        key, type = field.values_at(:key, :type)
        props = field.reject { |name, _| %i[type group exclusive].include?(name) }.merge(overrides)
        props.delete(:label) if props[:label].nil?
        props[:label] = '' if type == :checkbox && !props.key?(:label)
        props[:key] = input_key(key)
        return builder.component(type, **props) if type == :text

        # Script-owned live settings callbacks mirror GtkEntry's changed signal.
        # Forms without one retain the ordinary committed-entry timing.
        props[:change_mode] ||= :input if type == :text_input && props[:on]&.key?(:change)

        props[type == :checkbox ? :checked : :value] = field_value(key, type)
        props.delete(:value) if type == :select && props[:value].nil?
        if field[:exclusive]
          changed = props[:on]&.fetch(:change, nil)
          props[:on] = { change: proc do |event|
            changed&.call(event)
            next unless event.payload[:value]
            @fields.select { |other| other[:exclusive] == field[:exclusive] && other[:key] != key }.each do |other|
              @page.set(refs.fetch(other[:key]).cid, :checked, false, viewer: event.viewer_id)
            end
          end }
        end
        refs[key] = builder.component(type, **props)
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
