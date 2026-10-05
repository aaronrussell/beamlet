defmodule Beamlet.RoutesTest do
  use Beamlet.Case

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Plug.Conn
  import Phoenix.LiveViewTest

  alias Beamlet.Owner
  alias Beamlet.Route
  alias Beamlet.RouteFixtures
  alias Beamlet.Routes

  setup %{token: token} do
    principal = principal(token)

    %{
      conn: build_conn(),
      principal: principal,
      live_attrs: %{
        kind: :live_view,
        path: "/hello/:id",
        module: "My.HelloLive",
        principal: principal
      },
      controller_attrs: %{
        kind: :controller,
        verb: :post,
        path: "/hooks",
        module: "My.HookController",
        action: "create",
        principal: principal
      }
    }
  end

  defp add_hello!(ctx, path \\ "/hello/:id") do
    {:ok, route} = Routes.create(%{ctx.live_attrs | path: path})
    route
  end

  defp add_echo!(ctx, verb, action, path \\ "/echo") do
    {:ok, route} =
      Routes.create(%{
        kind: :controller,
        verb: verb,
        path: path,
        module: ctx.echo,
        action: action,
        principal: ctx.principal
      })

    route
  end

  describe "create/1" do
    test "forces :get on a live_view route regardless of input", ctx do
      assert {:ok, %Route{verb: :get}} = Routes.create(Map.put(ctx.live_attrs, :verb, :post))
    end

    test "refuses a path Phoenix would refuse", ctx do
      assert {:error, changeset} = Routes.create(%{ctx.live_attrs | path: "/*rest/more"})
      assert %{path: [message]} = errors_on(changeset)
      assert message =~ "glob"
    end

    test "inserts a controller route with verb and action", ctx do
      assert {:ok, %Route{verb: :post, action: "create"}} = Routes.create(ctx.controller_attrs)
    end

    test "records the mounting principal as provenance, and the time", ctx do
      assert {:ok, %Route{} = route} = Routes.create(ctx.live_attrs)

      assert route.principal == Beamlet.Principal.to_map(ctx.principal)
      assert {:ok, decoded} = Route.principal(route)
      assert decoded == ctx.principal
      assert %DateTime{} = route.inserted_at

      assert [%Route{principal: %{"token" => %{"label" => "test"}}}] = Routes.list()
    end

    test "requires a principal", ctx do
      assert {:error, changeset} = Routes.create(Map.delete(ctx.live_attrs, :principal))
      assert %{principal: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts a live action on a live_view route", ctx do
      assert {:ok, %Route{action: "new"}} =
               Routes.create(Map.put(ctx.live_attrs, :action, "new"))
    end

    test "rejects a malformed live action", ctx do
      assert {:error, changeset} =
               Routes.create(Map.put(ctx.live_attrs, :action, "New Thing"))

      assert %{action: [_message]} = errors_on(changeset)
    end

    test "requires verb and action on a controller route", ctx do
      assert {:error, changeset} =
               Routes.create(%{
                 kind: :controller,
                 path: "/x",
                 module: "My.C",
                 principal: ctx.principal
               })

      assert %{verb: [_verb], action: [_action]} = errors_on(changeset)
    end

    test "rejects a duplicate verb and path", ctx do
      assert {:ok, _route} = Routes.create(ctx.controller_attrs)
      assert {:error, changeset} = Routes.create(ctx.controller_attrs)
      assert %{path: ["has already been taken"]} = errors_on(changeset)
    end

    test "a live_view collides with a controller get at the same path", ctx do
      assert {:ok, _route} = Routes.create(ctx.live_attrs)

      assert {:error, changeset} =
               Routes.create(%{
                 kind: :controller,
                 verb: :get,
                 path: "/hello/:id",
                 module: "My.C",
                 action: "show",
                 principal: ctx.principal
               })

      assert %{path: ["has already been taken"]} = errors_on(changeset)
    end

    test "differing verbs coexist at one path", ctx do
      assert {:ok, _get} = Routes.create(%{ctx.controller_attrs | verb: :get, action: "show"})
      assert {:ok, _post} = Routes.create(ctx.controller_attrs)
    end

    test "rejects malformed paths", ctx do
      for path <- ["hello", ~s(/he"llo), "/he llo", "/hello\nx"] do
        assert {:error, changeset} = Routes.create(%{ctx.live_attrs | path: path})
        assert %{path: ["has invalid format"]} = errors_on(changeset)
      end
    end

    test "rejects malformed module strings", ctx do
      for module <- ["hello", "My..Mod", ~s(My.Mod"), "My.Mod x"] do
        assert {:error, changeset} = Routes.create(%{ctx.live_attrs | module: module})
        assert %{module: ["has invalid format"]} = errors_on(changeset)
      end
    end

    test "rejects malformed actions", ctx do
      assert {:error, changeset} =
               Routes.create(%{ctx.controller_attrs | action: "Create!()"})

      assert %{action: ["has invalid format"]} = errors_on(changeset)
    end
  end

  describe "list/1 and delete/1" do
    test "lists rows in id order", ctx do
      {:ok, first} = Routes.create(ctx.live_attrs)
      {:ok, second} = Routes.create(ctx.controller_attrs)

      assert [%Route{id: id1}, %Route{id: id2}] = Routes.list()
      assert {id1, id2} == {first.id, second.id}
    end

    test "narrows by path, verb and modules", ctx do
      {:ok, page} = Routes.create(ctx.live_attrs)
      {:ok, hook} = Routes.create(ctx.controller_attrs)
      {:ok, show} = Routes.create(%{ctx.controller_attrs | verb: :get, action: "show"})

      assert [^hook, ^show] = Routes.list(path: "/hooks")
      assert [^show] = Routes.list(path: "/hooks", verb: :get)
      assert [^page] = Routes.list(modules: ["My.HelloLive", "No.Such"])
      assert [] = Routes.list(modules: [])
    end

    test "deletes a row", ctx do
      {:ok, route} = Routes.create(ctx.live_attrs)
      assert :ok = Routes.delete(route)
      assert Routes.list() == []
    end
  end

  describe "the generated router" do
    setup ctx do
      %{hello: hello, echo: echo} = RouteFixtures.define!(ctx.principal)
      %{hello: hello, echo: echo, live_attrs: %{ctx.live_attrs | module: hello}}
    end

    test "the empty generation 404s everything under the forward", %{conn: conn} do
      assert conn |> get("/anything") |> response(404) ==
               "Not Found. Nothing is mounted at this path; your beamlet has its own pages at /beamlet."

      assert conn
             |> put_req_header("accept", "application/json")
             |> get("/anything")
             |> json_response(404) == %{"errors" => %{"detail" => "Not Found"}}
    end

    test "a live_view route serves through the forward with URL params", ctx do
      add_hello!(ctx)
      assert :ok = Routes.regenerate()

      {:ok, _view, html} = live(ctx.conn, "/hello/7")
      assert html =~ "hello from HelloLive"
      assert html =~ "id=7"
    end

    test "an agent page renders in the agent layout, styled from the CDN, on a canvas for both modes",
         ctx do
      add_hello!(ctx)
      assert :ok = Routes.regenerate()

      html = ctx.conn |> get("/hello/7") |> html_response(200)

      assert html =~ ~s(new LiveSocket("/beamlet/agent/live")
      assert html =~ "cdn.jsdelivr.net/npm/@tailwindcss/browser"
      assert html =~ ~r/<body class="[^"]*\bbg-[^"]*\bdark:bg-/
      refute html =~ "/beamlet/app/live"
      refute html =~ "/beamlet/assets/app.css"
    end

    test "a live action reaches the page", ctx do
      {:ok, _route} = Routes.create(Map.put(ctx.live_attrs, :action, "edit"))
      assert :ok = Routes.regenerate()

      {:ok, _view, html} = live(ctx.conn, "/hello/1")
      assert html =~ "action :edit"
    end

    test "controller routes serve with query and body params; a wrong verb 404s", ctx do
      add_echo!(ctx, :get, "show")
      add_echo!(ctx, :post, "create")
      assert :ok = Routes.regenerate()

      assert %{"echo" => "show", "params" => %{"x" => "1"}} =
               ctx.conn |> get("/echo?x=1") |> json_response(200)

      assert %{"echo" => "create", "params" => %{"y" => 2}} =
               ctx.conn
               |> put_req_header("content-type", "application/json")
               |> post("/echo", JSON.encode!(%{y: 2}))
               |> json_response(200)

      assert ctx.conn |> put("/echo") |> response(404)
    end

    test "a form posting _method reaches a delete mount", ctx do
      add_echo!(ctx, :delete, "create")
      assert :ok = Routes.regenerate()

      assert %{"echo" => "create", "params" => %{"_method" => "delete", "z" => "3"}} =
               ctx.conn
               |> put_req_header("content-type", "application/x-www-form-urlencoded")
               |> post("/echo", "_method=delete&z=3")
               |> json_response(200)
    end

    test "a removed route 404s after regeneration while survivors serve", ctx do
      add_hello!(ctx)
      echo = add_echo!(ctx, :get, "show")
      assert :ok = Routes.regenerate()
      assert ctx.conn |> get("/echo") |> json_response(200)

      assert :ok = Routes.delete(echo)
      assert :ok = Routes.regenerate()

      assert ctx.conn |> get("/echo") |> response(404)
      {:ok, _view, _html} = live(ctx.conn, "/hello/1")
    end

    test "a route with a missing target is left out with a warning; the rest serve", ctx do
      add_hello!(ctx)
      {:ok, ghost} = Routes.create(%{ctx.live_attrs | path: "/ghost", module: "No.Such.Module"})

      log = capture_log(fn -> assert :ok = Routes.regenerate() end)

      assert log =~ "GET /ghost is not served: No.Such.Module is not a module defined with define"
      refute Routes.servable?(ghost)
      assert ctx.conn |> get("/ghost") |> response(404)
      {:ok, _view, _html} = live(ctx.conn, "/hello/1")
      assert [_hello, ^ghost] = Routes.list()
    end

    test "a live_view route targeting a non-LiveView is left out", ctx do
      {:ok, _route} = Routes.create(%{ctx.live_attrs | path: "/wrong", module: ctx.echo})

      log = capture_log(fn -> assert :ok = Routes.regenerate() end)

      assert log =~ "GET /wrong is not served"
      assert ctx.conn |> get("/wrong") |> response(404)
    end

    test "a controller route whose action is not exported is left out", ctx do
      route = add_echo!(ctx, :get, "missing")

      refute Routes.servable?(route)
      assert capture_log(fn -> assert :ok = Routes.regenerate() end) =~ "GET /echo is not served"
      assert ctx.conn |> get("/echo") |> response(404)
    end

    test "boot/0 regenerates from the table and returns :ignore", ctx do
      add_hello!(ctx)
      assert :ignore = Routes.boot()
      {:ok, _view, _html} = live(ctx.conn, "/hello/3")
    end

    test "a module not defined with define is left out, however well it fits", ctx do
      {:ok, route} =
        Routes.create(%{ctx.live_attrs | path: "/home", module: "Beamlet.Web.HomeLive"})

      refute Routes.servable?(route)

      assert capture_log(fn -> assert :ok = Routes.regenerate() end) =~
               "GET /home is not served: Beamlet.Web.HomeLive is not a module defined with define"

      assert ctx.conn |> get("/home") |> response(404)
    end

    test "a broken generation is contained: boot logs and the previous router serves", ctx do
      add_hello!(ctx)
      assert :ok = Routes.regenerate()

      break_router_build()
      log = quiet(fn -> capture_log(fn -> assert :ignore = Routes.boot() end) end)

      assert log =~ "the router failed to regenerate"
      {:ok, _view, _html} = live(ctx.conn, "/hello/1")
    end

    test "a host route wins over a route mounted at the same path", ctx do
      add_echo!(ctx, :get, "show", "/host/ping")
      assert :ok = Routes.regenerate()

      assert ctx.conn |> get("/host/ping") |> response(200) == "pong"
    end

    @tag web: [prefix: "/pages"]
    test "a configured prefix serves the routes under it", ctx do
      add_hello!(ctx)
      add_echo!(ctx, :get, "show")
      assert :ok = Routes.regenerate()

      {:ok, _view, html} = live(ctx.conn, "/pages/hello/2")
      assert html =~ "id=2"
      assert ctx.conn |> get("/pages/echo") |> json_response(200)
      assert ctx.conn |> get("/hello/2") |> response(404)
    end

    test "an agent route writing a live session secret to its session signs nobody in to the app",
         ctx do
      add_echo!(ctx, :get, "session", "/door")
      assert :ok = Routes.regenerate()
      {:ok, session} = Owner.create_session()

      conn = get(ctx.conn, "/door", session_secret: session.secret)
      assert json_response(conn, 200) == %{"session_secret" => session.secret}

      assert conn |> get("/beamlet") |> redirected_to() == "/beamlet/login"
    end

    test "a browser signed in to the app brings no app session to an agent route", ctx do
      add_echo!(ctx, :get, "session", "/peek")
      assert :ok = Routes.regenerate()

      conn =
        post(ctx.conn, "/beamlet/login", user: %{email: ctx.user.email, password: ctx.password})

      assert conn |> get("/beamlet") |> html_response(200) =~ "Signed in as owner@example.com."

      assert conn |> get("/peek") |> json_response(200) == %{}
    end

    test "a row naming a never-seen module or action makes no atom and answers 404", ctx do
      ns = unique_namespace()
      module = "#{ns}.Never"
      action = "never_#{System.unique_integer([:positive])}"
      {:ok, _ghost} = Routes.create(%{ctx.live_attrs | path: "/never", module: module})
      echo = add_echo!(ctx, :get, action, "/never/action")

      log = capture_log(fn -> assert :ok = Routes.regenerate() end)

      assert log =~ "GET /never is not served"
      refute Routes.servable?(echo)
      assert_raise ArgumentError, fn -> String.to_existing_atom("Elixir." <> module) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(action) end
      assert ctx.conn |> get("/never") |> response(404)
      assert ctx.conn |> get("/never/action") |> response(404)
    end

    test "an earlier mount wins an overlapping match, whatever its kind", ctx do
      add_echo!(ctx, :get, "show", "/items/:id")
      add_hello!(ctx, "/items/new")
      add_hello!(ctx, "/pages/new")
      add_echo!(ctx, :get, "show", "/pages/:id")
      assert :ok = Routes.regenerate()

      assert %{"echo" => "show", "params" => %{"id" => "new"}} =
               ctx.conn |> get("/items/new") |> json_response(200)

      {:ok, _view, html} = live(ctx.conn, "/pages/new")
      assert html =~ "hello from HelloLive"
      assert %{"echo" => "show"} = ctx.conn |> get("/pages/1") |> json_response(200)
    end

    test "served?/1 is what the router in the VM holds", ctx do
      route = add_hello!(ctx)
      assert Routes.servable?(route)
      refute Routes.served?(route)

      assert :ok = Routes.regenerate()
      assert Routes.served?(route)

      {:ok, moved} = route |> Ecto.Changeset.change(path: "/moved") |> Beamlet.Repo.update()
      refute Routes.served?(moved)
    end

    test "refresh/0 rebuilds only when the router and the table disagree", ctx do
      {:ok, _ghost} = Routes.create(%{ctx.live_attrs | path: "/ghost", module: "No.Such.Module"})
      assert capture_log(fn -> assert :ok = Routes.refresh() end) == ""

      add_hello!(ctx)
      log = capture_log(fn -> assert :ok = Routes.refresh() end)

      assert log =~ "GET /ghost is not served"
      {:ok, _view, _html} = live(ctx.conn, "/hello/1")
      assert capture_log(fn -> assert :ok = Routes.refresh() end) == ""
    end

    test "regenerate compiles the table as it stands when the compile runs", ctx do
      server = Process.whereis(Beamlet.Code)
      :erlang.trace(server, true, [:receive])
      :ok = :sys.suspend(server)

      add_hello!(ctx, "/first")
      task = Task.async(&Routes.regenerate/0)

      assert_receive {:trace, ^server, :receive,
                      {:"$gen_call", _from, {:compile_artifact, _source, _file}}}

      :erlang.trace(server, false, [:receive])

      add_hello!(ctx, "/second")
      :ok = :sys.resume(server)
      assert :ok = Task.await(task)

      assert Enum.map(Beamlet.DynamicRouter.__routes__(), & &1.path) == ["/first", "/second"]
    end
  end
end
