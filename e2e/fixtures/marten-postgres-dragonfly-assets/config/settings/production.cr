Marten.configure :production do |config|
  config.debug = false
  config.host = "0.0.0.0"
  config.port = 8000

  config.secret_key = ENV.fetch("MARTEN_SECRET_KEY")
  config.allowed_hosts = ENV.fetch("MARTEN_ALLOWED_HOSTS")
    .split(",")
    .map(&.strip)
    .reject(&.empty?)

  config.assets.url = "http://e2e-pg-assets.test/"
  config.assets.manifests = ["src/manifest.json"]

  config.templates.cached = true
  config.use_x_forwarded_host = true
  config.use_x_forwarded_port = true
  config.use_x_forwarded_proto = true
end
