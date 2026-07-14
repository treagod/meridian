class RecordsController < ApplicationController
  def index
    RecipeRecord.create!(value: params[:value]) if params[:value].present?

    render plain: RecipeRecord.order(:id).pluck(:value).join("\n")
  end
end
