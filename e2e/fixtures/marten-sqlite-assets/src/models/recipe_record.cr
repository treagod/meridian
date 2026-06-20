class RecipeRecord < Marten::Model
  field :id, :big_int, primary_key: true, auto: true
  field :value, :string, max_size: 160
end
