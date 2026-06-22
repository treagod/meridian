class Migration::Main::V202606170000000 < Marten::Migration
  def plan
    create_table :main_recipe_record do
      column :id, :big_int, primary_key: true, auto: true
      column :value, :string, max_size: 160
    end
  end
end
