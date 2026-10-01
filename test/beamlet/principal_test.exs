defmodule Beamlet.PrincipalTest do
  use Beamlet.Case

  alias Beamlet.Principal
  alias Beamlet.Tokens

  test "builds the flat principal from an authenticated token", %{token: token} do
    {:ok, authenticated} = Tokens.authenticate(token.secret)

    assert Principal.from_token(authenticated) == %Principal{
             token_id: token.id,
             token_label: "test",
             policy: "default"
           }
  end

  @tag policies: [restricted: []]
  test "carries the token's policy" do
    {:ok, token} = Tokens.create(name: "phone", policy: "restricted")
    {:ok, authenticated} = Tokens.authenticate(token.secret)

    assert %Principal{token_label: "phone", policy: "restricted"} =
             Principal.from_token(authenticated)
  end

  test "an oauth token is carried by its client's host" do
    {:ok, token} =
      Tokens.create(oauth_attrs("https://claude.ai/.well-known/client.json"))

    {:ok, authenticated} = Tokens.authenticate(token.secret)

    assert %Principal{token_label: "claude.ai"} = principal = Principal.from_token(authenticated)
    assert {:ok, ^principal} = Principal.from_trailers(Principal.to_trailers(principal))
    assert {:ok, ^principal} = principal |> Principal.to_map() |> Principal.from_map()
  end

  test "system/0 is the beamlet acting on its own behalf, and round-trips" do
    system = Principal.system()

    assert %Principal{token_id: 0, token_label: "beamlet", policy: "default"} = system

    assert {:ok, ^system} = Principal.from_trailers(Principal.to_trailers(system))
  end

  describe "trailers" do
    test "round-trip the principal", %{token: token} do
      principal = principal(token)

      assert Principal.to_trailers(principal) ==
               "Token: test (#{principal.token_id})\nPolicy: default\n"

      assert {:ok, ^principal} = Principal.from_trailers(Principal.to_trailers(principal))
    end

    test "decode from a whole commit message, in any order", %{token: token} do
      principal = principal(token)

      message =
        "define: Shopping.List (new)\n\nPolicy: default\nToken: test (#{principal.token_id})\n"

      assert {:ok, ^principal} = Principal.from_trailers(message)
    end

    test "decoding a message with no trailers is an error" do
      assert :error = Principal.from_trailers("manual changes\n")
      assert :error = Principal.from_trailers("Token: test (1)\n")
    end
  end

  describe "the map encoding" do
    test "round-trips the principal through the JSON shape", %{token: token} do
      principal = principal(token)

      map = Principal.to_map(principal)

      assert map == %{
               "token" => %{"id" => principal.token_id, "label" => "test"},
               "policy" => "default"
             }

      assert {:ok, ^principal} = map |> JSON.encode!() |> JSON.decode!() |> Principal.from_map()
    end

    test "a map missing a part or with the wrong types is an error" do
      assert :error = Principal.from_map(%{})
      assert :error = Principal.from_map(%{"token" => %{"id" => 1, "label" => "t"}})

      assert :error =
               Principal.from_map(%{
                 "token" => %{"id" => "1", "label" => "t"},
                 "policy" => "default"
               })
    end
  end

  test "put_current/1 makes it the current process's principal", %{token: token} do
    assert Principal.current() == nil

    {:ok, authenticated} = Tokens.authenticate(token.secret)
    principal = Principal.from_token(authenticated)

    assert :ok = Principal.put_current(principal)
    assert Principal.current() == principal
  end

  test "current!/1 returns the current principal, and raises naming the caller without one",
       %{token: token} do
    assert_raise RuntimeError,
                 "Host.Code.remove works from eval, where your code acts as you; " <>
                   "there is no principal in this process",
                 fn -> Principal.current!("Host.Code.remove") end

    principal = principal(token)
    Principal.put_current(principal)
    assert Principal.current!("Host.Code.remove") == principal
  end

  defp oauth_attrs(client) do
    later = DateTime.add(DateTime.utc_now(), 3600, :second)
    %{kind: :oauth, client: client, expires_at: later, refresh_expires_at: later}
  end
end
