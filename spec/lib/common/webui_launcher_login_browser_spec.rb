# frozen_string_literal: true

# Throwaway testbed case: a browser example at a path the classifier does not list.
RSpec.describe 'an unlisted browser spec', if: ENV['NATIVE_BROWSER'] do
  it 'is never selected' do
    expect(true).to be(true)
  end
end
