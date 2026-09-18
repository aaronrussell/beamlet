defmodule Host.PubSub do
  @moduledoc """
  Publish/subscribe on your beamlet's shared message bus.

  A process subscribes to a topic string, and every message
  broadcast on that topic is delivered to it as an ordinary process
  message. A LiveView subscribes in `mount/3` and handles the message in
  `handle_info/2`; a controller action broadcasts:

      def mount(_params, _session, socket) do
        if connected?(socket), do: Host.PubSub.subscribe("notes:updated")
        {:ok, assign(socket, notes: Notes.all())}
      end

      def handle_info({:note_saved, note}, socket) do
        {:noreply, update(socket, :notes, &[note | &1])}
      end

      def create(conn, params) do
        note = Notes.save(params)
        Host.PubSub.broadcast("notes:updated", {:note_saved, note})
        json(conn, %{ok: true})
      end

  Topics are one shared namespace across every agent and module on
  your beamlet, so prefix them with your domain, e.g. `"notes:updated"`.
  Subscriptions belong to the calling process and end with it.
  """

  @server Beamlet.PubSub

  @doc """
  Subscribes the calling process to `topic`, e.g.
  `subscribe("notes:updated")`. Messages broadcast on the topic
  arrive as process messages, `handle_info/2` in a LiveView.
  """
  @spec subscribe(String.t()) :: :ok
  def subscribe(topic) when is_binary(topic) do
    case Phoenix.PubSub.subscribe(@server, topic) do
      :ok -> :ok
      {:error, reason} -> raise "could not subscribe to #{topic}: #{inspect(reason)}"
    end
  end

  @doc """
  Unsubscribes the calling process from `topic`. Unsubscribing from
  a topic the process never subscribed to is a no-op.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(topic) when is_binary(topic), do: Phoenix.PubSub.unsubscribe(@server, topic)

  @doc """
  Delivers `message`, any term, to every process subscribed to
  `topic`, e.g. `broadcast("notes:updated", {:note_saved, note})`.
  Returns `:ok` whether or not anyone is subscribed.
  """
  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(topic, message) when is_binary(topic) do
    case Phoenix.PubSub.broadcast(@server, topic, message) do
      :ok -> :ok
      {:error, reason} -> raise "could not broadcast on #{topic}: #{inspect(reason)}"
    end
  end
end
