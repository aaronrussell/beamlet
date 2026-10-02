defmodule Host.PubSubTest do
  use Beamlet.Case, shared: true

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

      refute_received :gone
    end

    test "broadcast with no subscribers returns :ok" do
      assert Host.PubSub.broadcast(topic(), :nobody_home) == :ok
    end

    test "the bus is registered as Beamlet.PubSub" do
      assert is_pid(Process.whereis(Beamlet.PubSub))
    end
  end
end
