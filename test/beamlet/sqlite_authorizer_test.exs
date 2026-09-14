defmodule Beamlet.SQLiteAuthorizerTest do
  use Beamlet.Case

  test "ATTACH DATABASE is refused on the agent database" do
    system_db = Beamlet.Repo.config()[:database]

    assert {:error, %Exqlite.Error{message: "not authorized"}} =
             Host.Repo.query("attach database ? as system", [system_db])
  end

  test "the system database is not restricted" do
    agent_db = Host.Repo.config()[:database]

    assert {:ok, _} = Beamlet.Repo.query("attach database ? as agent", [agent_db])
  end
end
