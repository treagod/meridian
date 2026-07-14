require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

module MeridianE2eRails
  class Application < Rails::Application
    config.load_defaults 8.0
  end
end
