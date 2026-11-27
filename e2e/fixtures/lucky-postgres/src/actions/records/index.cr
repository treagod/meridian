# Database-backed endpoint for the recipe E2E: `?value=` inserts a row, and
# every request lists all stored values.
class Records::Index < BrowserAction
  include Auth::AllowGuests

  get "/records" do
    if value = params.get?(:value)
      RecipeRecord::SaveOperation.create!(value: value)
    end

    plain_text RecipeRecordQuery.new.id.asc_order.map(&.value).join("\n")
  end
end
