class CreateRecipeRecords < ActiveRecord::Migration[8.0]
  def change
    create_table :recipe_records do |t|
      t.string :value, null: false

      t.timestamps
    end
  end
end
