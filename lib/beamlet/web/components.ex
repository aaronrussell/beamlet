defmodule Beamlet.Web.Components do
  @moduledoc """
  The pieces the beamlet's own pages are built from.

  Each one is a Beamlet design system component in Tailwind classes
  over the theme in `assets/css/beamlet.css`: the wordmark, the
  button, the labelled input, the flash, the code panel and the
  numbered steps. A piece is added here when a second page needs it;
  a page-specific piece stays in its page.
  """

  use Phoenix.Component

  @doc "The wordmark: the ochre beam block and the word, sized by `class`."
  attr :class, :string, default: "text-lg"

  def wordmark(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-[0.4em]", @class]}>
      <span class="inline-block size-[0.46em] rounded-[2px] border border-strong bg-ochre-400 shadow-[1.5px_1.5px_0_var(--color-putty-900)]">
      </span>
      <span class="font-display text-[1em] font-bold leading-none tracking-[-0.04em] text-strong">
        beamlet
      </span>
    </span>
    """
  end

  @doc """
  A button: primary for the one action on a view, secondary beside
  it, ghost for chrome.
  """
  attr :type, :string, default: "button"
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost)
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :full, :boolean, default: false
  attr :rest, :global, include: ~w(name value disabled)
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex cursor-pointer items-center justify-center whitespace-nowrap rounded-sm border font-display font-semibold leading-none tracking-heading transition",
        @full && "flex w-full",
        size(@size),
        variant(@variant)
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp size("sm"), do: "h-[26px] gap-1.5 px-2.5 text-sm"
  defp size("md"), do: "h-8 gap-[7px] px-3.5 text-sm"
  defp size("lg"), do: "h-10 gap-2 px-5 text-base"

  defp variant("primary"),
    do:
      "border-strong bg-primary text-on-primary shadow-lift-2 hover:bg-primary-hover active:translate-x-px active:translate-y-px active:shadow-lift-press"

  defp variant("secondary"),
    do:
      "border-strong bg-card text-strong shadow-lift-2 hover:bg-putty-100 active:translate-x-px active:translate-y-px active:shadow-lift-press"

  defp variant("ghost"), do: "border-transparent bg-transparent text-body hover:bg-putty-100"

  @doc "A labelled text field, the label in mono small caps above it."
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :mono, :boolean, default: false
  attr :rest, :global, include: ~w(autocomplete autofocus required)

  def input(assigns) do
    ~H"""
    <label class="flex flex-col gap-1.5">
      <span class="font-mono text-2xs uppercase tracking-label text-muted">{@label}</span>
      <input
        type={@type}
        name={@field.name}
        value={@field.value}
        class={[
          "h-10 w-full rounded-sm border border-line bg-card px-3 text-base text-strong shadow-inset-top transition focus:border-primary focus:shadow-field-focus",
          @mono && "font-mono"
        ]}
        {@rest}
      />
    </label>
    """
  end

  @doc "A flash line: an error in rust, information in slate."
  attr :id, :string, required: true
  attr :kind, :string, required: true, values: ~w(error info)
  attr :class, :string, default: "mt-4"
  slot :inner_block, required: true

  def flash(assigns) do
    ~H"""
    <p
      id={@id}
      class={[
        "rounded-sm border px-3 py-2.5 text-sm",
        @class,
        @kind == "error" && "border-rust-400 bg-rust-50 text-danger-text",
        @kind == "info" && "border-slate-300 bg-slate-50 text-slate-800"
      ]}
    >
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  A code panel on the dark terminal ground. The content is rendered
  as is, so keep it on one line in the template.
  """
  attr :id, :string, default: nil
  attr :class, :string, default: "mt-3"
  slot :inner_block, required: true

  def code(assigns) do
    ~H"""
    <pre
      id={@id}
      class={[
        "overflow-x-auto rounded-md border border-terminal-line bg-terminal p-4 font-mono text-sm leading-code text-on-terminal",
        @class
      ]}
    ><code>{render_slot(@inner_block)}</code></pre>
    """
  end

  @doc "Numbered steps, each number in a quiet pill."
  slot :step, required: true

  def steps(assigns) do
    ~H"""
    <ol class="mt-5 flex flex-col gap-3.5">
      <li :for={{step, i} <- Enum.with_index(@step, 1)} class="flex items-start gap-3">
        <div class="mt-px flex size-5 flex-none items-center justify-center rounded-xs bg-sunken font-mono text-2xs font-medium text-strong">
          {i}
        </div>
        <div class="flex-1 min-w-0 leading-normal text-body">{render_slot(step)}</div>
      </li>
    </ol>
    """
  end
end
