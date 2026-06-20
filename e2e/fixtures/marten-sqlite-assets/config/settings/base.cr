Marten.configure do |config|
  config.installed_apps = [] of Marten::Apps::Config.class

  config.database do |db|
    db.backend = :sqlite
    db.name = Path["/app/data/meridian-e2e.db"]
  end

  config.templates.context_producers = [
    Marten::Template::ContextProducer::Request,
  ]
end
