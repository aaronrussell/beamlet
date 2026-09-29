defmodule Beamlet.Routes.GeneratorTest do
  use ExUnit.Case, async: true

  alias Beamlet.Route
  alias Beamlet.Routes.Generator

  defp live_route(path, module) do
    %Route{kind: :live_view, verb: :get, path: path, module: module}
  end

  defp controller_route(verb, path, module, action) do
    %Route{kind: :controller, verb: verb, path: path, module: module, action: action}
  end

  defp source(routes, prefix), do: routes |> Generator.quoted(prefix) |> Macro.to_string()

  defp calls(quoted, name) do
    {_quoted, calls} =
      Macro.prewalk(quoted, [], fn
        {^name, _meta, args} = node, acc when is_list(args) -> {node, [args | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(calls)
  end

  test "an empty route list builds a router with both scopes and no routes" do
    source = source([], "")

    assert source =~ "defmodule Beamlet.DynamicRouter do"
    assert source =~ "use Phoenix.Router, helpers: false"
    assert source =~ ~s|scope("/") do|
    refute source =~ "live("
    refute source =~ "get("
  end

  test "live_view rows become live lines in the browser scope" do
    source = source([live_route("/hello/:id", "My.HelloLive")], "")

    assert source =~ ~s|live("/hello/:id", My.HelloLive)|
    assert source =~ ~s|put_root_layout, html: {Beamlet.Web.Layouts, :beamlet}|
    assert source =~ "plug(:protect_from_forgery)"
  end

  test "a live_view row with a live action becomes the three-argument live line" do
    route = %Route{
      kind: :live_view,
      verb: :get,
      path: "/todos/new",
      module: "My.TodoLive",
      action: "new"
    }

    assert source([route], "") =~ ~s|live("/todos/new", My.TodoLive, :new)|
  end

  test "controller rows become verb lines in the api scope" do
    source = source([controller_route(:post, "/hooks", "My.HookController", "create")], "")

    assert source =~ ~s|post("/hooks", My.HookController, :create)|
    assert source =~ ~s|plug(:accepts, ["json"])|
  end

  test "a prefix becomes the scope path" do
    assert source([], "/pages") =~ ~s|scope("/pages") do|
  end

  test "row order is preserved" do
    quoted =
      Generator.quoted([live_route("/a/new", "My.ALive"), live_route("/a/:id", "My.BLive")], "")

    assert [["/a/new", My.ALive], ["/a/:id", My.BLive]] = calls(quoted, :live)
  end

  test "a path is a string argument, whatever it holds" do
    path = ~s|/x", My.OtherLive\n    :persistent_term.put(:pwned, true)\n    live "/y|

    quoted = Generator.quoted([live_route(path, "My.HelloLive")], "")

    assert [[^path, My.HelloLive]] = calls(quoted, :live)
    refute Macro.to_string(quoted) =~ ~r/^\s*:persistent_term/m
  end
end
