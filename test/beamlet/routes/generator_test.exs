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

  test "an empty route list renders a router with both scopes and no routes" do
    source = Generator.source([], "")

    assert source =~ "defmodule Beamlet.DynamicRouter do"
    assert source =~ "use Phoenix.Router, helpers: false"
    assert source =~ ~s(scope "/" do)
    refute source =~ "live \""
    refute source =~ "get \""
  end

  test "live_view rows render live lines in the browser scope" do
    source = Generator.source([live_route("/hello/:id", "My.HelloLive")], "")

    assert source =~ ~s(live "/hello/:id", My.HelloLive)
    assert source =~ ~s(put_root_layout, html: {Beamlet.Layouts, :root})
    assert source =~ "plug :protect_from_forgery"
  end

  test "a live_view row with a live action renders the three-argument live line" do
    route = %Route{
      kind: :live_view,
      verb: :get,
      path: "/todos/new",
      module: "My.TodoLive",
      action: "new"
    }

    assert Generator.source([route], "") =~ ~s(live "/todos/new", My.TodoLive, :new)
  end

  test "controller rows render verb lines in the api scope" do
    source =
      Generator.source([controller_route(:post, "/hooks", "My.HookController", "create")], "")

    assert source =~ ~s(post "/hooks", My.HookController, :create)
    assert source =~ ~s(plug :accepts, ["json"])
  end

  test "a prefix becomes the scope path" do
    assert Generator.source([], "/pages") =~ ~s(scope "/pages" do)
  end

  test "row order is preserved" do
    source =
      Generator.source([live_route("/a/new", "My.ALive"), live_route("/a/:id", "My.BLive")], "")

    {new_at, _} = :binary.match(source, ~s(live "/a/new"))
    {id_at, _} = :binary.match(source, ~s(live "/a/:id"))
    assert new_at < id_at
  end

  test "the rendered source parses as one module" do
    source =
      Generator.source(
        [
          live_route("/hello/:id", "Beamlet.RouteFixtures.HelloLive"),
          controller_route(:get, "/echo", "Beamlet.RouteFixtures.EchoController", "show")
        ],
        "/app"
      )

    assert {:ok, {:defmodule, _meta, _args}} = Code.string_to_quoted(source)
  end
end
