defmodule Beamlet.Web.HomeLive do
  @moduledoc false

  # The home page at /beamlet, behind the login: how to connect the
  # apps, coding agents and code a person works with to this beamlet.
  # Snippets that carry braces are built as strings, since a `{` in a
  # template body is an interpolation.

  use Phoenix.LiveView

  alias Beamlet.OAuth
  alias Beamlet.Web.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "beamlet", url: OAuth.resource())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app current_user={@current_user}>
      <h1 class="text-2xl font-semibold">Your beamlet</h1>
      <p class="mt-3">
        Your beamlet is an MCP server. Add it to the app or agent you work in, and that app can read what is on your beamlet and build on it.
      </p>
      <p class="mt-3">Every client below connects to this URL:</p>
      <pre id="mcp-url" class={pre()}><code>{@url}</code></pre>

      <section class="mt-12">
        <h2 class="text-xl font-semibold">Apps</h2>
        <p class="mt-3">
          Claude, ChatGPT and other apps connect by signing in here. You give the app the URL, and when it first uses your beamlet it sends you to this beamlet to sign in and choose what it may do.
        </p>

        <h3 class="mt-6 font-semibold">Claude</h3>
        <ol class={ol()}>
          <li>Open Settings, then Connectors, and choose Add custom connector.</li>
          <li>Enter a name and the URL above, then Continue.</li>
          <li>
            Leave Authentication at "Sign in now" and OAuth client at "Use Claude's published identity", both detected, and add the connector.
          </li>
          <li>When Claude asks you to sign in, sign in on this beamlet and choose a policy.</li>
        </ol>

        <h3 class="mt-6 font-semibold">ChatGPT</h3>
        <ol class={ol()}>
          <li>Open Settings, then Plugins, then Browse plugins, and choose the plus button.</li>
          <li>Enter a name, the URL above as the server URL, and OAuth as the authentication.</li>
          <li>Tick the acknowledgement and choose Create.</li>
          <li>When ChatGPT asks you to sign in, sign in on this beamlet and choose a policy.</li>
        </ol>

        <h3 class="mt-6 font-semibold">Other apps</h3>
        <p class="mt-2">
          Any app that connects to MCP servers by OAuth works the same way: give it the URL and sign in when it asks. There is nothing else to configure and no client to register.
        </p>

        <p class="mt-6 text-sm text-zinc-600">
          A policy is what a connected app may do on your beamlet: which tools it has and what its code may reach. You choose one when you sign in, from the policies you have been granted.
        </p>
      </section>

      <section class="mt-12">
        <h2 class="text-xl font-semibold">Coding agents</h2>
        <p class="mt-3">Claude Code and Codex sign in the same way, from the terminal.</p>

        <h3 class="mt-6 font-semibold">Claude Code</h3>
        <pre class={pre()}><code>claude mcp add --transport http beamlet {@url}</code></pre>
        <p class="mt-2">Then, in Claude Code, run <code>/mcp</code>, choose beamlet and choose Authenticate.</p>

        <h3 class="mt-6 font-semibold">Codex</h3>
        <pre class={pre()}><code>{codex(@url)}</code></pre>

        <h3 class="mt-6 font-semibold">Everything else needs a token</h3>
        <p class="mt-2">
          An agent or editor that sends a header instead of signing in uses a token. Whoever operates this beamlet creates one for you and gives you the secret, which is shown once:
        </p>
        <pre id="token-command" class={pre()}><code>beamlet tokens.create NAME --user {@current_user.name}</code></pre>
        <p class="mt-2">
          Keep the secret in an environment variable, <code>BEAMLET_TOKEN</code> below, rather than in a file you might commit.
        </p>

        <h3 class="mt-6 font-semibold">Cursor</h3>
        <p class="mt-2">
          In <code>.cursor/mcp.json</code> in the project, or <code>~/.cursor/mcp.json</code> for every project:
        </p>
        <pre class={pre()}><code>{cursor(@url)}</code></pre>

        <h3 class="mt-6 font-semibold">Claude Code with a token</h3>
        <p class="mt-2">
          For a setup with no browser to sign in from, in the project's <code>.mcp.json</code>:
        </p>
        <pre class={pre()}><code>{claude_code(@url)}</code></pre>
      </section>

      <section class="mt-12">
        <h2 class="text-xl font-semibold">From code</h2>
        <p class="mt-3">
          Code that calls a model can hand it your beamlet as a tool server. It needs a token, as above.
        </p>

        <h3 class="mt-6 font-semibold">Claude API</h3>
        <pre class={pre()}><code>{anthropic(@url)}</code></pre>

        <h3 class="mt-6 font-semibold">OpenAI API</h3>
        <pre class={pre()}><code>{openai(@url)}</code></pre>
      </section>
    </Layouts.app>
    """
  end

  defp pre, do: "mt-3 overflow-x-auto rounded bg-zinc-100 p-3 text-sm"
  defp ol, do: "mt-2 list-decimal space-y-1 pl-6"

  defp codex(url) do
    """
    codex mcp add beamlet --url #{url}
    codex mcp login beamlet\
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

  defp claude_code(url) do
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
