class CreateRecipeRecords::V20260101000000 < Avram::Migrator::Migration::V1
  def migrate
    create table_for(RecipeRecord) do
      primary_key id : Int64
      add_timestamps
      add value : String
    end
  end

  def rollback
    drop table_for(RecipeRecord)
  end
end
