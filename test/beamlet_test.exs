defmodule BeamletTest do
  use Beamlet.Case

  test "runs as a supervisor under the host's tree", %{data_dir: data_dir} do
    assert Process.whereis(Beamlet) != nil
    assert File.dir?(data_dir)
  end

  test "opens both databases under the data dir's db directory" do
    assert %{rows: [[1]]} = Beamlet.Repo.query!("select 1")
    assert %{rows: [[1]]} = Host.Repo.query!("select 1")

    db_dir = Beamlet.Config.db_dir()
    assert File.exists?(Path.join(db_dir, "beamlet.db"))
    assert File.exists?(Path.join(db_dir, "agent.db"))
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
