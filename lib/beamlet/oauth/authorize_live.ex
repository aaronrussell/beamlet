defmodule Beamlet.OAuth.AuthorizeLive do
  @moduledoc """
  The authorization endpoint, `/beamlet/authorize`: where a client
  sends the browser, and where the person consents.

  The page sits behind the login, so the beamlet knows who is
  consenting before it reads anything the client sent, and fetches
  the client's document (`Beamlet.OAuth.Clients`) only for a signed-in
  person. Mounting validates the request and shows the consent form;
  the decision either stores a code (`Beamlet.OAuth.Codes`) and sends
  the browser back to the client, or sends it back with
  `access_denied`. The request lives in the page's own state between
  the two, so nothing the form carries can be tampered with. The
  policies on offer are the ones the signed-in user may carry
  (`Beamlet.Users.policies/1`).

  A request the beamlet cannot safely redirect for, an unknown
  client or a redirect URI its document does not list, is an error
  page. Every other fault is answered the way the client expects:
  a redirect carrying `error`, `error_description`, the client's
  `state` and this beamlet's `iss`.

  The way back to the client depends on its redirect URI. An http or
  https one is a plain redirect. A custom scheme, which is how a
  desktop app such as Raycast receives its code, is a page that sends
  the browser on and says the app has been opened, since a redirect
  there opens the app and leaves the tab on whatever page it was on.
  """

  use Phoenix.LiveView

  import Beamlet.Web.Components

  alias Beamlet.OAuth
  alias Beamlet.OAuth.Clients
  alias Beamlet.OAuth.Codes
  alias Beamlet.Policies
  alias Beamlet.Users
  alias Beamlet.Web.Layouts

  @fields ~w(client_id redirect_uri state scope code_challenge code_challenge_method response_type resource)a

  @impl true
  def mount(params, _session, socket) do
    case validate(params) do
      {:ok, request} ->
        {:ok, consent(socket, request)}

      {:error, :page, reason} ->
        {:ok, error_page(socket, reason)}

      {:error, :redirect, request, error, description} ->
        {:ok, refuse(socket, request, error, description)}
    end
  end

  @impl true
  def handle_event("decide", params, %{assigns: %{page: :consent, request: request}} = socket) do
    {:noreply, decide(socket, request, params)}
  end

  def handle_event("decide", _params, socket), do: {:noreply, socket}

  @impl true
  def render(%{page: :consent} = assigns) do
    ~H"""
    <Layouts.split tagline={"#{@client_host} wants to connect."}>
      <:aside>
        <p id="client-id" class="mt-3 font-mono text-2xs break-all text-faint">{@request.client_id}</p>
      </:aside>

      <h1 class="text-xl">What may it do?</h1>
      <p class="mt-2.5 max-w-[44ch]">
        A policy is the set of tools a connected app has, and what its code may reach.
      </p>

      <.flash :if={@loopback?} id="loopback-warning" kind="info">
        This app is running on your own computer. Allowing sends it a code at {@request.redirect_uri}.
      </.flash>

      <form id="consent-form" phx-submit="decide" class="mt-5">
        <fieldset class="flex flex-col gap-2">
          <legend class="sr-only">What may it do on your beamlet?</legend>
          <label
            :for={{name, tools} <- @policies}
            class="flex cursor-pointer items-start gap-[11px] rounded-sm border border-line bg-card px-3.5 py-3 transition has-checked:border-strong has-checked:bg-slate-50 has-checked:shadow-lift-2"
          >
            <input type="radio" name="policy" value={name} checked={name == @selected} class="peer sr-only" />
            <span class="mt-[3px] flex size-3.5 flex-none items-center justify-center rounded-full border border-line bg-card after:size-[7px] after:rounded-full after:bg-primary after:opacity-0 peer-checked:border-strong peer-checked:after:opacity-100 peer-focus-visible:shadow-focus">
            </span>
            <span class="flex flex-col gap-[3px]">
              <span class="font-mono text-sm text-strong">{name}</span>
              <span class="text-sm text-muted">{tools}</span>
            </span>
          </label>
        </fieldset>

        <div class="mt-5 flex gap-2.5">
          <.button type="submit" name="decision" value="allow" variant="primary" size="lg">Allow</.button>
          <.button type="submit" name="decision" value="deny" size="lg">Deny</.button>
        </div>
      </form>

      <p id="signed-in" class="mt-6 text-sm text-muted">Signed in as {@current_user.name}.</p>
    </Layouts.split>
    """
  end

  def render(%{page: :sent} = assigns) do
    ~H"""
    <meta http-equiv="refresh" content={"0;url=" <> @location} />
    <Layouts.split tagline="Connected.">
      <h1 class="text-xl">Sending you back to {@client_host}</h1>
      <p id="sent" class="mt-2.5">
        The app should open on its own. If it does not, <a href={@location}>open it here</a>. You can close this tab.
      </p>
    </Layouts.split>
    """
  end

  def render(%{page: :error} = assigns) do
    ~H"""
    <Layouts.split tagline="That app could not connect.">
      <h1 class="text-xl">This beamlet could not verify the app asking to connect</h1>
      <p id="error-reason" class="mt-2.5">
        <%= case @reason do %>
          <% :unknown_client -> %>
            The app's client id must be an https URL serving its client metadata document, and this one could not be fetched or read.
          <% :bad_redirect -> %>
            The app asked to be sent to an address its metadata document does not list.
          <% :bad_policy -> %>
            The chosen policy is not one this beamlet lets you use.
          <% :bad_form -> %>
            The consent form was incomplete. Go back to the app and connect again.
        <% end %>
      </p>
    </Layouts.split>
    """
  end

  defp decide(socket, request, %{"decision" => "allow", "policy" => policy}) do
    user = socket.assigns.current_user

    if policy in Users.policies(user) do
      code =
        Codes.store(%{
          user_id: user.id,
          policy: policy,
          client_id: request.client_id,
          redirect_uri: request.redirect_uri,
          code_challenge: request.code_challenge,
          resource: request.resource,
          scope: request.scope
        })

      back_to_client(socket, request, code: code)
    else
      error_page(socket, :bad_policy)
    end
  end

  defp decide(socket, request, %{"decision" => "deny"}) do
    refuse(socket, request, "access_denied", "the person declined")
  end

  defp decide(socket, _request, _params), do: error_page(socket, :bad_form)

  # The page offers only what the user may carry, so the gate in
  # `Users.create_token/2` never refuses a choice made here; `default`
  # is preselected when it is on offer and the user's first policy
  # otherwise.
  defp consent(socket, request) do
    names = Users.policies(socket.assigns.current_user)

    policies =
      for name <- names, {:ok, policy} <- [Policies.fetch(name)] do
        {name, Enum.map_join(policy.tools, ", ", &to_string/1)}
      end

    assign(socket,
      page: :consent,
      page_title: "Connect to your beamlet",
      request: request,
      client_host: URI.parse(request.client_id).host,
      loopback?: Clients.loopback?(request.redirect_uri),
      policies: policies,
      selected: if("default" in names, do: "default", else: List.first(names))
    )
  end

  defp error_page(socket, reason) do
    assign(socket, page: :error, page_title: "Could not connect", reason: reason)
  end

  defp refuse(socket, request, error, description) do
    back_to_client(socket, request, error: error, error_description: description)
  end

  defp back_to_client(socket, request, params) do
    params = params ++ [iss: OAuth.issuer()]
    params = if request.state, do: params ++ [state: request.state], else: params
    uri = request.redirect_uri |> URI.parse() |> URI.append_query(URI.encode_query(params))

    if uri.scheme in ["http", "https"] do
      redirect(socket, external: URI.to_string(uri))
    else
      assign(socket,
        page: :sent,
        page_title: "Sending you back",
        location: URI.to_string(uri),
        client_host: URI.parse(request.client_id).host
      )
    end
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
