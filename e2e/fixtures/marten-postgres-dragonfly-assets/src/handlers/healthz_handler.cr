class HealthzHandler < Marten::Handler
  def get
    respond("ok", content_type: "text/plain")
  end
end
