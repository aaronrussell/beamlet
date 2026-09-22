defmodule Beamlet.OAuth.CodesTest do
  use ExUnit.Case, async: true

  alias Beamlet.OAuth.Codes

  @entry %{
    user_id: 1,
    policy: "default",
    client_id: "https://chat.example/client.json",
    redirect_uri: "https://chat.example/callback",
    code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
    resource: nil,
    scope: nil
  }

  defp start(opts) do
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!({Codes, [name: name] ++ opts})
  end

  test "a code redeems its entry once" do
    codes = start([])
    code = Codes.store(@entry, codes)

    assert byte_size(code) == 43
    assert Codes.take(code, codes) == {:ok, @entry}
    assert Codes.take(code, codes) == :error
  end

  test "codes are unique and unknown or malformed ones are errors" do
    codes = start([])
    assert Codes.store(@entry, codes) != Codes.store(@entry, codes)
    assert Codes.take("not-a-code", codes) == :error
    assert Codes.take(nil, codes) == :error
  end

  test "an expired code is an error at take" do
    codes = start(ttl: 0)
    code = Codes.store(@entry, codes)
    assert Codes.take(code, codes) == :error
  end

  test "the sweep drops expired codes" do
    codes = start(ttl: 0)
    Codes.store(@entry, codes)
    assert map_size(:sys.get_state(codes).codes) == 1

    send(codes, :sweep)
    assert :sys.get_state(codes).codes == %{}
  end
end
