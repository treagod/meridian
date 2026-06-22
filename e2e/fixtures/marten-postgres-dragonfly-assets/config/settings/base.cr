Marten.configure do |config|
  config.installed_apps = [] of Marten::Apps::Config.class

  config.database do |db|
    db.backend = :postgresql
    db.host = ENV.fetch("MY_APP_DATABASE_HOST", "localhost")
    db.name = ENV.fetch("MY_APP_DATABASE_NAME", "meridian_e2e")
    db.user = ENV.fetch("MY_APP_DATABASE_USER", "meridian_e2e")
    db.password = ENV.fetch("MY_APP_DATABASE_PASSWORD", "")
  end

  config.templates.context_producers = [
    Marten::Template::ContextProducer::Request,
  ]
end
