class DragonflyHandler < Marten::Handler
  KEY = "meridian:e2e:dragonfly"

  def get
    client = DragonflyClient.new(ENV.fetch("MY_APP_DRAGONFLY_URL"))

    if value = request.query_params["value"]?
      client.set(KEY, value)
    end

    respond(client.get(KEY), content_type: "text/plain")
  end
end
