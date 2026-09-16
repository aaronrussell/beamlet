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
             token_name: "test",
             policy: "default"
           }
  end

  @tag policies: [restricted: []]
  test "carries the token's policy", %{user: user} do
    {:ok, token} = Users.create_token(user, name: "phone", policy: "restricted")
    {:ok, authenticated} = Users.authenticate(token.secret)

    assert %Principal{token_name: "phone", policy: "restricted"} =
             Principal.from_token(authenticated)
  end

  test "system/0 is the beamlet acting on its own behalf, and round-trips" do
    system = Principal.system()

    assert %Principal{user_id: 0, user_name: "beamlet", token_id: 0, policy: "default"} = system
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

  test "put_current/1 makes it the current process's principal", %{token: token} do
    assert Principal.current() == nil

    {:ok, authenticated} = Users.authenticate(token.secret)
    principal = Principal.from_token(authenticated)

    assert :ok = Principal.put_current(principal)
    assert Principal.current() == principal
  end
end
