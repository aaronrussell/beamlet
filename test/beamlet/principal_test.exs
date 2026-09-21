defmodule Beamlet.PrincipalTest do
  use Beamlet.Case

  alias Beamlet.Principal
  alias Beamlet.Users

  test "builds the flat principal from an authenticated token", %{user: user, token: token} do
    {:ok, authenticated} = Users.authenticate(token.secret)

    assert Principal.from_token(authenticated) == %Principal{
             user_id: user.id,
             user_name: "alice",
             token_id: token.id,
             token_label: "test",
             policy: "default"
           }
  end

  @tag policies: [restricted: []]
  test "carries the token's policy", %{user: user} do
    {:ok, token} = Users.create_token(user, name: "phone", policy: "restricted")
    {:ok, authenticated} = Users.authenticate(token.secret)

    assert %Principal{token_label: "phone", policy: "restricted"} =
             Principal.from_token(authenticated)
  end

  test "an oauth token is carried by its client's host", %{user: user} do
    {:ok, token} =
      Users.create_token(user, oauth_attrs("https://claude.ai/.well-known/client.json"))

    {:ok, authenticated} = Users.authenticate(token.secret)

    assert %Principal{token_label: "claude.ai"} = principal = Principal.from_token(authenticated)
    assert {:ok, ^principal} = Principal.from_trailers(Principal.to_trailers(principal))
    assert {:ok, ^principal} = principal |> Principal.to_map() |> Principal.from_map()
  end

  test "system/0 is the beamlet acting on its own behalf, and round-trips" do
    system = Principal.system()

    assert %Principal{
             user_id: 0,
             user_name: "beamlet",
             token_id: 0,
             token_label: "beamlet",
             policy: "default"
           } = system

    assert {:ok, ^system} = Principal.from_trailers(Principal.to_trailers(system))
  end

  describe "trailers" do
    test "round-trip the principal", %{token: token} do
      principal = principal(token)

      assert Principal.to_trailers(principal) ==
               "User: alice (#{principal.user_id})\n" <>
                 "Token: test (#{principal.token_id})\n" <>
                 "Policy: default\n"

      assert {:ok, ^principal} = Principal.from_trailers(Principal.to_trailers(principal))
    end

    test "decode from a whole commit message, in any order", %{token: token} do
      principal = principal(token)

      message =
        "define: Shopping.List (new)\n\nPolicy: default\nUser: alice (#{principal.user_id})\n" <>
          "Token: test (#{principal.token_id})\n"

      assert {:ok, ^principal} = Principal.from_trailers(message)
    end

    test "decoding a message with no trailers is an error" do
      assert :error = Principal.from_trailers("manual changes\n")
      assert :error = Principal.from_trailers("User: alice (1)\n")
    end
  end

  describe "the map encoding" do
    test "round-trips the principal through the JSON shape", %{token: token} do
      principal = principal(token)

      map = Principal.to_map(principal)

      assert map == %{
               "user" => %{"id" => principal.user_id, "name" => "alice"},
               "token" => %{"id" => principal.token_id, "label" => "test"},
               "policy" => "default"
             }

      assert {:ok, ^principal} = map |> JSON.encode!() |> JSON.decode!() |> Principal.from_map()
    end

    test "a map missing a part or with the wrong types is an error" do
      assert :error = Principal.from_map(%{})
      assert :error = Principal.from_map(%{"user" => %{"id" => 1, "name" => "alice"}})

      assert :error =
               Principal.from_map(%{
                 "user" => %{"id" => "1", "name" => "alice"},
                 "token" => %{"id" => 1, "label" => "t"},
                 "policy" => "default"
               })
    end
  end

  test "put_current/1 makes it the current process's principal", %{token: token} do
    assert Principal.current() == nil

    {:ok, authenticated} = Users.authenticate(token.secret)
    principal = Principal.from_token(authenticated)

    assert :ok = Principal.put_current(principal)
    assert Principal.current() == principal
  end

  defp oauth_attrs(client) do
    later = DateTime.add(DateTime.utc_now(), 3600, :second)
    %{kind: :oauth, client: client, expires_at: later, refresh_expires_at: later}
  end
end
