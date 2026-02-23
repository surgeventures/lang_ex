defmodule IncidentResponder.Repo.Migrations.AddLangEx do
  use Ecto.Migration

  def up, do: LangEx.Migration.up()
  def down, do: LangEx.Migration.down()
end
