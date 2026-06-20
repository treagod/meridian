class HealthHandler < Marten::Handler
  def get
    RecipeRecord.all.count
    respond("ok", content_type: "text/plain")
  end
end
