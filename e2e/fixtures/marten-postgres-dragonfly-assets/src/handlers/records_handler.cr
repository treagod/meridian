class RecordsHandler < Marten::Handler
  def get
    if value = request.query_params["value"]?
      RecipeRecord.create!(value: value)
    end

    body = RecipeRecord.all.order("id").to_a.map(&.value).join('\n')
    respond(body, content_type: "text/plain")
  end
end
