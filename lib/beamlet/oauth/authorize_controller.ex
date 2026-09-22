defmodule Beamlet.OAuth.AuthorizeController do
  @moduledoc """
  The authorization endpoint, `/beamlet/authorize`: where a client
  sends the browser, and where the person consents.

  Both actions sit behind the login, so the beamlet knows who is
  consenting before it reads anything the client sent, and fetches
  the client's document (`Beamlet.OAuth.Clients`) only for a signed-in
  person. `new/2` validates the request and renders the consent
  page; `create/2` validates it again from the form and either
  stores a code (`Beamlet.OAuth.Codes`) and sends the browser back
  to the client, or sends it back with `access_denied`.

  A request the beamlet cannot safely redirect for, an unknown
  client or a redirect URI its document does not list, is an error
  page. Every other fault is answered the way the client expects:
  a redirect carrying `error`, `error_description`, the client's
  `state` and this beamlet's `iss`.
  """

  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Beamlet.OAuth
  alias Beamlet.OAuth.Clients
  alias Beamlet.OAuth.Codes
  alias Beamlet.Policies

  @fields ~w(client_id redirect_uri state scope code_challenge code_challenge_method response_type resource)a

  @doc "Validates the request and renders the consent page."
  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, params) do
    case validate(params) do
      {:ok, request} ->
        consent(conn, request)

      {:error, :page, reason} ->
        error_page(conn, reason)

      {:error, :redirect, request, error, description} ->
        refuse(conn, request, error, description)
    end
  end

  @doc "Takes the decision from the consent form: a code for the client, or `access_denied`."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case validate(params) do
      {:ok, request} ->
        decide(conn, request, params)

      {:error, :page, reason} ->
        error_page(conn, reason)

      {:error, :redirect, request, error, description} ->
        refuse(conn, request, error, description)
    end
  end

  defp decide(conn, request, %{"decision" => "allow", "policy" => policy}) do
    if policy in Policies.names() do
      code =
        Codes.store(%{
          user_id: conn.assigns.current_user.id,
          policy: policy,
          client_id: request.client_id,
          redirect_uri: request.redirect_uri,
          code_challenge: request.code_challenge,
          resource: request.resource,
          scope: request.scope
        })

      back_to_client(conn, request, code: code)
    else
      error_page(conn, :bad_policy)
    end
  end

  defp decide(conn, request, %{"decision" => "deny"}) do
    refuse(conn, request, "access_denied", "the person declined")
  end

  defp decide(conn, _request, _params), do: error_page(conn, :bad_form)

  defp consent(conn, request) do
    policies =
      for name <- Policies.names(), {:ok, policy} <- [Policies.fetch(name)] do
        {name, Enum.map_join(policy.tools, ", ", &to_string/1)}
      end

    conn
    |> assign(:page_title, "Connect to your beamlet")
    |> render(:new,
      request: request,
      client_host: URI.parse(request.client_id).host,
      loopback?: Clients.loopback?(request.redirect_uri),
      policies: policies
    )
  end

  defp error_page(conn, reason) do
    conn
    |> put_status(400)
    |> assign(:page_title, "Could not connect")
    |> render(:error, reason: reason)
  end

  defp refuse(conn, request, error, description) do
    back_to_client(conn, request, error: error, error_description: description)
  end

  defp back_to_client(conn, request, params) do
    params = params ++ [iss: OAuth.issuer()]
    params = if request.state, do: params ++ [state: request.state], else: params
    url = request.redirect_uri |> URI.parse() |> URI.append_query(URI.encode_query(params))
    redirect(conn, external: URI.to_string(url))
  end

  defp validate(params) do
    request =
      Map.new(@fields, fn field -> {field, present(params[Atom.to_string(field)])} end)

    with {:ok, document} <- fetch_client(request.client_id),
         :ok <- check_redirect(document, request.redirect_uri) do
      check_redirectable(request)
    end
  end

  defp fetch_client(nil), do: {:error, :page, :unknown_client}

  defp fetch_client(client_id) do
    case Clients.fetch(client_id) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> {:error, :page, :unknown_client}
    end
  end

  defp check_redirect(document, uri) do
    if Clients.redirect_uri_allowed?(document, uri), do: :ok, else: {:error, :page, :bad_redirect}
  end

  defp check_redirectable(request) do
    cond do
      request.response_type != "code" ->
        {:error, :redirect, request, "unsupported_response_type", "response_type must be code"}

      request.code_challenge == nil ->
        {:error, :redirect, request, "invalid_request", "code_challenge is required"}

      request.code_challenge_method != "S256" ->
        {:error, :redirect, request, "invalid_request", "code_challenge_method must be S256"}

      request.resource != nil and request.resource != OAuth.resource() ->
        {:error, :redirect, request, "invalid_target", "resource must be #{OAuth.resource()}"}

      true ->
        {:ok, request}
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_other), do: nil
end
