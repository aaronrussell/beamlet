defmodule Host.PubSubTest do
  use Beamlet.Case, async: false

  alias Beamlet.Policy
  alias Beamlet.Scanner

  defp topic, do: "pubsub-test:#{System.unique_integer([:positive])}"

  describe "Host.PubSub" do
    test "subscribe then broadcast delivers to the subscriber" do
      topic = topic()

      assert Host.PubSub.subscribe(topic) == :ok
      assert Host.PubSub.broadcast(topic, {:note_saved, 1}) == :ok

      assert_receive {:note_saved, 1}
    end

    test "unsubscribe stops delivery" do
      topic = topic()

      assert Host.PubSub.subscribe(topic) == :ok
      assert Host.PubSub.unsubscribe(topic) == :ok
      assert Host.PubSub.broadcast(topic, :gone) == :ok

      refute_receive :gone, 50
    end

    test "broadcast with no subscribers returns :ok" do
      assert Host.PubSub.broadcast(topic(), :nobody_home) == :ok
    end

    test "the bus is registered as Beamlet.PubSub" do
      assert is_pid(Process.whereis(Beamlet.PubSub))
    end
  end

  describe "the policy" do
    defp scan(code), do: Scanner.scan_eval(code, Policy.default())

    test "Host.PubSub passes the scan" do
      assert :ok = scan(~s|Host.PubSub.subscribe("notes:updated")|)
      assert :ok = scan(~s|Host.PubSub.broadcast("notes:updated", {:note_saved, 1})|)
    end

    test "a direct Phoenix.PubSub call is redirected to the stdlib" do
      assert {:error, message} = scan(~s|Phoenix.PubSub.subscribe(Beamlet.PubSub, "t")|)

      assert message =~ "Phoenix.PubSub.subscribe/2 — Phoenix.PubSub is not permitted"
      assert message =~ "publish/subscribe goes through Host.PubSub"
    end
  end
end
