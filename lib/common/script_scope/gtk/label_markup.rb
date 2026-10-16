# frozen_string_literal: true

module Lich
  module Common
    module ScriptScope
      module Gtk
        # Parses measured inline label markup into bounded literal fragments.
        # No source tag, attribute or CSS is sent to the browser.
        class LabelMarkup
          def initialize(label)
            @label = label
            @fragments = []
          end

          # @return [Array<Hash>] validated text fragments in source order
          def parse(source)
            refuse if source.include?('<!') || source.include?('<?')
            document = REXML::Document.new("<label>#{source}</label>")
            walk(document.root, {}, 0)
            @fragments
          rescue REXML::ParseException
            refuse
          end

          private

          def refuse
            @label.session.refuse(@label, :set_markup)
          end

          def walk(element, inherited, depth)
            refuse if depth > 16
            element.children.each do |child|
              if child.is_a?(REXML::Text)
                # Match the existing wire-field bound even for a long literal run.
                child.value.chars.each_slice(Lich::WebUI::Contract::BOUNDS[:body_text]) do |characters|
                  refuse if @fragments.size >= Lich::WebUI::Contract::BOUNDS[:collection]
                  @fragments << { content: characters.join, **inherited }
                end
              elsif child.is_a?(REXML::Element)
                walk(child, style(child, inherited), depth + 1)
              else
                refuse
              end
            end
          end

          def style(element, inherited)
            attributes = element.attributes.to_h.transform_values(&:value)
            case element.expanded_name
            when 'b', 'i', 'small', 'big'
              refuse unless attributes.empty?
              case element.name
              when 'b' then inherited.merge(emphasis: :strong)
              when 'i' then inherited.merge(font_style: :italic)
              else
                scale = inherited.fetch(:scale, 1.0) * (element.name == 'small' ? 1 / 1.2 : 1.2)
                refuse unless scale.between?(0.5, 2)
                inherited.merge(scale: scale)
              end
            when 'span'
              refuse if attributes.empty? || (attributes.keys - %w[foreground weight size]).any?
              result = inherited.dup
              if attributes['size']
                sizes = %w[xx-small x-small small medium large x-large xx-large]
                index = sizes.index(attributes['size'])
                refuse unless index
                scale = inherited.fetch(:scale, 1.0) * (1.2**(index - 3))
                refuse unless scale.between?(0.5, 2)
                result[:scale] = scale
              end
              if attributes['foreground']
                color = Color.parse(attributes['foreground'])
                refuse unless color
                result[:foreground] = color
              end
              if attributes['weight']
                refuse unless %w[normal bold].include?(attributes['weight'])
                result[:emphasis] = attributes['weight'] == 'bold' ? :strong : :normal
              end
              result
            else
              refuse
            end
          end
        end
        private_constant :LabelMarkup
      end
    end
  end
end
