defmodule BeamletTest do
  use Beamlet.Case

  test "runs as a supervisor under the host's tree", %{data_dir: data_dir} do
    assert Process.whereis(Beamlet) != nil
    assert File.dir?(data_dir)
  end

  test "opens both databases" do
    assert %{rows: [[1]]} = Beamlet.Repo.query!("select 1")
    assert %{rows: [[1]]} = Host.Repo.query!("select 1")
  end

  test "creates both database files in WAL mode at boot" do
    db_dir = Beamlet.Config.db_dir()
    assert File.exists?(Path.join(db_dir, "beamlet.db"))
    assert File.exists?(Path.join(db_dir, "agent.db"))

    assert %{rows: [["wal"]]} = Beamlet.Repo.query!("pragma journal_mode")
    assert %{rows: [["wal"]]} = Host.Repo.query!("pragma journal_mode")
  end

  test "creates its own tables in the agent database at boot" do
    assert furniture() == ["__kv", "__routes"]
    assert Beamlet.Tables.version() == Beamlet.Tables.current_version()
  end

  test "upgrades an agent database at furniture version zero to the current one" do
    Host.Repo.query!("drop table __routes")
    Host.Repo.query!("drop table __kv")
    Host.Repo.query!("pragma user_version = 0")
    assert furniture() == []

    assert Beamlet.Tables.upgrade() == :ignore

    assert Beamlet.Tables.version() == Beamlet.Tables.current_version()
    assert furniture() == ["__kv", "__routes"]
    assert :ok = Host.KV.put("beamlet-test:after-upgrade", 1)
  end

  test "refuses an agent database written by a newer Beamlet" do
    Host.Repo.query!("pragma user_version = #{Beamlet.Tables.current_version() + 1}")

    assert_raise RuntimeError, ~r/newer Beamlet/, fn -> Beamlet.Tables.upgrade() end
  end

  defp furniture do
    %{rows: rows} =
      Host.Repo.query!(
        "select name from sqlite_master where name like '\\_\\_%' escape '\\' order by name"
      )

    List.flatten(rows)
  end

  test "serves the routes through the host's endpoint" do
    assert Process.whereis(Beamlet.TestEndpoint)
    assert Beamlet.Config.web()[:endpoint] == Beamlet.TestEndpoint
  end

  test "migrates the system database at boot" do
    assert %{rows: [["schema_migrations"]]} =
             Beamlet.Repo.query!(
               "select name from sqlite_master where name = 'schema_migrations'"
             )
  end
end

defmodule BeamletNotStartedTest do
  use ExUnit.Case

  test "is not started as an application" do
    assert Process.whereis(Beamlet) == nil
    assert Application.spec(:beamlet, :mod) in [nil, []]
  end
end

defmodule BeamletSystemOnlyTest do
  use ExUnit.Case

  test "only: :system starts the policies and the system database, nothing else" do
    start_supervised!({Beamlet, only: :system})

    assert Process.whereis(Beamlet.Policies)
    assert Process.whereis(Beamlet.Repo)
    refute Process.whereis(Host.Repo)
    refute Process.whereis(Beamlet.MCP.Server)
  end

  @tag :capture_log
  test "another only: value fails to start" do
    assert {:error, {{%ArgumentError{message: message}, _stack}, _spec}} =
             start_supervised({Beamlet, only: :web})

    assert message =~ "Beamlet.start_link only: accepts :system, got: :web"
  end
end
