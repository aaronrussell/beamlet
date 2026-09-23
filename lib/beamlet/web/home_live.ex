defmodule Beamlet.Web.HomeLive do
  @moduledoc false

  # The home page at /beamlet, behind the login: how to connect the
  # apps, coding agents and code a person works with to this beamlet,
  # one client at a time, chosen by the `client` query parameter.
  # Snippets that carry braces are built as strings, since a `{` in a
  # template body is an interpolation.

  use Phoenix.LiveView

  import Beamlet.Web.Components

  alias Beamlet.OAuth
  alias Beamlet.Web.Layouts
  alias Phoenix.LiveView.JS

  @clients [
    {"chatgpt", "ChatGPT"},
    {"claude", "Claude"},
    {"claude-code", "Claude Code"},
    {"cursor", "Cursor"},
    {"code", "From code"},
    {"other", "Other apps"}
  ]

  @first_client hd(@clients)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "beamlet", url: OAuth.resource(), clients: @clients)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    client =
      if List.keymember?(@clients, params["client"], 0),
        do: params["client"],
        else: elem(@first_client, 0)

    {:noreply, assign(socket, :client, client)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app current_user={@current_user}>
      <h1 class="text-3xl leading-[1.06] tracking-display">Your beamlet</h1>
      <p class="mt-3.5 max-w-[66ch] text-md leading-normal text-muted">
        Your beamlet is an MCP server. Add it to the app or agent you work in, and that app can read what is on your beamlet and build on it.
      </p>
      <div class="mt-5 inline-flex max-w-full items-center gap-8 rounded-md border border-strong bg-card p-2.5 pl-4 shadow-lift-2">
        <span id="mcp-url" class="overflow-x-auto font-mono text-sm text-strong">{@url}</span>
        <.button size="sm" phx-click={JS.dispatch("beamlet:copy", to: "#mcp-url")}>Copy</.button>
      </div>

      <p class="mt-9 font-mono text-2xs uppercase tracking-label text-muted">Connect from</p>
      <nav id="clients" role="tablist" class="mt-3.5 flex flex-wrap gap-5 border-b border-hairline">
        <.link
          :for={{key, label} <- @clients}
          patch={"/beamlet?client=#{key}"}
          role="tab"
          aria-selected={key == @client}
          class={[
            "-mb-px whitespace-nowrap border-b-2 pb-2.5 font-display text-sm no-underline transition",
            if(key == @client,
              do: "border-primary font-semibold text-strong",
              else: "border-transparent font-medium text-muted hover:text-strong"
            )
          ]}
        >
          {label}
        </.link>
      </nav>

      <section id="guide" class="mt-6 max-w-[680px]">
        <.guide client={@client} url={@url} user={@current_user} />
      </section>
    </Layouts.app>
    """
  end

  defp guide(%{client: "chatgpt"} = assigns) do
    ~H"""
    <h2 class="text-xl">ChatGPT</h2>
    <p class="mt-3">
      To connect your beamlet to ChatGPT, you must first enable
      <a rel="noopener" target="_blank" href="https://help.openai.com/en/articles/12584461-developer-mode-and-mcp-apps-in-chatgpt">Developer mode</a>,
      in order to add an MCP App.
      When connecting, ChatGPT will ask you to sign in to your beamlet and choose what it may do.
    </p>
    <.steps>
      <:step>
        Open <code>Settings</code>, then <code>Plugins</code> and choose <code>Developer mode</code>, and ensure it is toggled on.
      </:step>
      <:step>Open <code>Settings</code>, then <code>Plugins</code>, and choose <code>Browse plugins</code>.</:step>
      <:step>
        From the Plugins screen, click the <code>+</code> button and select <code>Create app</code>.<br>
        From the popup dialog click <code>Create MCP App</code>.
      </:step>
      <:step>
        Enter a name and the URL from above, and select OAuth for authentication.<br>
        Tick the big, bad "I understand the risks" checkbox, then click <code>Create</code>.
      </:step>
      <:step>
        ChatGPT sends you to your beamlet. Sign in and choose a <em>policy</em>.
        <.policy_note />
      </:step>
      <:step>Once connected, start a new chat and prompt ChatGPT, "What can I do with my beamlet?".</:step>
    </.steps>
    """
  end

  defp guide(%{client: "claude"} = assigns) do
    ~H"""
    <h2 class="text-xl">Claude</h2>
    <p class="mt-3">
      You can connect your beamlet to Claude by adding a
      <a rel="noopener" target="_blank" href="https://support.claude.com/en/articles/11175166-get-started-with-custom-connectors-using-remote-mcp">Custom connector</a>.
      When connecting, Claude will ask you to sign in to your beamlet and choose what it may do.
    </p>
    <.steps>
      <:step>Open <code>Settings</code>, then <code>Connectors</code>, and choose <code>Add custom connector</code>.</:step>
      <:step>Enter a name and the URL from above, then <code>Continue</code>.</:step>
      <:step>Leave the default Authentication and OAuth settings, scroll down and click <code>Add</code>.</:step>
      <:step>
        Claude sends you to your beamlet. Sign in and choose a <em>policy</em>.
        <.policy_note />
      </:step>
      <:step>Once connected, start a new chat and ask Claude, "What can I do with my beamlet?".</:step>
    </.steps>

    """
  end

  defp guide(%{client: "claude-code"} = assigns) do
    ~H"""
    <h2 class="text-xl">Claude Code</h2>
    <p class="mt-3">
      You can connect your beamlet to Claude Code using OAuth or with a token from the beamlet operator.
    </p>
    <h3 class="mt-8 text-md">OAuth</h3>
    <.steps>
      <:step>
        Add your beamlet as an MCP server, then login to connect.
        <.code>{claude_code(:cli, @url)}</.code>
      </:step>
      <:step>
        Claude Code opens your beamlet in a browser. Sign in and choose a <em>policy</em>.
        <.policy_note />
      </:step>
      <:step>Once connected, start a new chat and ask Claude, "What can I do with my beamlet?".</:step>
    </.steps>

    <h3 class="mt-8 text-md">With a token</h3>
    <.steps>
      <:step>
        The beamlet operator can generate an authentication token from the CLI.
        <.code class="my-2">beamlet tokens.create NAME --user {@user.name}</.code>
        Keep the token in an environment variable, <code>BEAMLET_TOKEN</code>, rather than in a file you might commit.
      </:step>
      <:step>
        Add to the project's <code>.mcp.json</code>:
        <.code>{claude_code(:config, @url)}</.code>
      </:step>
    </.steps>
    """
  end

  defp guide(%{client: "cursor"} = assigns) do
    ~H"""
    <h2 class="text-xl">Cursor</h2>
    <p class="mt-3">
      You can connect your beamlet to Cursor by manually generating an authentication token.
    </p>
    <.steps>
      <:step>
        The beamlet operator can generate an authentication token from the CLI.
        <.code class="my-2">beamlet tokens.create NAME --user {@user.name}</.code>
        Keep the token in an environment variable, <code>BEAMLET_TOKEN</code>, rather than in a file you might commit.
      </:step>
      <:step>
        Add to <code>.cursor/mcp.json</code> in the project, or <code>~/.cursor/mcp.json</code> for every project:
        <.code>{cursor(@url)}</.code>
      </:step>
    </.steps>
    """
  end

  defp guide(%{client: "code"} = assigns) do
    ~H"""
    <h2 class="text-xl">From code</h2>
    <p class="mt-3">
      If you're working with LLM APIs, you can integrate Beamlet by manually generating an authentication token.
    </p>
    <p class="mt-2">
      The beamlet operator can generate an authentication token from the CLI.
      <.code class="my-2">beamlet tokens.create NAME --user {@user.name}</.code>
      Keep the token in an environment variable, <code>BEAMLET_TOKEN</code>, rather than in a file you might commit.
    </p>

    <h3 class="mt-8 text-md">Claude API</h3>
    <.code>{anthropic(@url)}</.code>

    <h3 class="mt-8 text-md">OpenAI API</h3>
    <.code>{openai(@url)}</.code>
    """
  end

  defp guide(%{client: "other"} = assigns) do
    ~H"""
    <h2 class="text-xl">Other apps</h2>
    <p class="mt-3">
      Any app that connects to MCP servers by OAuth works the same way as Claude and ChatGPT:
      give it the URL and sign in when it asks. There is nothing else to configure.
    </p>
    <p class="mt-2">
      For everything else, agents or editors that support MCP without OAuth,
      generate an authentication token manually and send it as a header.
    </p>
    """
  end

  defp policy_note(assigns) do
    ~H"""
    <p class="mt-2 text-sm text-muted">
      A policy is what a connected app may do on your beamlet: which tools it has and what its code may reach.
      You choose one when you sign in, from the policies you have been granted.
    </p>
    """
  end

  defp claude_code(:cli, url) do
    """
    claude mcp add --transport http beamlet #{url}
    claude mcp login beamlet\
    """
  end

  defp claude_code(:config, url) do
    """
    {
      "mcpServers": {
        "beamlet": {
          "type": "http",
          "url": "#{url}",
          "headers": {"Authorization": "Bearer ${BEAMLET_TOKEN}"}
        }
      }
    }\
    """
  end

  defp cursor(url) do
    """
    {
      "mcpServers": {
        "beamlet": {
          "url": "#{url}",
          "headers": {"Authorization": "Bearer ${env:BEAMLET_TOKEN}"}
        }
      }
    }\
    """
  end

  defp anthropic(url) do
    """
    import Anthropic from "@anthropic-ai/sdk";

    const anthropic = new Anthropic();

    const response = await anthropic.beta.messages.create({
      model: "claude-opus-5",
      max_tokens: 1024,
      messages: [{role: "user", content: "What is on my beamlet?"}],
      mcp_servers: [
        {
          type: "url",
          url: "#{url}",
          name: "beamlet",
          authorization_token: process.env.BEAMLET_TOKEN
        }
      ],
      tools: [{type: "mcp_toolset", mcp_server_name: "beamlet"}],
      betas: ["mcp-client-2025-11-20"]
    });\
    """
  end

  defp openai(url) do
    """
    import OpenAI from "openai";

    const client = new OpenAI();

    const response = await client.responses.create({
      model: "gpt-6-astra",
      input: "What is on my beamlet?",
      tools: [
        {
          type: "mcp",
          server_label: "beamlet",
          server_url: "#{url}",
          authorization: process.env.BEAMLET_TOKEN,
          require_approval: "never"
        }
      ]
    });\
    """
  end
end
