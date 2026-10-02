defmodule Beamlet.OAuth.TokenController do
  @moduledoc """
  The token endpoint, `/beamlet/token`: where a client turns a code
  into a token, and later a refresh token into a new pair.

  Form-encoded in, JSON out, as the spec has it, and the errors are
  OAuth error bodies, `invalid_grant` and friends, because the client
  reads them. `grant_type=authorization_code` redeems a code from
  `Beamlet.OAuth.Codes`: the client id, redirect URI and, when sent,
  the resource must be the ones the code was issued for, a resource
  first named here being this beamlet's, and the `code_verifier` must
  hash to the challenge the client committed to. Then `Beamlet.Tokens.create/1` mints an `oauth` token under
  the consented policy. `grant_type=refresh_token` rotates that token
  in place (`Beamlet.Tokens.rotate/2`): the old secrets die, the row
  and its id stay.

  No client authentication: every client is public, identified by
  the client id it sends, which must match what the code or token
  records. No scopes: `scope` is echoed when the client sent one and
  means nothing here, since what a token may do is its policy.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias Beamlet.OAuth
  alias Beamlet.OAuth.Codes
  alias Beamlet.Token
  alias Beamlet.Tokens

  plug :no_store

  @doc "Answers the grant the form names."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"grant_type" => "authorization_code"} = params), do: exchange(conn, params)
  def create(conn, %{"grant_type" => "refresh_token"} = params), do: refresh(conn, params)

  def create(conn, _params) do
    error(
      conn,
      "unsupported_grant_type",
      "grant_type must be authorization_code or refresh_token"
    )
  end

  defp exchange(conn, params) do
    with {:ok, [code, client_id, redirect_uri, verifier]} <-
           required(params, ~w(code client_id redirect_uri code_verifier)),
         {:ok, entry} <- take(code),
         :ok <- issued_for(entry, client_id, redirect_uri, params["resource"]),
         :ok <- verify(entry.code_challenge, verifier),
         {:ok, token} <- mint(entry) do
      json(conn, reply(token, entry.scope))
    else
      {:error, code, description} -> error(conn, code, description)
    end
  end

  defp refresh(conn, params) do
    with {:ok, [secret, client_id]} <- required(params, ~w(refresh_token client_id)),
         {:ok, token} <- authenticate(secret),
         :ok <- same_client(token, client_id),
         {:ok, token} <- rotate(token) do
      json(conn, reply(token, nil))
    else
      {:error, code, description} -> error(conn, code, description)
    end
  end

  defp required(params, names) do
    values = Enum.map(names, &OAuth.present(params[&1]))

    case Enum.zip(names, values) |> Enum.filter(fn {_name, value} -> value == nil end) do
      [] ->
        {:ok, values}

      missing ->
        {:error, "invalid_request", Enum.map_join(missing, ", ", &elem(&1, 0)) <> " required"}
    end
  end

  defp take(code) do
    case Codes.take(code) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, "invalid_grant", "the code is unknown, already used or expired"}
    end
  end

  defp issued_for(entry, client_id, redirect_uri, resource) do
    cond do
      entry.client_id != client_id ->
        {:error, "invalid_grant", "the code was issued to another client"}

      entry.redirect_uri != redirect_uri ->
        {:error, "invalid_grant", "redirect_uri does not match the authorization request"}

      OAuth.present(resource) != nil and resource != (entry.resource || OAuth.resource()) ->
        {:error, "invalid_grant", "resource does not match the authorization request"}

      true ->
        :ok
    end
  end

  defp verify(challenge, verifier) do
    hashed = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    if Plug.Crypto.secure_compare(hashed, challenge),
      do: :ok,
      else: {:error, "invalid_grant", "code_verifier does not match the code_challenge"}
  end

  defp mint(entry) do
    attrs =
      Map.merge(%{kind: :oauth, client: entry.client_id, policy: entry.policy}, OAuth.expiries())

    case Tokens.create(attrs) do
      {:ok, token} ->
        {:ok, token}

      {:error, _changeset} ->
        {:error, "invalid_grant", "the consented policy is no longer declared on this beamlet"}
    end
  end

  defp authenticate(secret) do
    case Tokens.authenticate_refresh(secret) do
      {:ok, token} ->
        {:ok, token}

      {:error, :unknown_token} ->
        {:error, "invalid_grant", "the refresh token is unknown or already used"}

      {:error, :expired_token} ->
        {:error, "invalid_grant", "the refresh token has expired"}
    end
  end

  defp same_client(%Token{client: client}, client_id) do
    if client == client_id,
      do: :ok,
      else: {:error, "invalid_grant", "the refresh token was issued to another client"}
  end

  defp rotate(token) do
    case Tokens.rotate(token, OAuth.expiries()) do
      {:ok, token} ->
        {:ok, token}

      {:error, :unknown_token} ->
        {:error, "invalid_grant", "the refresh token is unknown or already used"}

      {:error, _reason} ->
        {:error, "invalid_grant", "the token could not be refreshed"}
    end
  end

  defp reply(%Token{} = token, scope) do
    reply = %{
      access_token: token.secret,
      token_type: "Bearer",
      expires_in: OAuth.access_ttl(),
      refresh_token: token.refresh_secret
    }

    if scope, do: Map.put(reply, :scope, scope), else: reply
  end

  defp error(conn, code, description) do
    conn
    |> put_status(400)
    |> json(%{error: code, error_description: description})
  end

  # A token reply is a secret; nothing on the way may keep a copy.
  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")
end
