defmodule Host.KVTest do
  # Host.Repo's sandbox connection is shared with eval's task, so
  # nothing here can run async.
  use Beamlet.Case, async: false

  alias Beamlet.Eval

  describe "fetch, get, put and delete" do
    test "a nested JSON value round-trips" do
      value = %{
        "n" => [1, 2.5, nil, true, false],
        "big" => 12_345_678_901_234_567_890,
        "name" => "Zoë",
        "nested" => %{"tags" => ["a", "b"], "empty" => %{}}
      }

      assert Host.KV.put("kv-test:value", value) == :ok
      assert Host.KV.get("kv-test:value") == value
      assert Host.KV.fetch("kv-test:value") == {:ok, value}
      assert Host.KV.all("kv-test:") == %{"kv-test:value" => value}
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

      :ok = Host.KV.put("kv-test:gone", "soon")
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

  describe "values are JSON" do
    test "an atom value is refused" do
      assert_raise ArgumentError, ~r/does not store the atom :active: .*e\.g\. "active"/, fn ->
        Host.KV.put("kv-test:bad", :active)
      end

      assert Host.KV.fetch("kv-test:bad") == :error
    end

    test "an atom key is refused" do
      assert_raise ArgumentError, ~r/does not store the map key :count: .*map keys must be/, fn ->
        Host.KV.put("kv-test:bad", %{count: 1})
      end

      assert Host.KV.fetch("kv-test:bad") == :error
    end

    test "a struct is refused by name" do
      assert_raise ArgumentError, ~r/does not store a %DateTime\{\} struct: .*to_iso8601/, fn ->
        Host.KV.put("kv-test:bad", DateTime.utc_now())
      end

      assert Host.KV.fetch("kv-test:bad") == :error
    end

    test "tuples, funs, pids, improper lists and non-UTF-8 binaries are refused" do
      for {value, message} <- [
            {{1, 2}, ~r/the tuple \{1, 2\}: .*store a list instead/},
            {&String.upcase/1, ~r/&String\.upcase\/1: .*funs, pids/},
            {self(), ~r/#PID<.*funs, pids/},
            {[1 | 2], ~r/an improper list: .*end the list with \[\]/},
            {<<255>>, ~r/not UTF-8 text: .*Base\.encode64/},
            {%{<<255>> => 1}, ~r/the map key <<255>>: .*map keys must be UTF-8 strings/}
          ] do
        assert_raise ArgumentError, message, fn -> Host.KV.put("kv-test:bad", value) end
      end

      assert Host.KV.fetch("kv-test:bad") == :error
    end

    test "a refusal inside a value names where it sits" do
      value = %{"items" => [%{"status" => "ok"}, %{"status" => :active}]}

      assert_raise ArgumentError, ~r/the atom :active at \["items", 1, "status"\]: /, fn ->
        Host.KV.put("kv-test:bad", value)
      end
    end

    test "a refused put leaves the stored value in place" do
      :ok = Host.KV.put("kv-test:kept", 1)

      assert_raise ArgumentError, fn -> Host.KV.put("kv-test:kept", :two) end
      assert Host.KV.get("kv-test:kept") == 1
    end
  end

  describe "rows written outside Host.KV" do
    defp insert_raw(key, value) do
      Host.Repo.query!("INSERT INTO __kv (key, value) VALUES (?, ?)", [key, value])
    end

    test "valid JSON text reads back as its value" do
      insert_raw("kv-test:raw", ~s|{"a": [1, null]}|)

      assert Host.KV.get("kv-test:raw") == %{"a" => [1, nil]}
    end

    test "a value that is not JSON raises naming the key, and stays removable" do
      insert_raw("kv-test:raw", "not json")
      message = ~r/the value under "kv-test:raw" is not JSON: .*Host\.KV\.delete\("kv-test:raw"\)/

      assert_raise RuntimeError, message, fn -> Host.KV.get("kv-test:raw") end
      assert_raise RuntimeError, message, fn -> Host.KV.fetch("kv-test:raw") end
      assert_raise RuntimeError, message, fn -> Host.KV.all("kv-test:") end

      assert Host.KV.keys("kv-test:") == ["kv-test:raw"]
      assert Host.KV.delete("kv-test:raw") == :ok
      assert Host.KV.all("kv-test:") == %{}
    end

    test "external term format bytes for a fun do not decode" do
      module = "Elixir.Beamlet.Tokens"
      bytes = <<131, 113, 119, byte_size(module), module::binary, 119, 4, "list", 97, 0>>
      insert_raw("kv-test:fun", bytes)

      assert_raise RuntimeError, ~r/"kv-test:fun" is not JSON/, fn ->
        Host.KV.get("kv-test:fun")
      end
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

      :ok = Host.KV.put("kv-test:after-boot", "ok")
      assert Host.KV.get("kv-test:after-boot") == "ok"
    end
  end

  describe "through eval" do
    test "agent code puts and gets", %{token: token} do
      code = ~s|Host.KV.put("kv-test:eval", %{"n" => 1})\nHost.KV.get("kv-test:eval")|
      assert {:ok, ~s|=> %{"n" => 1}|} = Eval.run(code, principal(token))
    end

    test "agent code putting an atom key is taught string keys", %{token: token} do
      code = ~s|Host.KV.put("kv-test:eval", %{n: 1})|
      assert {:error, message} = Eval.run(code, principal(token))
      assert message =~ ~s|map keys must be UTF-8 strings, e.g. %{"count" => 1}|
    end
  end
end
