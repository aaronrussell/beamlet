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
end
