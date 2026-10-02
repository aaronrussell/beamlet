defmodule Host.RepoTest do
  use Beamlet.Case, shared: true

  test "ATTACH DATABASE is refused on the agent database" do
    system_db = Beamlet.Repo.config()[:database]

    assert {:error, %Exqlite.Error{message: "not authorized"}} =
             Host.Repo.query("attach database ? as system", [system_db])
  end

  @tag :tmp_dir
  test "VACUUM INTO is refused on the agent database", ctx do
    copy = Path.join(ctx.tmp_dir, "copy.db")

    # VACUUM cannot run inside the sandbox's transaction.
    assert {:error, %Exqlite.Error{message: "authorization denied"}} =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Host.Repo, fn ->
               Host.Repo.query("vacuum into ?", [copy])
             end)

    refute File.exists?(copy)
  end

  test "the system database is not restricted" do
    agent_db = Host.Repo.config()[:database]

    assert {:ok, _} = Beamlet.Repo.query("attach database ? as agent", [agent_db])
  end
end
