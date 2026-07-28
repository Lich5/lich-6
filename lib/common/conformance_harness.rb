# frozen_string_literal: true

module Lich
  module Common
    # Contract-only harness for future GTK-to-WebUI conformance tests.
    #
    # +script_id+ is a non-empty target script identifier. +trace+ is an Array
    # of recorded GTK call Hashes. Results always have +script_id+ and a binary
    # +verdict+ (pass or fail). A failure additionally has
    # +failure_category+; successful results cannot carry a category.
    class ConformanceHarness
      FAILURE_CATEGORIES = %w[security_refusal behavioural_failure].freeze

      def evaluate(script_id:, trace:, failure_category: nil)
        raise ArgumentError, 'script_id must be a non-empty String' unless script_id.is_a?(String) && !script_id.empty?
        raise ArgumentError, 'trace must be an Array' unless trace.is_a?(Array)
        raise ArgumentError, 'every trace call must be a Hash' unless trace.all? { |call| call.is_a?(Hash) }
        unless failure_category.nil? || FAILURE_CATEGORIES.include?(failure_category)
          raise ArgumentError, "failure_category must be one of #{FAILURE_CATEGORIES.join(', ')}"
        end

        return { 'script_id' => script_id, 'verdict' => 'pass' } if failure_category.nil?

        { 'script_id' => script_id, 'verdict' => 'fail', 'failure_category' => failure_category }
      end
    end
  end
end
