defmodule Beamlet.Eval.Output do
  @moduledoc false

  # The group leader of an evaluation: an io device that keeps the
  # first `max` bytes printed and only counts the rest, so a print
  # loop costs the beamlet a counter rather than its memory. It
  # answers what StringIO answers, with no input to read, and stops
  # when the process that started it does, a cancelled tool use
  # included.

  use GenServer

  @doc """
  Starts a device keeping the first `max` bytes printed, owned by the
  caller and stopping when it does.
  """
  @spec start(non_neg_integer()) :: {:ok, pid()}
  def start(max), do: GenServer.start(__MODULE__, {self(), max})

  @doc """
  Stops the device, returning the bytes kept and the count printed in
  all.
  """
  @spec close(pid()) :: {binary(), non_neg_integer()}
  def close(device), do: GenServer.call(device, :close)

  @impl true
  def init({owner, max}) do
    Process.monitor(owner)
    {:ok, %{max: max, kept: "", total: 0}}
  end

  @impl true
  def handle_call(:close, _from, state), do: {:stop, :normal, {state.kept, state.total}, state}

  @impl true
  def handle_info({:io_request, from, reply_as, request}, state) do
    {reply, state} = io_request(request, state)
    send(from, {:io_reply, reply_as, reply})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

  defp io_request({:put_chars, chars} = request, state),
    do: put_chars(:latin1, chars, request, state)

  defp io_request({:put_chars, mod, fun, args} = request, state),
    do: put_chars(:latin1, apply(mod, fun, args), request, state)

  defp io_request({:put_chars, encoding, chars} = request, state),
    do: put_chars(encoding, chars, request, state)

  defp io_request({:put_chars, encoding, mod, fun, args} = request, state),
    do: put_chars(encoding, apply(mod, fun, args), request, state)

  defp io_request(request, state)
       when elem(request, 0) in [:get_chars, :get_line, :get_until, :get_password],
       do: {:eof, state}

  defp io_request({:setopts, [encoding: :unicode]}, state), do: {:ok, state}
  defp io_request({:setopts, _opts}, state), do: {{:error, :enotsup}, state}
  defp io_request(:getopts, state), do: {[binary: true, encoding: :unicode], state}
  defp io_request({:get_geometry, _dimension}, state), do: {{:error, :enotsup}, state}
  defp io_request({:requests, requests}, state), do: io_requests(requests, {:ok, state})
  defp io_request(_request, state), do: {{:error, :request}, state}

  defp io_requests([request | rest], {:ok, state}),
    do: io_requests(rest, io_request(request, state))

  defp io_requests(_requests, result), do: result

  # The kept slice is copied: a slice of a large binary would hold
  # the whole of it.
  defp put_chars(encoding, chars, request, state) do
    case :unicode.characters_to_binary(chars, encoding, :unicode) do
      string when is_binary(string) ->
        room = state.max - byte_size(state.kept)
        slice = :binary.copy(binary_part(string, 0, min(room, byte_size(string))))
        {:ok, %{state | kept: state.kept <> slice, total: state.total + byte_size(string)}}

      {_, _, _} ->
        {{:error, {:no_translation, encoding, :unicode}}, state}
    end
  rescue
    ArgumentError -> {{:error, request}, state}
  end
end
