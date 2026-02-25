defmodule Baudrate.Repo.Migrations.AddApAcceptPolicyToBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :ap_accept_policy, :string, default: "followers_only", null: false
    end
  end
end
