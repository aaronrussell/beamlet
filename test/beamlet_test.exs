defmodule BeamletTest do
  use Beamlet.Case

  test "creates both database files in WAL mode at boot" do
    db_dir = Beamlet.Config.db_dir()
    assert File.exists?(Path.join(db_dir, "beamlet.db"))
    assert File.exists?(Path.join(db_dir, "agent.db"))

    assert %{rows: [["wal"]]} = Beamlet.Repo.query!("pragma journal_mode")
    assert %{rows: [["wal"]]} = Host.Repo.query!("pragma journal_mode")
  end

  test "creates the key/value table in the agent database at boot, and only that" do
    %{rows: rows} =
      Host.Repo.query!(
        "select name from sqlite_master where type = 'table' and name not like 'schema_%'"
      )

    assert List.flatten(rows) == ["__kv"]
    assert :ok = Host.KV.put("beamlet-test:boot", 1)
    assert Host.KV.get("beamlet-test:boot") == 1
  end

  test "keeps the routes in the beamlet's database" do
    %{rows: rows} =
      Beamlet.Repo.query!("select name from sqlite_master where type = 'table' order by name")

    assert "routes" in List.flatten(rows)
  end
end

defmodule BeamletNotStartedTest do
  use ExUnit.Case

  test "is not started as an application" do
    assert Application.spec(:beamlet, :mod) in [nil, []]
  end
end

defmodule BeamletSystemOnlyTest do
  use ExUnit.Case

  test "only: :system starts the policies and the beamlet's database, nothing else" do
    agent_db = Beamlet.Config.agent_db_file()
    File.rm_rf!(Beamlet.Config.files_dir())
    for file <- [agent_db, agent_db <> "-wal", agent_db <> "-shm"], do: File.rm(file)

    start_supervised!({Beamlet, only: :system})

    assert Process.whereis(Beamlet.Policies)
    assert Process.whereis(Beamlet.Repo)
    refute Process.whereis(Host.Repo)
    refute Process.whereis(Beamlet.MCP.Server)

    assert File.exists?(Beamlet.Config.beamlet_db_file())
    refute File.exists?(agent_db)
    refute File.exists?(Beamlet.Config.files_dir())
  end

  @tag :capture_log
  test "another only: value fails to start" do
    assert {:error, {{%ArgumentError{message: message}, _stack}, _spec}} =
             start_supervised({Beamlet, only: :web})

    assert message =~ "Beamlet.start_link only: accepts :system, got: :web"
  end
end
