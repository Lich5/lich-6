# frozen_string_literal: true

require_relative 'errors'

module Lich
  module WebUI
    # Machine-readable authority for SPEC-WEBUI-CONTRACT 2.5.0 SS10 and SS14.
    module Contract
      VERSION = '2.15.0'
      MAJOR_VERSION = 2

      TYPES = %i[
        page group stack columns grid tabs expander split overlay scroll divider
        text markdown log progress image
        button toggle checkbox radio radio_option text_input password_input textarea number_input slider select
        table dialog composite
      ].freeze

      STRUCTURE_TYPES = TYPES.first(11).freeze
      DISPLAY_TYPES = TYPES.slice(11, 5).freeze
      INPUT_TYPES = TYPES.slice(16, 10).freeze

      TONES = %w[neutral positive caution danger].freeze
      EMPHASES = %w[normal strong subtle].freeze
      ALIGNS = %w[start center end stretch].freeze
      IDENTIFIER = /\A[A-Za-z0-9_.:-]{1,128}\z/
      CID_PATTERN = /\A[A-Za-z0-9_.:-]+(?:\/[A-Za-z0-9_.:-]+)*\z/

      BOUNDS = {
        identifier: 128,
        short_text: 512,
        body_text: 8192,
        rich_text: 65_536,
        input_text: 8192,
        multiline_text: 65_536,
        log_line: 4096,
        log_lines: 10_000,
        collection: 512,
        table_rows: 10_000,
        table_columns: 64,
        children: 1024,
        components: 20_000,
        tree_depth: 64,
        geometry: (-65_536..65_536),
        timeout: (1..86_400),
        event_payload_bytes: 65_536,
      }.freeze

      module_function

      # Describes a scalar kind and its validator constraints.
      # @return [Hash] shape definition
      def scalar(kind, **constraints)
        { kind: kind, **constraints }
      end

      # Describes a string, optionally using a named contract length bound.
      # @return [Hash] shape definition
      def string(bound = nil, **constraints)
        scalar(:string, **({ bound: bound }.compact), **constraints)
      end

      # Describes an integer with optional inclusive limits.
      # @return [Hash] shape definition
      def integer(min: nil, max: nil, **constraints)
        scalar(:integer, **({ min: min, max: max }.compact), **constraints)
      end

      # Describes a finite number with optional inclusive limits.
      # @return [Hash] shape definition
      def number(min: nil, max: nil)
        scalar(:number, finite: true, **({ min: min, max: max }.compact))
      end

      # Describes a closed set of string values, accepting nested value lists.
      # @return [Hash] shape definition
      def enum(*values)
        scalar(:enum, values: values.flatten.map(&:to_s))
      end

      # Describes an ordered collection with cardinality and item constraints.
      # @return [Hash] shape definition
      def array(items, min: 0, max: nil)
        scalar(:array, items: items, min: min, **({ max: max }.compact))
      end

      # Describes named fields; unknown fields are refused unless explicitly allowed.
      # Supply fields as either a positional hash or keywords, never both.
      # @return [Hash] shape definition
      # @raise [ArgumentError] if fields are supplied twice
      def record(fields = nil, allow_extra: false, **field_keywords)
        raise ArgumentError, 'record fields supplied twice' if fields && !field_keywords.empty?

        scalar(:record, fields: fields || field_keywords, allow_extra: allow_extra)
      end

      # Describes alternatives accepted when any one shape validates.
      # @return [Hash] shape definition
      def union(*variants)
        scalar(:union, variants: variants)
      end

      # Describes property ownership, requiredness, and an optional default.
      # The sentinel distinguishes no default from an explicit nil default.
      # @return [Hash] property definition
      def property(shape, required: false, scope: :shared, default: :__none__)
        result = { shape: shape, required: required, scope: scope }
        result[:default] = default unless default == :__none__
        result
      end

      # Describes an event payload and its dispatch/lifecycle classification.
      # @return [Hash] event definition
      def event(payload = nil, terminal: false, lifecycle: false, structural: false)
        { payload: payload, terminal: terminal, lifecycle: lifecycle, structural: structural }
      end

      SHORT = string(:short_text).freeze
      BODY = string(:body_text).freeze
      IDENT = string(:identifier, pattern: IDENTIFIER).freeze
      CID = string(:body_text, pattern: CID_PATTERN).freeze
      BOOL = scalar(:boolean).freeze
      ANY_NUMBER = number.freeze
      GEOMETRY = integer(min: BOUNDS[:geometry].begin, max: BOUNDS[:geometry].end).freeze
      SCROLL_PIXELS = integer(min: 0, max: BOUNDS[:geometry].end).freeze

      # One shape for declarative facilities and imperative shim window state.
      PRESENTATION = record(
        always_on_top: property(BOOL), borderless: property(BOOL),
        opacity: property(number(min: 0.1, max: 1.0)), scrollbars: property(BOOL)
      ).freeze

      OPTION = record(
        value: property(string(:input_text), required: true),
        label: property(SHORT, required: true)
      ).freeze
      OPTIONS = array(OPTION, max: BOUNDS[:collection]).freeze

      BUTTON_DEF = record(
        id: property(IDENT, required: true),
        label: property(SHORT, required: true),
        variant: property(enum(:default, :primary, :danger), default: 'default')
      ).freeze

      ATTRIBUTE_APPLICABILITY = {
        page: %i[key width height min_height],
        group: %i[key tooltip disabled hidden align margin width height min_height tone],
        stack: %i[key hidden align margin width height],
        columns: %i[key hidden align margin width height],
        grid: %i[key hidden align margin width height],
        tabs: %i[key disabled hidden align margin width height],
        expander: %i[key tooltip disabled hidden align margin width height],
        split: %i[key hidden align margin width height],
        overlay: %i[key hidden align margin width height],
        scroll: %i[key hidden align margin width height],
        divider: %i[key hidden margin width tone],
        text: %i[key tooltip hidden align margin width height emphasis tone],
        markdown: %i[key hidden align margin width],
        log: %i[key hidden align margin width height],
        progress: %i[key tooltip hidden align margin width height tone],
        image: %i[key tooltip hidden align margin width height],
        button: %i[key tooltip disabled hidden align margin width min_height emphasis tone],
        toggle: %i[key tooltip disabled hidden align margin width tone],
        checkbox: %i[key tooltip disabled hidden align margin width tone],
        radio: %i[key tooltip disabled hidden align margin width tone],
        radio_option: %i[key tooltip disabled hidden align margin width tone],
        text_input: %i[key tooltip disabled hidden align margin width tone sensitive],
        password_input: %i[key tooltip disabled hidden align margin width sensitive],
        textarea: %i[key tooltip disabled hidden align margin width height sensitive],
        number_input: %i[key tooltip disabled hidden align margin width tone sensitive],
        slider: %i[key tooltip disabled hidden align margin width tone],
        select: %i[key tooltip disabled hidden align margin width min_height tone sensitive],
        table: %i[key disabled hidden align margin width height min_height],
        dialog: %i[key width height min_height tone],
        composite: %i[key tooltip hidden align margin width height],
      }.freeze

      ATTRIBUTE_SCHEMAS = {
        key: property(IDENT),
        tooltip: property(string(:body_text)),
        disabled: property(BOOL),
        hidden: property(BOOL),
        align: property(enum(*ALIGNS)),
        margin: property(union(integer(min: 0, max: 512), record(
                                                            top: property(integer(min: 0, max: 512)),
                                                            right: property(integer(min: 0, max: 512)),
                                                            bottom: property(integer(min: 0, max: 512)),
                                                            left: property(integer(min: 0, max: 512))
                                                          ))),
        width: property(GEOMETRY),
        height: property(GEOMETRY),
        min_height: property(GEOMETRY),
        emphasis: property(enum(*EMPHASES)),
        tone: property(enum(*TONES)),
        sensitive: property(BOOL),
      }.freeze

      ACCESSIBILITY_SCHEMAS = {
        a11y_label: property(SHORT),
        a11y_description: property(BODY),
        a11y_role: property(IDENT),
      }.freeze

      BASE_SCHEMAS = {
        page: {
          properties: {
            title: property(SHORT, required: true), bare: property(BOOL, default: false),
            theme: property(enum(:light, :dark)), density: property(enum(:compact, :normal)),
            viewport: property(BOOL, default: false),
            presentation: property(PRESENTATION),
            size: property(array(GEOMETRY, min: 2, max: 2)),
            resize_request: property(record(id: property(IDENT, required: true),
                                            size: property(array(integer(min: 1, max: BOUNDS[:geometry].end), min: 2, max: 2), required: true))),
            position: property(array(integer(min: -65_536, max: 65_536), min: 2, max: 2)),
          }, children: :many, events: {}, value: nil,
        },
        group: {
          # Omission means no label widget; an empty string retains the blank label requisition.
          properties: { label: property(SHORT), collapsible: property(BOOL, default: false),
                        menu: property(enum(:context, :submenu)),
                        open: property(BOOL, scope: :viewer),
                        popup_position: property(array(GEOMETRY, min: 2, max: 2), scope: :viewer), constrain_width: property(BOOL, default: false) },
          children: :many, events: {}, value: nil,
        },
        stack: {
          properties: { gap: property(integer(min: 0, max: 64), default: 8),
                        orientation: property(enum(:vertical, :horizontal), default: 'vertical') },
          children: :many, events: {}, value: nil,
        },
        columns: {
          properties: {
            count: property(integer(min: 1, max: 12), required: true),
            weights: property(array(integer(min: 0), max: 12)), compact: property(BOOL, default: false),
            row_align: property(enum(:start, :center, :end, :stretch)),
            gap: property(integer(min: 0, max: 64), default: 8),
          }, children: { kind: :named_dynamic, count_property: :count }, events: {}, value: nil,
        },
        grid: {
          properties: {
            cols: property(integer(min: 1, max: 24), required: true),
            homogeneous: property(BOOL, default: true), equal_rows: property(BOOL, default: false),
            expand_columns: property(array(integer(min: 1, max: 24), max: 24)),
            row_sizing: property(enum(:auto, :spread), default: :auto),
            cells: property(integer(min: 0, max: BOUNDS[:children])),
            gap: property(integer(min: 0, max: 64), default: 8),
            row_gap: property(integer(min: 0, max: 64)), column_gap: property(integer(min: 0, max: 64)),
          }, children: :many, child_properties: {
            column: property(integer(min: 1, max_property: :cols)),
            row: property(integer(min: 1, max: BOUNDS[:children])),
            span: property(integer(min: 1, max_property: :cols)),
            row_span: property(integer(min: 1, max: 24)),
          }, events: {}, value: nil,
        },
        tabs: {
          properties: {
            names: property(array(SHORT, min: 1, max: BOUNDS[:collection]), required: true),
            vertical: property(BOOL, default: false), selected: property(integer(min: 0), scope: :viewer),
            size_to_all: property(BOOL, default: false),
            show_tabs: property(BOOL, default: true),
          }, children: { kind: :named_from_property, property: :names },
          events: { select: event(record(index: property(integer(min: 0), required: true)), structural: true) }, value: nil,
        },
        expander: {
          properties: { label: property(SHORT, required: true), open: property(BOOL, default: false, scope: :viewer) },
          children: :many, events: { toggle: event(record(open: property(BOOL, required: true)), structural: true) }, value: nil,
        },
        split: {
          properties: {
            orientation: property(enum(:horizontal, :vertical), required: true),
            position: property(integer(min: 0, max: 100), scope: :viewer),
            position_pixels: property(integer(min: 0, max: 65_536)),
            resize_side: property(enum(:first)),
          }, children: { kind: :named, slots: %w[first second] },
          events: { move: event(record(position: property(integer(min: 0, max: 100), required: true))) }, value: nil,
        },
        overlay: {
          properties: {}, children: :many,
          child_properties: { z: property(integer(min: 0, max: 99)) }, events: {}, value: nil,
        },
        scroll: {
          properties: {
            max_height: property(GEOMETRY), scroll_to: property(IDENT, scope: :viewer),
            fill: property(BOOL, default: false), scrollbars: property(BOOL, default: true),
            scroll_position: property(SCROLL_PIXELS, scope: :viewer),
          },
          children: :many,
          events: { scrolled: event(record(
                                      position: property(SCROLL_PIXELS, required: true),
                                      upper: property(SCROLL_PIXELS),
                                      page_size: property(SCROLL_PIXELS)
                                    )) }, value: nil,
        },
        divider: { properties: { label: property(SHORT) }, children: :none, events: {}, value: nil },
        text: {
          properties: { content: property(BODY, required: true), wrap: property(BOOL, default: true),
                        fragments: property(array(BODY, max: BOUNDS[:collection])),
                        max_width_chars: property(integer(min: 1, max: 1024)),
                        ellipsize: property(enum(:middle)) },
          children: :none, events: {}, value: nil,
        },
        markdown: {
          properties: { content: property(string(:rich_text), required: true) }, children: :none, events: {}, value: nil,
        },
        log: {
          properties: {
            lines: property(array(union(string(:log_line), array(string(:log_line), max: BOUNDS[:collection])), max: BOUNDS[:log_lines]), required: true),
            max_lines: property(integer(min: 1, max: BOUNDS[:log_lines]), required: true),
            follow: property(BOOL, default: true), wrap: property(enum(:word, :none), default: :word),
          }, children: :none, events: {}, value: nil,
        },
        progress: {
          properties: {
            value: property(number(min: 0.0, max: 1.0)), label: property(SHORT),
            indeterminate: property(BOOL, default: false),
          }, children: :none, events: {}, value: nil,
        },
        image: {
          properties: {
            src: property(string(:body_text), required: true), alt: property(SHORT),
            scale: property(number(min: 0.1, max: 8.0), default: 1.0),
          }, children: :none, events: {}, value: nil,
        },
        button: {
          properties: {
            label: property(SHORT, required: true),
            variant: property(enum(:default, :primary, :danger), default: 'default'), confirm: property(SHORT),
            indicator: property(enum(:check, :radio)), checked: property(BOOL, default: false),
          }, children: :none, events: { activate: event(nil, terminal: true) }, value: nil,
        },
        toggle: {
          properties: { label: property(SHORT), checked: property(BOOL, required: true, scope: :viewer),
                        appearance: property(enum(:checkbox, :button, :menu), default: :checkbox) },
          children: :none, events: { change: event(record(value: property(BOOL, required: true))), activate: event(nil, terminal: true) }, value: BOOL,
        },
        checkbox: {
          properties: { label: property(SHORT, required: true), checked: property(BOOL, required: true, scope: :viewer) },
          children: :none, events: { change: event(record(value: property(BOOL, required: true))) }, value: BOOL,
        },
        # Independently placed members share exclusive selection within one page/viewer.
        radio_option: {
          properties: { appearance: property(enum(:radio, :menu), default: :radio), label: property(SHORT, required: true), group: property(IDENT, required: true),
                        checked: property(BOOL, required: true, scope: :viewer) },
          children: :none, events: { change: event(record(value: property(BOOL, required: true))), activate: event(nil, terminal: true) }, value: BOOL,
        },
        radio: {
          properties: {
            label: property(SHORT, required: true), group: property(IDENT, required: true),
            orientation: property(enum(:horizontal, :vertical), default: 'horizontal'),
            gap: property(integer(min: 0, max: 64), default: 12),
            options: property(OPTIONS, required: true), selected: property(string(:input_text), scope: :viewer),
          }, children: :none,
          events: { change: event(record(value: property(string(:input_text), required: true))) },
          value: string(:input_text), value_scope: :viewer,
        },
        text_input: {
          properties: {
            label: property(SHORT), value: property(string(:input_text), required: true, scope: :viewer),
            placeholder: property(SHORT), max_length: property(integer(min: 1, max: 8192)),
            search: property(BOOL, default: false),
            # GTK changed handlers and activate/focus-out handlers have different
            # timing. Keep existing committed changes unless explicitly opted in.
            change_mode: property(enum(:commit, :input), default: :commit),
          }, children: :none,
          events: {
            change: event(record(value: property(string(:input_text), required: true))),
            # Focus changes can execute source logic; never coalesce them.
            focus: event(nil, lifecycle: true),
            submit: event(nil, terminal: true),
          }, value: string(:input_text), value_scope: :viewer,
        },
        password_input: {
          properties: {
            label: property(SHORT), placeholder: property(SHORT),
            max_length: property(integer(min: 1, max: 8192)),
            revealable: property(BOOL, default: false, scope: :ephemeral_client),
          }, children: :none, events: { submit: event(nil, terminal: true) },
          value: string(:input_text), value_scope: :sensitive_write_only, sensitive: true,
        },
        textarea: {
          properties: {
            read_only: property(BOOL, default: false), cursor_visible: property(BOOL, default: true),
            wrap: property(enum(:word, :none), default: :word), follow: property(BOOL, default: false),
            label: property(SHORT), value: property(string(:multiline_text), required: true, scope: :viewer),
            rows: property(integer(min: 1, max: 64), default: 5),
            max_length: property(integer(min: 1, max: 65_536)),
          }, children: :none,
          events: { change: event(record(value: property(string(:multiline_text), required: true))) },
          value: string(:multiline_text), value_scope: :viewer,
        },
        number_input: {
          properties: {
            stepper_buttons: property(BOOL, default: false),
            digits: property(integer(min: 0, max: 20)),
            acceleration: property(number(min: 0)), page_step: property(number(min: 0)),
            snap_to_step: property(BOOL, default: true),
            label: property(SHORT), value: property(ANY_NUMBER, required: true, scope: :viewer),
            min: property(ANY_NUMBER, required: true), max: property(ANY_NUMBER, required: true),
            step: property(ANY_NUMBER, default: 1),
          }, children: :none,
          events: { change: event(record(value: property(ANY_NUMBER, required: true))) },
          value: ANY_NUMBER, value_scope: :viewer,
        },
        slider: {
          properties: {
            label: property(SHORT), value: property(ANY_NUMBER, required: true, scope: :viewer),
            min: property(ANY_NUMBER, required: true), max: property(ANY_NUMBER, required: true),
            step: property(ANY_NUMBER, default: 1),
          }, children: :none,
          events: { change: event(record(value: property(ANY_NUMBER, required: true))) },
          value: ANY_NUMBER, value_scope: :viewer,
        },
        select: {
          properties: {
            label: property(SHORT), options: property(OPTIONS, required: true),
            editable: property(BOOL, default: false), placeholder: property(SHORT),
            # Optional disjoint encoding for free text when labels and option IDs differ.
            free_text_prefix: property(SHORT),
            empty_value: property(string(:input_text)),
            value: property(string(:input_text), scope: :viewer),
          }, children: :none,
          events: { change: event(record(value: property(string(:input_text), required: true))) },
          value: string(:input_text), value_scope: :viewer,
        },
        table: { properties: {}, children: :none, events: {}, value: nil, special: :table },
        dialog: {
          properties: {
            title: property(SHORT, required: true), show_title: property(BOOL, default: true), body: property(BODY),
            buttons: property(array(BUTTON_DEF, min: 1, max: BOUNDS[:collection]), required: true),
            no_viewer: property(enum(:wait, :default, :abort), required: true),
            cancel_button: property(IDENT), default_button: property(IDENT), timeout: property(integer(min: 1, max: 86_400)),
          }, children: :many,
          events: { response: event(record(button: property(IDENT, required: true)), terminal: true) }, value: nil,
        },
        composite: { properties: {}, children: :none, events: {}, value: nil, special: :composite },
      }.freeze

      TABLE_COLUMN = record(
        key: property(IDENT, required: true), label: property(SHORT, required: true),
        align: property(enum(:start, :center, :end), default: 'start'), width: property(GEOMETRY),
        sortable: property(BOOL, default: false), resizable: property(BOOL, default: false),
        editor: property(scalar(:editor), default: nil),
        color_preview: property(record(width: property(integer(min: 1, max: 128), required: true),
                                       height: property(integer(min: 1, max: 128), required: true)))
      ).freeze
      TABLE_ROW = record(
        key: property(IDENT, required: true), parent: property(IDENT),
        expanded: property(BOOL, default: false, scope: :viewer),
        cells: property(scalar(:cell_map), required: true),
        # Preserve numeric ordering when the visible cells include formatting.
        sort_cells: property(scalar(:cell_map))
      ).freeze

      TABLE_PROPERTIES = {
        headers: property(BOOL),
        # Stable row IDs separate viewer interaction from positional model paths.
        expanded: property(array(IDENT, max: BOUNDS[:table_rows]), scope: :viewer),
        cursor: property(record(row: property(IDENT), column: property(IDENT)), scope: :viewer),
        scrollable: property(BOOL, default: true),
        # Single-line cells retain their natural width and scroll horizontally.
        # Omission preserves existing wrapping tables, including shim consumers.
        wrap: property(BOOL),
        row_height: property(integer(min: 1, max: BOUNDS[:geometry].end)),
        border_width: property(integer(min: 0, max: 8)),
        grid_lines: property(enum(:none, :horizontal, :vertical, :both)),
        sort_mode: property(enum(:natural, :lexical, :model), default: 'natural'),
        columns: property(array(TABLE_COLUMN, min: 1, max: BOUNDS[:table_columns]), required: true),
        rows: property(array(TABLE_ROW, max: BOUNDS[:table_rows]), required: true),
        selection: property(enum(:none, :single, :browse, :multi), default: 'none'),
        selected: property(array(IDENT, max: BOUNDS[:table_rows]), scope: :viewer),
        sortable: property(BOOL, default: false),
        sort: property(record(
                         column: property(IDENT, required: true), direction: property(enum(:asc, :desc), required: true)
                       ), scope: :viewer),
        max_height: property(GEOMETRY),
        transfer_group: property(IDENT),
        search_column: property(IDENT),
        activation: property(enum(:single, :double), default: 'double'),
      }.freeze

      TABLE_EVENTS = {
        row_drop: event(record(source: property(CID, required: true), row: property(IDENT, required: true)), terminal: true),
        row_activate: event(record(row: property(IDENT, required: true), column: property(IDENT)), terminal: true),
        # Cursor and selection changes are already visible in the client. An
        # automatic refresh would invalidate the following activation (including
        # its one stale-generation retry). Callback-authored edits still refresh.
        cursor_change: event(record(row: property(IDENT, required: true), column: property(IDENT))),
        selection_change: event(record(rows: property(array(IDENT, max: BOUNDS[:table_rows]), required: true))),
        cell_edit: event(record(
                           row: property(IDENT, required: true), column: property(IDENT, required: true),
                           value: property(scalar(:editor_value), required: true)
                         )),
        row_toggle: event(record(
                            row: property(IDENT, required: true), expanded: property(BOOL, required: true)
                          ), structural: true),
        sort_change: event(record(
                             column: property(IDENT, required: true), direction: property(enum(:asc, :desc), required: true)
                           )),
      }.freeze

      RGBA = record(
        r: property(integer(min: 0, max: 255), required: true),
        g: property(integer(min: 0, max: 255), required: true),
        b: property(integer(min: 0, max: 255), required: true),
        a: property(number(min: 0.0, max: 1.0), required: true)
      ).freeze
      # Native typography uses literal text and the existing bounded color
      # shape. This does not admit Pango markup or add GTK style translation.
      TEXT_STYLE_PROPERTIES = {
        font_size: property(number(min: 6, max: 48)),
        font_unit: property(enum(:pt, :px), default: 'pt'),
        font_family: property(string(:identifier)),
        font_style: property(enum(:normal, :italic)),
        foreground: property(RGBA), background: property(RGBA),
      }.freeze
      TINT = union(record(tone: property(enum(*TONES), required: true)), RGBA).freeze
      POINT_FIELDS = {
        x: property(GEOMETRY, required: true), y: property(GEOMETRY, required: true),
      }.freeze
      COMPOSITE_LAYER = union(
        # Map's original hollow room ring and tag/location crosses. This is a
        # bounded native drawing primitive, not GTK/Cairo or executable markup.
        record({
          kind: property(enum(:marker), required: true), **POINT_FIELDS,
          shape: property(enum(:ring, :cross), required: true),
          w: property(GEOMETRY, required: true), h: property(GEOMETRY, required: true),
          line_width: property(number(min: 1, max: 16), default: 2), color: property(RGBA, required: true),
        }),
        record({
          kind: property(enum(:image), required: true), src: property(string(:body_text), required: true),
          **POINT_FIELDS, w: property(GEOMETRY), h: property(GEOMETRY),
          # Wound assets may intentionally extend beyond the silhouette edge.
          x: property(integer(min: -65_536, max: 65_536), required: true),
          y: property(integer(min: -65_536, max: 65_536), required: true),
          opacity: property(number(min: 0.0, max: 1.0), default: 1.0),
          tint: property(TINT), mask: property(string(:body_text)),
        }),
        record({
          kind: property(enum(:bar), required: true), **POINT_FIELDS,
          w: property(GEOMETRY, required: true), h: property(GEOMETRY, required: true),
          value: property(number(min: 0.0, max: 1.0), required: true),
          tone: property(union(enum(*TONES), RGBA), default: 'neutral'),
          orientation: property(enum(:horizontal, :vertical), default: 'horizontal'),
        }),
        record({
          kind: property(enum(:label), required: true), **POINT_FIELDS,
          w: property(GEOMETRY), h: property(GEOMETRY), font_unit: property(enum(:pt, :px), default: 'pt'),
          text: property(SHORT, required: true), emphasis: property(enum(*EMPHASES), default: 'normal'),
          tone: property(enum(*TONES), default: 'neutral'),
          align: property(enum(:start, :center, :end), default: 'start'),
          **TEXT_STYLE_PROPERTIES,
        }),
        record(
          kind: property(enum(:region), required: true), key: property(IDENT, required: true),
          x1: property(GEOMETRY, required: true), y1: property(GEOMETRY, required: true),
          x2: property(GEOMETRY, required: true), y2: property(GEOMETRY, required: true),
          label: property(SHORT), activates: property(BOOL, default: false)
        )
      ).freeze

      COMPOSITE_PROPERTIES = {
        width: property(GEOMETRY, required: true), height: property(GEOMETRY, required: true),
        scale: property(number(min: 0.1, max: 8.0), default: 1.0),
        scroll_to: property(IDENT, scope: :viewer),
        popup: property(record(
                          page: property(IDENT, required: true), size: property(array(GEOMETRY, min: 2, max: 2))
                        )),
        surface_events: property(BOOL, default: false),
        context_menu: property(IDENT),
        scroll_origin: property(array(GEOMETRY, min: 2, max: 2)),
        layers: property(array(COMPOSITE_LAYER, max: BOUNDS[:collection]), required: true),
      }.freeze

      COMPOSITE_EVENTS = {
        zoom: event(record(direction: property(enum(:in, :out), required: true))),
        region_activate: event(record(region: property(IDENT, required: true)), terminal: true),
        surface_activate: event(record(
                                  x: property(GEOMETRY, required: true), y: property(GEOMETRY, required: true),
                                  button: property(enum(:primary, :secondary), required: true),
                                  modifiers: property(array(enum(:ctrl, :shift, :alt), max: 3), required: true),
                                  region: property(IDENT)
                                ), terminal: true),
      }.freeze

      FACILITIES = {
        accelerators: {
          shape: array(record(
                         keys: property(SHORT, required: true), target: property(CID, required: true),
                         event: property(IDENT, required: true)
                       ), max: BOUNDS[:collection]), scope: :shared,
        },
        geometry: {
          shape: record(
            width: property(GEOMETRY), height: property(GEOMETRY),
            x: property(GEOMETRY), y: property(GEOMETRY)
          ), scope: :viewer,
        },
        notify: {
          shape: record(
            text: property(BODY, required: true), level: property(enum(:info, :warn, :error), required: true)
          ), scope: :transient,
        },
        focus: { shape: CID, scope: :viewer },
        announce: {
          shape: record(
            text: property(BODY, required: true),
            politeness: property(enum(:polite, :assertive), required: true)
          ), scope: :viewer,
        },
        presentation: {
          shape: PRESENTATION, scope: :viewer,
        },
      }.freeze

      POINTER_EVENT = event(record(
                              x: property(GEOMETRY, required: true), y: property(GEOMETRY, required: true),
                              button: property(integer(min: 1, max: 3), required: true),
                              time: property(integer(min: 0), required: true),
                              state: property(integer(min: 0, max: 13), required: true)
                            ), lifecycle: true).freeze

      PAGE_LIFECYCLE_EVENTS = {
        pointer_press: POINTER_EVENT,
        # Measured host geometry is notification data, not a form submission.
        configure: event(record(
                           width: property(integer(min: 0, max: 65_536), required: true),
                           height: property(integer(min: 0, max: 65_536), required: true),
                           position: property(array(integer(min: -65_536, max: 65_536), min: 2, max: 2), required: true)
                         )),
        close: event(record(reason: property(enum(:user, :owner, :timeout), required: true)), terminal: true, lifecycle: true),
        attach: event(nil, lifecycle: true),
        detach: event(nil, lifecycle: true),
      }.freeze

      # Assembles and recursively freezes the bounded control/facility contract once.
      # Shared property families are added here so native and shim consumers agree.
      # @return [Hash] cached schemas keyed by type
      def schemas
        @schemas ||= begin
          schemas = {}
          TYPES.each do |type|
            base = deep_dup(BASE_SCHEMAS.fetch(type))
            base[:events].merge!(deep_dup(PAGE_LIFECYCLE_EVENTS)) if type == :page
            base[:properties].merge!(TABLE_PROPERTIES) if type == :table
            base[:events].merge!(TABLE_EVENTS) if type == :table
            ATTRIBUTE_APPLICABILITY.fetch(type).each do |attribute|
              next if base[:properties].key?(attribute)

              base[:properties][attribute] = deep_dup(ATTRIBUTE_SCHEMAS.fetch(attribute))
            end
            if %i[page text image group].include?(type)
              base[:properties][:pointer_events] = property(BOOL, default: false)
              base[:events][:pointer_press] = deep_dup(POINTER_EVENT)
            end
            if type == :group
              base[:events][:dismiss] = event(nil, lifecycle: true)
            end
            # A layout request is a minimum, not a fixed allocation. Native
            # conversions opt in without changing existing width semantics.
            base[:properties][:min_width] = property(integer(min: 0, max: 65_536)) if ATTRIBUTE_APPLICABILITY.fetch(type).include?(:width)
            base[:properties].merge!(COMPOSITE_PROPERTIES) if type == :composite
            # Grid-child allocation is distinct from text alignment. Single-child
            # frames use their existing content_align property instead.
            base[:properties][:vertical_align] = property(enum(:start, :center, :end, :stretch)) unless type == :page
            if type == :text
              base[:properties].merge!(TEXT_STYLE_PROPERTIES)
              base[:properties].merge!(padding_x: property(integer(min: 0, max: 64)), padding_y: property(integer(min: 0, max: 64)),
                                       content_vertical_align: property(enum(:start, :center, :end)),
                                       rotation: property(enum(0, 90, 180, 270)))
            end
            base[:properties][:fill] = property(BOOL, default: false) if %i[stack columns table split group].include?(type)
            if type == :group
              base[:properties].merge!(padding: property(integer(min: 0, max: 64)),
                                       border_width: property(integer(min: 0, max: 8)), radius: property(integer(min: 0, max: 32)),
                                       content_align: property(enum(:start, :center, :end)),
                                       border_color: property(RGBA), background: property(RGBA),
                                       surface_events: property(BOOL, default: false), context_menu: property(IDENT))
              base[:events][:surface_activate] = COMPOSITE_EVENTS.fetch(:surface_activate)
            end
            if %i[text text_input select].include?(type)
              base[:properties][:min_width_chars] = property(integer(min: 1, max: 1024))
            end
            if %i[text_input select].include?(type)
              base[:properties][:max_width_chars] = property(integer(min: 1, max: 1024))
            end
            if %i[text_input select].include?(type)
              base[:properties][:control_width_chars] = property(integer(min: 1, max: 1024))
            end
            if %i[text_input number_input select].include?(type)
              base[:properties].merge!(inline: property(BOOL, default: false),
                                       control_width: property(integer(min: 1, max: 1024)))
            end
            base[:properties][:fill_color] = property(RGBA) if type == :progress
            base[:events].merge!(COMPOSITE_EVENTS) if type == :composite
            base[:properties].merge!(deep_dup(ACCESSIBILITY_SCHEMAS))
            if type == :password_input
              base[:properties][:sensitive][:forced] = true
              base[:properties][:sensitive][:default] = true
            end
            schemas[type] = base
          end
          deep_freeze(schemas)
        end
      end

      # Looks up a supported type after identifier normalization.
      # @return [Hash] frozen schema
      # @raise [UnknownTypeError] if the type is outside the contract
      def schema(type)
        normalized = normalize_type(type)
        schemas.fetch(normalized)
      rescue KeyError
        raise UnknownTypeError, "unknown component type #{type.inspect}"
      end

      # Converts identifier-shaped strings to symbols; leaves other inputs for rejection.
      # @return [Object] normalized candidate type
      def normalize_type(type)
        return type if type.is_a?(Symbol)
        return type.to_sym if type.is_a?(String) && type.match?(IDENTIFIER)

        type
      end

      # Preserve a literal string while dividing it across bounded wire fields.
      # The receiver still owns the collection bound and presentation policy.
      def fragment_text(value, bound:)
        limit = BOUNDS.fetch(bound)
        value.length <= limit ? value : value.scan(/.{1,#{limit}}/m)
      end

      # Accepts the current major protocol version and returns the server version.
      # Minor version differences do not prevent attachment.
      # @return [String] server contract version
      # @raise [VersionError] for malformed or incompatible major versions
      def negotiate!(client_version)
        version = client_version.to_s
        major = Integer(version.split('.').first, exception: false)
        raise VersionError, "invalid contract version #{client_version.inspect}" unless major
        raise VersionError, "unsupported contract major #{major}; server requires #{MAJOR_VERSION}" unless major == MAJOR_VERSION

        VERSION
      end

      # Recursively freezes schema hashes, arrays, keys, and leaf values.
      # @return [Object] the supplied object
      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end

      # Copies hash/array containers recursively, retaining scalar objects.
      # This is a schema composition helper, not a general mutable deep copy.
      # @return [Object] copied container or original scalar
      def deep_dup(value)
        case value
        when Hash
          value.to_h { |key, child| [key, deep_dup(child)] }
        when Array
          value.map { |child| deep_dup(child) }
        else
          value
        end
      end
    end
  end
end
