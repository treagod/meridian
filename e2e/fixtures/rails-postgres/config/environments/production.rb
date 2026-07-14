Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  # The recipe serves precompiled assets from the app container itself.
  config.public_file_server.enabled = true

  # TLS terminates at kamal-proxy; the app listens on plain HTTP.
  config.assume_ssl = false
  config.force_ssl = false

  config.logger = ActiveSupport::Logger.new($stdout)
  config.log_level = :info

  config.secret_key_base = ENV.fetch("MY_APP_SECRET_KEY_BASE")

  config.active_record.dump_schema_after_migration = false
end
