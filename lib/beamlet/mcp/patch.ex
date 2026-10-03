defmodule Beamlet.MCP.Patch do
  @moduledoc """
  The `patch` tool: targeted edits to the source of modules defined on
  a beamlet.

  Each use takes a list of patches. A patch names a module, an anchor
  and an operation. The anchor is `find`, text occurring exactly once
  in the module's source, or `select`, a function as `name/arity`
  with its `@doc` and `@spec`; the operation is `replace`, `before` or
  `after`. The patches apply in order, then the touched modules go
  through everything `define` does, as one change: scanned, checked
  for docs, compiled with the modules that depend on them and
  committed to the code dir's history (`Beamlet.MCP.Define`). On any
  error nothing changes.

  `patch` comes with `define`: a policy listing `:define` under
  `tools` grants both (`Beamlet.Policy`). It shares define's
  `timeout` (`Beamlet.MCP.Define`).
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias Beamlet.MCP.Server
  alias Beamlet.Patch

  @keys [:module, :find, :select, :replace, :before, :after]

  schema do
    embeds_many :patches, required: true, description: "The patches to apply, in order" do
      field(:module, {:required, :string}, description: "The module to edit, like Shopping.List")

      field(:find, :string,
        description:
          "Anchor: text occurring exactly once in the module's current source. " <>
            "One anchor per patch, find or select."
      )

      field(:select, :string,
        description:
          "Anchor: a function as name/arity, all its clauses with the @doc and @spec " <>
            "above them. One anchor per patch, find or select."
      )

      field(:replace, :string,
        description:
          "Operation: text replacing the anchor, empty to remove it. " <>
            "One operation per patch: replace, before or after."
      )

      field(:before, :string,
        description:
          "Operation: text inserted before the anchor. " <>
            "One operation per patch: replace, before or after."
      )

      field(:after, :string,
        description:
          "Operation: text inserted after the anchor. " <>
            "One operation per patch: replace, before or after."
      )
    end
  end

  @doc """
  The description a client lists for the tool, written for the model.

  Built when it is read, from define's `timeout`, so it always states
  the one in force.
  """
  @impl true
  def description do
    limits = Beamlet.Config.define()

    """
    Patch modules on your beamlet: targeted edits to their source.

    Each patch names a module, an anchor and an operation. The anchor is
    `find`, text occurring exactly once in the module's current source, or
    `select`, a function as `name/arity`: all its clauses and the `@doc`
    and `@spec` above them. The operation is `replace`, empty to remove,
    or `before` or `after`, code inserted around the anchor. All patches
    apply as one transaction, in order: the modules recompile together
    with their dependents, and on any error nothing changes. Source is
    stored formatted.

    Read before you patch: `Host.Code.print_outline(Mod)` for the shape
    and the `name/arity` spellings, `print_source(Mod, fun, arity)` or a
    line range for exact text to quote. Define's rules hold for the
    result: public functions documented, your policy applied, a function
    another module still calls not dropped. A patch stops after
    #{Server.seconds(limits[:timeout])}.
    """
  end

  @impl true
  def execute(%{patches: patches}, frame) do
    with :ok <- Server.authorize("patch", frame) do
      patches =
        Enum.map(patches, fn patch ->
          patch |> Map.take(@keys) |> Map.reject(fn {_key, value} -> is_nil(value) end)
        end)

      case Patch.run(patches, frame.assigns.principal) do
        {:ok, text} -> {:reply, Response.text(Response.tool(), text), frame}
        {:error, text} -> {:reply, Response.error(Response.tool(), text), frame}
      end
    end
  end
end
