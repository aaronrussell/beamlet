defmodule Host.KVTest do
  # Host.Repo's sandbox connection is shared with eval's task, so
  # nothing here can run async.
  use Beamlet.Case, async: false

  alias Beamlet.Eval

  describe "fetch, get, put and delete" do
    test "a nested term round-trips" do
      value = %{"n" => {1, 2.5, nil}, count: 3, tags: [:a, :b]}

      assert Host.KV.put("kv-test:term", value) == :ok
      assert Host.KV.get("kv-test:term") == value
      assert Host.KV.fetch("kv-test:term") == {:ok, value}
    end

    test "get returns the default on a miss" do
      assert Host.KV.get("kv-test:nope") == nil
      assert Host.KV.get("kv-test:nope", 0) == 0
    end

    test "fetch tells a stored nil from a missing key" do
      assert Host.KV.fetch("kv-test:nil") == :error

      :ok = Host.KV.put("kv-test:nil", nil)
      assert Host.KV.fetch("kv-test:nil") == {:ok, nil}
      assert Host.KV.get("kv-test:nil", :default) == nil
    end

    test "put overwrites" do
      :ok = Host.KV.put("kv-test:cursor", 1)
      :ok = Host.KV.put("kv-test:cursor", 2)

      assert Host.KV.get("kv-test:cursor") == 2
      assert Host.KV.keys("kv-test:") == ["kv-test:cursor"]
    end

    test "delete is idempotent" do
      assert Host.KV.delete("kv-test:missing") == :ok

      :ok = Host.KV.put("kv-test:gone", :soon)
      assert Host.KV.delete("kv-test:gone") == :ok
      assert Host.KV.fetch("kv-test:gone") == :error
      assert Host.KV.delete("kv-test:gone") == :ok
    end

    test "keys must be strings" do
      key = Enum.random([:atom])

      assert_raise FunctionClauseError, fn -> Host.KV.put(key, 1) end
      assert_raise FunctionClauseError, fn -> Host.KV.get(key) end
      assert_raise FunctionClauseError, fn -> Host.KV.fetch(key) end
    end
  end

  describe "prefixes" do
    setup do
      :ok = Host.KV.put("kv-test:a:1", 1)
      :ok = Host.KV.put("kv-test:a:2", 2)
      :ok = Host.KV.put("kv-test:b:1", 3)
      :ok
    end

    test "all and keys select under a prefix" do
      assert Host.KV.keys("kv-test:a:") == ["kv-test:a:1", "kv-test:a:2"]
      assert Host.KV.all("kv-test:a:") == %{"kv-test:a:1" => 1, "kv-test:a:2" => 2}
    end

    test "an empty prefix is everything" do
      assert Host.KV.keys("") == ["kv-test:a:1", "kv-test:a:2", "kv-test:b:1"]
      assert Host.KV.keys() == Host.KV.keys("")
      assert map_size(Host.KV.all("")) == 3
      assert Host.KV.all() == Host.KV.all("")
    end

    test "keys are sorted in byte order" do
      :ok = Host.KV.put("kv-test:B", 0)

      assert Host.KV.keys("kv-test:") ==
               ["kv-test:B", "kv-test:a:1", "kv-test:a:2", "kv-test:b:1"]
    end

    test "wildcard characters in a prefix match literally" do
      :ok = Host.KV.put("kv-test:*:x", 0)
      :ok = Host.KV.put("kv-test:?:x", 0)
      :ok = Host.KV.put("kv-test:[:x", 0)

      assert Host.KV.keys("kv-test:*") == ["kv-test:*:x"]
      assert Host.KV.keys("kv-test:?") == ["kv-test:?:x"]
      assert Host.KV.keys("kv-test:[") == ["kv-test:[:x"]
    end

    test "delete_all removes only the prefix" do
      assert Host.KV.delete_all("kv-test:a:") == :ok
      assert Host.KV.keys("kv-test:") == ["kv-test:b:1"]
    end

    test "delete_all with an empty prefix removes every key" do
      assert Host.KV.delete_all("") == :ok
      assert Host.KV.keys() == []
    end
  end

  describe "the agent database" do
    test "a put inside a Host.Repo.transaction rolls back with it" do
      assert_raise RuntimeError, "boom", fn ->
        Host.Repo.transaction(fn ->
          Host.KV.put("kv-test:tx", 1)
          raise "boom"
        end)
      end

      assert Host.KV.fetch("kv-test:tx") == :error
    end

    test "the table is in the agent database, not the system database" do
      sql = "select name from sqlite_master where name = '__kv'"

      assert Host.Repo.query!(sql).rows == [["__kv"]]
      assert Beamlet.Repo.query!(sql).rows == []
    end

    test "upgrading the furniture at the current version is a no-op" do
      assert Beamlet.Tables.upgrade() == :ignore
      assert Beamlet.Tables.upgrade() == :ignore

      :ok = Host.KV.put("kv-test:after-boot", :ok)
      assert Host.KV.get("kv-test:after-boot") == :ok
    end
  end

  describe "through eval" do
    test "agent code puts and gets", %{token: token} do
      code = ~s|Host.KV.put("kv-test:eval", %{n: 1})\nHost.KV.get("kv-test:eval")|
      assert {:ok, "=> %{n: 1}"} = Eval.run(code, principal(token))
    end
  end
end
