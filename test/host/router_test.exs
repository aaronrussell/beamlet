defmodule Host.RouterTest do
  use Beamlet.Case

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias Beamlet.Code
  alias Beamlet.Define
  alias Beamlet.Patch
  alias Beamlet.Principal
  alias Beamlet.Routes

  setup %{token: token} do
    act_as(token)
    %{conn: build_conn(), principal: principal(token), base: Beamlet.TestEndpoint.url()}
  end

  # Targets go through the code server: Host.Router's authority for
  # "defined" is its manifest.
  defp define!(ctx, code, modules) do
    purge_on_exit(modules)
    {:ok, _summary} = Code.define([entry(code)], ctx.principal)
    :ok
  end

  defp live_source(ns) do
    """
    defmodule #{ns}.PageLive do
      use Host.Web, :live_view

      def mount(_params, _session, socket) do
        {:ok, assign(socket, count: 1)}
      end

      def render(assigns) do
        ~H"<div>page {@count}</div>"
      end
    end
    """
  end

  defp controller_source(ns) do
    """
    defmodule #{ns}.HookController do
      use Host.Web, :controller

      def create(conn, _params), do: send_resp(conn, 201, "created")
    end
    """
  end

  defp define_live!(ctx) do
    ns = unique_namespace()
    mod = Module.concat([ns, "PageLive"])
    define!(ctx, live_source(ns), [mod])
    mod
  end

  defp define_controller!(ctx, ns \\ unique_namespace()) do
    mod = Module.concat([ns, "HookController"])
    define!(ctx, controller_source(ns), [mod])
    mod
  end

  # A LiveView and a controller in one define, one compile and one
  # commit.
  defp define_live_and_controller!(ctx) do
    ns = unique_namespace()
    live = Module.concat([ns, "PageLive"])
    controller = Module.concat([ns, "HookController"])
    purge_on_exit([live, controller])

    {:ok, _summary} =
      Code.define([entry(live_source(ns)), entry(controller_source(ns))], ctx.principal)

    {live, controller}
  end

  # A module with the action's shape but no controller `use`;
  # `plug?: true` adds `init/1` and `call/2`, making it a hand-rolled plug.
  defp define_bare_show!(ctx, opts \\ []) do
    ns = unique_namespace()
    mod = Module.concat([ns, "Report"])

    plug_fns =
      if opts[:plug?] do
        """
          def init(opts), do: opts
          def call(conn, _opts), do: show(conn, conn.params)
        """
      else
        ""
      end

    define!(
      ctx,
      """
      defmodule #{ns}.Report do
        import Plug.Conn
      #{plug_fns}
        def show(conn, _params), do: send_resp(conn, 200, "report")
      end
      """,
      [mod]
    )

    mod
  end

  # Mounting and unmounting print; the output is returned for
  # assertions and otherwise kept out of the test run.
  defp quietly(fun), do: capture_io(fn -> assert fun.() == :ok end)

  # A wrongly typed argument is what a teaching error is for; the
  # compiler's type check must not see it coming.
  defp as_given(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))

  describe "mounting" do
    test "live/2 mounts a LiveView, printing the route and its URL", ctx do
      mod = define_live!(ctx)

      output = quietly(fn -> Host.Router.live("/rt/page", mod) end)

      assert output =~ "Mounted GET /rt/page — #{inspect(mod)}"
      assert output =~ "URL: #{ctx.base}/rt/page"

      assert [route] = Routes.list(path: "/rt/page")
      assert {:ok, ctx.principal} == Beamlet.Route.principal(route)
    end

    test "live/3 stores the live action", ctx do
      mod = define_live!(ctx)

      output = quietly(fn -> Host.Router.live("/rt/page/new", mod, :new) end)

      assert output =~ "Mounted GET /rt/page/new — #{inspect(mod)}, live_action: :new"
      assert [%{action: "new"}] = Routes.list(path: "/rt/page/new")
    end

    test "verb functions mount controller routes", ctx do
      mod = define_controller!(ctx)

      output = quietly(fn -> Host.Router.post("/rt/hooks", mod, :create) end)

      assert output =~ "Mounted POST /rt/hooks — #{inspect(mod)}, action: :create"
      assert output =~ "URL: #{ctx.base}/rt/hooks"

      assert [route] = Routes.list(path: "/rt/hooks")
      assert {:ok, ctx.principal} == Beamlet.Route.principal(route)
    end

    test "the root path is served at the base URL", ctx do
      mod = define_live!(ctx)

      output = quietly(fn -> Host.Router.live("/", mod) end)

      assert output =~ "Mounted GET / — #{inspect(mod)}"
      assert output =~ "URL: #{ctx.base}/\n"
    end

    @tag web: [prefix: "/app"]
    test "the printed URL carries the configured prefix", ctx do
      mod = define_live!(ctx)

      assert quietly(fn -> Host.Router.live("/rt/page", mod) end) =~
               "URL: #{ctx.base}/app/rt/page"

      assert quietly(fn -> Host.Router.live("/", mod) end) =~ "URL: #{ctx.base}/app\n"
    end

    test "a LiveView written against Phoenix.LiveView directly still mounts", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, "PlainLive"])

      define!(
        ctx,
        """
        defmodule #{ns}.PlainLive do
          use Phoenix.LiveView

          def render(assigns), do: ~H"<div>plain</div>"
        end
        """,
        [mod]
      )

      quietly(fn -> Host.Router.live("/rt/plain", mod) end)

      assert ctx.conn |> get("/rt/plain") |> html_response(200) =~ "plain"
    end

    test "a mount the router cannot build is taken back, and the mounted routes keep serving",
         ctx do
      {page, hook} = define_live_and_controller!(ctx)
      quietly(fn -> Host.Router.live("/rt/page", page) end)

      break_router_build()

      log =
        quiet(fn ->
          capture_log(fn ->
            assert_raise RuntimeError, ~r/could not mount \/rt\/hook/, fn ->
              Host.Router.post("/rt/hook", hook, :create)
            end
          end)
        end)

      assert log =~ "the router failed to regenerate"
      assert Routes.list(path: "/rt/hook") == []
      assert ctx.conn |> get("/rt/page") |> html_response(200) =~ "page 1"
    end
  end

  describe "redefining a routed module" do
    defp page_source(ns, body) do
      """
      defmodule #{ns}.PageLive do
        @moduledoc "A page."
        use Host.Web, :live_view

        @impl true
        def render(assigns) do
          ~H"<div>#{body}</div>"
        end
      end
      """
    end

    defp define_page!(ctx, ns, body) do
      purge_on_exit([Module.concat([ns, "PageLive"])])
      {:ok, _summary} = Define.run([%{code: page_source(ns, body), replace: true}], ctx.principal)
      Module.concat([ns, "PageLive"])
    end

    test "a module torn at boot and repaired by patch serves its route again", ctx do
      ns = unique_namespace()
      mod = define_page!(ctx, ns, "page one")
      quietly(fn -> Host.Router.live("/rt/torn", mod) end)

      {:ok, file} = Code.source_file(mod)
      path = Path.expand(file, Path.join(ctx.data_dir, "code"))

      File.write!(
        path,
        String.replace(File.read!(path), "~H\"<div>page one</div>\"", "~H\"<div>")
      )

      capture_log(fn ->
        quiet(fn ->
          :ok = Supervisor.terminate_child(Beamlet, Code)
          {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)
          assert :ignore = Routes.boot()
        end)
      end)

      assert [%{modules: [^mod]}] = Code.quarantined()
      assert ctx.conn |> get("/rt/torn") |> response(404)

      assert capture_io(&Host.Router.print_routes/0) =~
               "/rt/torn — #{inspect(mod)} (test) — not served"

      patch = %{module: inspect(mod), find: "~H\"<div>", replace: "~H\"<div>page two</div>\""}
      assert {:ok, _summary} = quiet(fn -> Patch.run([patch], ctx.principal) end)

      {:ok, _view, html} = live(ctx.conn, "/rt/torn")
      assert html =~ "page two"
      refute capture_io(&Host.Router.print_routes/0) =~ "not served"
    end

    test "a redefine that breaks a route drops it, and the fix brings it back", ctx do
      ns = unique_namespace()
      mod = define_page!(ctx, ns, "page one")
      quietly(fn -> Host.Router.live("/rt/shape", mod) end)

      plain = """
      defmodule #{ns}.PageLive do
        @moduledoc "No longer a page."

        @doc "Says hello."
        def hello, do: :hello
      end
      """

      capture_log(fn ->
        assert {:ok, _summary} = Define.run([%{code: plain, replace: true}], ctx.principal)
      end)

      assert ctx.conn |> get("/rt/shape") |> response(404)

      assert capture_io(&Host.Router.print_routes/0) =~
               "/rt/shape — #{inspect(mod)} (test) — not served"

      define_page!(ctx, ns, "page again")
      {:ok, _view, html} = live(ctx.conn, "/rt/shape")
      assert html =~ "page again"
    end

    test "a redefine leaves the router alone while every route stays as it was", ctx do
      ns = unique_namespace()
      mod = define_page!(ctx, ns, "page one")
      quietly(fn -> Host.Router.live("/rt/same", mod) end)

      server = Process.whereis(Code)
      :erlang.trace(server, true, [:receive])
      define_page!(ctx, ns, "page two")
      :erlang.trace(server, false, [:receive])

      refute_received {:trace, ^server, :receive,
                       {:"$gen_call", _from, {:compile_artifact, _source, _file}}}

      {:ok, _view, html} = live(ctx.conn, "/rt/same")
      assert html =~ "page two"
    end

    test "a define stands when the router fails to rebuild, with a warning", ctx do
      ns = unique_namespace()
      other_ns = unique_namespace()
      mod = Module.concat([ns, "PageLive"])
      other = Module.concat([other_ns, "PageLive"])
      purge_on_exit([mod, other])

      {:ok, _summary} =
        Define.run(
          [%{code: page_source(ns, "page one")}, %{code: page_source(other_ns, "other")}],
          ctx.principal
        )

      for {path, page} <- [{"/rt/kept", mod}, {"/rt/other", other}] do
        {:ok, _route} =
          Routes.create(%{
            kind: :live_view,
            path: path,
            module: inspect(page),
            principal: ctx.principal
          })
      end

      :ok = Routes.regenerate()
      break_router_build()

      plain = """
      defmodule #{ns}.PageLive do
        @moduledoc "No longer a page."

        @doc "Says hello."
        def hello, do: :hello
      end
      """

      log =
        capture_log(fn ->
          quiet(fn ->
            assert {:ok, summary} = Define.run([%{code: plain, replace: true}], ctx.principal)

            assert summary =~
                     "Warning: the router failed to rebuild, so your routes serve as they did " <>
                       "before this change"
          end)
        end)

      assert log =~ "the router failed to regenerate"
      assert mod.hello() == :hello
      assert ctx.conn |> get("/rt/other") |> html_response(200) =~ "other"
    end

    test "print_routes marks a servable route the router has not picked up", ctx do
      page = define_page!(ctx, unique_namespace(), "page one")

      {:ok, _route} =
        Routes.create(%{
          kind: :live_view,
          path: "/rt/late",
          module: inspect(page),
          principal: ctx.principal
        })

      assert capture_io(&Host.Router.print_routes/0) =~
               "/rt/late — #{inspect(page)} (test) — not served yet: the router was not " <>
                 "rebuilt after the last change; unmount it and mount it again"
    end
  end

  describe "mount validation" do
    test "raises without a principal" do
      Task.async(fn ->
        assert_raise RuntimeError, ~r/Host\.Router\.live works from eval/, fn ->
          Host.Router.live("/rt/x", Enum)
        end

        assert_raise RuntimeError, ~r/Host\.Router\.post works from eval/, fn ->
          Host.Router.post("/rt/x", Enum, :create)
        end
      end)
      |> Task.await()

      assert Routes.list() == []
    end

    test "refuses a module that is part of the beamlet" do
      assert_raise RuntimeError, ~r/Enum is part of your beamlet/, fn ->
        Host.Router.live("/rt/x", Enum)
      end
    end

    test "refuses a module that does not exist" do
      assert_raise RuntimeError, ~r/nothing named No\.Such exists on your beamlet/, fn ->
        Host.Router.get("/rt/x", No.Such, :show)
      end
    end

    test "refuses a quarantined module, pointing at its error", ctx do
      ns = unique_namespace()
      mod = define_page!(ctx, ns, "page one")

      {:ok, file} = Code.source_file(mod)
      path = Path.expand(file, Path.join(ctx.data_dir, "code"))

      File.write!(
        path,
        String.replace(File.read!(path), "~H\"<div>page one</div>\"", "~H\"<div>")
      )

      capture_log(fn ->
        quiet(fn ->
          :ok = Supervisor.terminate_child(Beamlet, Code)
          {:ok, _pid} = Supervisor.restart_child(Beamlet, Code)
        end)
      end)

      assert [%{modules: [^mod]}] = Code.quarantined()

      error = assert_raise RuntimeError, fn -> Host.Router.live("/rt/q", mod) end

      assert error.message ==
               "#{inspect(mod)} is quarantined — Host.Code.print_modules() shows its " <>
                 "error; patch it, then mount"

      assert Routes.list() == []
    end

    test "refuses something that is not a module" do
      assert_raise RuntimeError, ~r/Host\.Router mounts modules/, fn ->
        Host.Router.live("/rt/x", as_given("Todo.PageLive"))
      end
    end

    test "refuses a non-LiveView target for live/2", ctx do
      mod = define_controller!(ctx)

      assert_raise RuntimeError,
                   ~r/is not a LiveView — write it with `use Host.Web, :live_view`/,
                   fn -> Host.Router.live("/rt/x", mod) end
    end

    test "refuses a LiveView target for a verb function", ctx do
      mod = define_live!(ctx)

      assert_raise RuntimeError, ~r/is a LiveView — mount it with Host\.Router\.live/, fn ->
        Host.Router.get("/rt/x", mod, :show)
      end
    end

    test "refuses a module that is not a Phoenix controller", ctx do
      mod = define_bare_show!(ctx)

      error = assert_raise RuntimeError, fn -> Host.Router.get("/rt/report", mod, :show) end

      assert error.message =~ "#{inspect(mod)} is not a Phoenix controller"
      assert error.message =~ "`use Host.Web, :controller`"
      assert Routes.list(path: "/rt/report") == []
    end

    test "refuses a hand-rolled plug that is not a Phoenix controller", ctx do
      mod = define_bare_show!(ctx, plug?: true)

      error = assert_raise RuntimeError, fn -> Host.Router.get("/rt/report", mod, :show) end

      assert error.message =~ "#{inspect(mod)} is not a Phoenix controller"
      assert Routes.list(path: "/rt/report") == []
    end

    test "a controller written against Phoenix.Controller directly mounts", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, "Api"])

      define!(
        ctx,
        """
        defmodule #{ns}.Api do
          use Phoenix.Controller, formats: [:json]

          def show(conn, _params), do: json(conn, %{ok: true})
        end
        """,
        [mod]
      )

      quietly(fn -> Host.Router.get("/rt/api", mod, :show) end)

      assert %{status: 200, body: %{"ok" => true}} = Host.Router.call(:get, "/rt/api")
    end

    test "refuses a missing controller action", ctx do
      mod = define_controller!(ctx)

      assert_raise RuntimeError, ~r/does not export destroy\/2/, fn ->
        Host.Router.delete("/rt/x", mod, :destroy)
      end

      assert_raise RuntimeError, ~r/action must be an atom naming a function/, fn ->
        Host.Router.delete("/rt/x", mod, as_given("destroy"))
      end
    end

    test "refuses a non-string path and a malformed path", ctx do
      mod = define_live!(ctx)

      assert_raise RuntimeError, ~r/path must be a string starting with \//, fn ->
        Host.Router.live(:page, mod)
      end

      assert_raise RuntimeError, ~r/must be a string starting with \//, fn ->
        Host.Router.live("page", mod)
      end

      assert_raise RuntimeError, ~r/contain only letters, digits/, fn ->
        Host.Router.live("/rt/page?x", mod)
      end

      assert Routes.list() == []
    end

    test "refuses a path the router cannot route, with Phoenix's reason", ctx do
      mod = define_controller!(ctx)

      assert_raise RuntimeError, ~r{^/\*rest/more cannot be routed: .*glob}, fn ->
        Host.Router.post("/*rest/more", mod, :create)
      end

      assert Routes.list() == []
    end

    test "refuses a reserved first segment, with the convention", ctx do
      mod = Enum
      controller = define_controller!(ctx)

      error = assert_raise RuntimeError, fn -> Host.Router.live("/beamlet/pages", mod) end

      assert error.message =~ "first segment is beamlet are your beamlet's own"
      assert error.message =~ "(/beamlet/login, /beamlet/mcp)"
      assert error.message =~ "/beamlet/pages cannot be mounted"

      error =
        assert_raise RuntimeError, fn ->
          Host.Router.post("/~alice/notes", controller, :create)
        end

      assert error.message =~ "the path must start with / and contain only letters"
      assert error.message =~ "/~alice/notes"

      assert_raise RuntimeError, ~r/\/beamlet\/mcp cannot be mounted/, fn ->
        Host.Router.live("/beamlet/mcp", mod)
      end

      assert_raise RuntimeError, ~r/\/beamlet cannot be mounted/, fn ->
        Host.Router.live("/beamlet", mod)
      end

      assert_raise RuntimeError, ~r/\/\/beamlet\/admin cannot be mounted/, fn ->
        Host.Router.live("//beamlet/admin", mod)
      end

      assert Routes.list() == []
    end

    test "refuses an empty segment, naming the path it would be served at" do
      mod = Enum
      controller = Enum

      error = assert_raise RuntimeError, fn -> Host.Router.live("/rt//page", mod) end

      assert error.message =~ "paths have no empty segments"
      assert error.message =~ "/rt//page would be served at /rt/page. Use /rt/page"

      assert_raise RuntimeError, ~r/\/rt\/hooks\/ would be served at \/rt\/hooks\./, fn ->
        Host.Router.post("/rt/hooks/", controller, :create)
      end

      assert Routes.list() == []
    end

    test "an underscore anywhere, a leading one included, is an ordinary path", ctx do
      mod = define_live!(ctx)

      quietly(fn -> Host.Router.live("/my_notes/_drafts", mod) end)
      quietly(fn -> Host.Router.live("/x_/y", mod) end)
      quietly(fn -> Host.Router.live("/_admin/pages", mod) end)

      assert [_first, _second, _third] = Routes.list()
    end

    @tag web: [prefix: "/app"]
    test "refuses a path that begins with the prefix" do
      mod = Enum
      controller = Enum

      error = assert_raise RuntimeError, fn -> Host.Router.live("/app/rt/notes", mod) end

      assert error.message =~ "paths never include the prefix /app"
      assert error.message =~ "/app/rt/notes would be served at /app/app/rt/notes"
      assert error.message =~ "Use /rt/notes"
      assert error.message =~ ~s|~p"/rt/notes"|

      assert_raise RuntimeError, ~r/Use \/rt\/hooks/, fn ->
        Host.Router.post("/app/rt/hooks", controller, :create)
      end

      assert_raise RuntimeError, ~r/\/app would be served at \/app\/app\. Use \/;/, fn ->
        Host.Router.live("/app", mod)
      end

      assert Routes.list() == []
    end

    @tag web: [prefix: "/app"]
    test "a path sharing the prefix's letters but not its segment is allowed", ctx do
      mod = define_live!(ctx)

      assert quietly(fn -> Host.Router.live("/application", mod) end) =~
               "URL: #{ctx.base}/app/application"
    end

    test "with no prefix a path beginning with /app is an ordinary path", ctx do
      mod = define_live!(ctx)

      assert quietly(fn -> Host.Router.live("/app/rt/notes", mod) end) =~
               "Mounted GET /app/rt/notes"

      assert [_route] = Routes.list(path: "/app/rt/notes")
    end

    test "a conflict names the mounted route and its token", ctx do
      {mod, controller} = define_live_and_controller!(ctx)
      quietly(fn -> Host.Router.live("/rt/taken", mod) end)

      error =
        assert_raise RuntimeError, fn -> Host.Router.get("/rt/taken", controller, :create) end

      assert error.message =~
               "GET /rt/taken is already mounted — #{inspect(mod)}, mounted by test"

      assert error.message =~ "Unmount it first, or choose another path"

      quietly(fn -> Host.Router.post("/rt/taken", controller, :create) end)
      assert [_page, _hook] = Routes.list(path: "/rt/taken")
    end
  end

  describe "unmount/2" do
    test "unmounts every route at a path, printing each", ctx do
      {live_mod, controller} = define_live_and_controller!(ctx)
      quietly(fn -> Host.Router.live("/rt/both", live_mod) end)
      quietly(fn -> Host.Router.post("/rt/both", controller, :create) end)

      output = quietly(fn -> Host.Router.unmount("/rt/both") end)

      assert output =~ "Unmounted GET /rt/both — #{inspect(live_mod)}"
      assert output =~ "Unmounted POST /rt/both — #{inspect(controller)}, action: :create"
      assert Routes.list(path: "/rt/both") == []
      assert %{status: 404} = Host.Router.call(:get, "/rt/both")
    end

    test "verb: narrows to one route", ctx do
      {live_mod, controller} = define_live_and_controller!(ctx)
      quietly(fn -> Host.Router.live("/rt/both", live_mod) end)
      quietly(fn -> Host.Router.post("/rt/both", controller, :create) end)

      output = quietly(fn -> Host.Router.unmount("/rt/both", verb: :post) end)

      assert output =~ "Unmounted POST /rt/both"
      refute output =~ "Unmounted GET"
      assert [%{kind: :live_view}] = Routes.list(path: "/rt/both")
    end

    test "requires a principal", ctx do
      mod = define_live!(ctx)
      quietly(fn -> Host.Router.live("/rt/page", mod) end)

      Task.async(fn ->
        assert_raise RuntimeError, ~r/Host\.Router\.unmount works from eval/, fn ->
          Host.Router.unmount("/rt/page")
        end
      end)
      |> Task.await()

      assert [_route] = Routes.list(path: "/rt/page")
    end

    @tag web: [prefix: "/app"]
    test "rejects a prefixed path" do
      assert_raise RuntimeError, ~r/paths never include the prefix \/app/, fn ->
        Host.Router.unmount("/app/rt/page")
      end
    end

    test "rejects a reserved path" do
      assert_raise RuntimeError, ~r/\/beamlet\/mcp cannot be mounted/, fn ->
        Host.Router.unmount("/beamlet/mcp")
      end
    end

    test "raises when nothing is mounted at the path" do
      assert_raise RuntimeError, ~r/nothing is mounted at \/rt\/absent/, fn ->
        Host.Router.unmount("/rt/absent")
      end

      assert_raise RuntimeError, ~r/no POST route is mounted at \/rt\/absent/, fn ->
        Host.Router.unmount("/rt/absent", verb: :post)
      end
    end

    test "raises on an unknown verb or option" do
      assert_raise RuntimeError, ~r/unknown verb :fetch/, fn ->
        Host.Router.unmount("/rt/x", verb: :fetch)
      end

      assert_raise RuntimeError, ~r/unmount takes a verb option/, fn ->
        Host.Router.unmount("/rt/x", method: :post)
      end
    end
  end

  describe "path/1, url/1 and ~p" do
    import Host.Router, only: [sigil_p: 2]

    test "path/1 is the path itself with no prefix" do
      assert Host.Router.path("/notes") == "/notes"
      assert Host.Router.path("/") == "/"
      assert Host.Router.path("/notes?page=2") == "/notes?page=2"
    end

    @tag web: [prefix: "/app"]
    test "path/1 prepends the prefix" do
      assert Host.Router.path("/notes") == "/app/notes"
      assert Host.Router.path("/") == "/app"
      assert Host.Router.path("/notes?page=2") == "/app/notes?page=2"
    end

    test "url/1 is the base URL plus the browser path", ctx do
      assert Host.Router.url("/notes") == "#{ctx.base}/notes"
      assert Host.Router.url("/") == "#{ctx.base}/"
    end

    @tag web: [prefix: "/app"]
    test "url/1 carries the prefix", ctx do
      assert Host.Router.url("/notes") == "#{ctx.base}/app/notes"
      assert Host.Router.url("/") == "#{ctx.base}/app"
    end

    @tag web: [prefix: "/app"]
    test "both reject a prefixed or malformed path" do
      assert_raise RuntimeError, ~r/paths never include the prefix/, fn ->
        Host.Router.path("/app/notes")
      end

      assert_raise RuntimeError, ~r/paths never include the prefix/, fn ->
        Host.Router.url("/app/notes")
      end

      assert_raise RuntimeError, ~r/must be a string starting with \//, fn ->
        Host.Router.path("notes")
      end
    end

    test "both reject a reserved path" do
      assert_raise RuntimeError, ~r/\/beamlet\/assets\/app\.js cannot be mounted/, fn ->
        Host.Router.path("/beamlet/assets/app.js")
      end
    end

    test "path/1 needs no principal" do
      Task.async(fn -> assert Host.Router.path("/notes") == "/notes" end) |> Task.await()
    end

    @tag web: [prefix: "/app"]
    test "~p interpolates and maps through path/1" do
      id = 7

      assert ~p"/notes" == "/app/notes"
      assert ~p"/notes/#{id}/edit" == "/app/notes/7/edit"

      assert_raise RuntimeError, ~r/paths never include the prefix/, fn ->
        ~p"/app/notes"
      end
    end

    test "~p refuses a literal that is not a path, naming ~H" do
      error =
        assert_raise ArgumentError, fn ->
          Elixir.Code.eval_string(
            ~S|import Host.Router, only: [sigil_p: 2]; ~p"<div>hello</div>"|
          )
        end

      assert error.message =~ ~s|~p takes a route path starting with /, e.g. ~p"/todos"|
      assert error.message =~ ~s|got ~p"<div>hello</div>"|
      assert error.message =~ "A template is written with ~H, not ~p."
    end

    test "~p starting with an interpolation is checked at runtime" do
      path = "/notes"
      assert ~p"#{path}" == "/notes"

      path = "notes"

      assert_raise RuntimeError, ~r/must be a string starting with \//, fn -> ~p"#{path}" end
    end

    test "~p refuses modifiers" do
      assert_raise ArgumentError, ~r/~p takes no modifiers/, fn ->
        Elixir.Code.eval_string(~S|import Host.Router, only: [sigil_p: 2]; ~p"/notes"x|)
      end
    end
  end

  describe "print_routes/0" do
    test "prints teaching copy when nothing is mounted" do
      output = capture_io(&Host.Router.print_routes/0)

      assert output =~ "No routes are mounted"
      assert output =~ "Host.Router.live"
    end

    test "prints the base once, then verb, path, target, and token", ctx do
      {live_mod, controller} = define_live_and_controller!(ctx)
      quietly(fn -> Host.Router.live("/rt/page", live_mod) end)
      quietly(fn -> Host.Router.post("/rt/hooks", controller, :create) end)

      output = capture_io(&Host.Router.print_routes/0)

      assert output =~ "Paths are served at #{ctx.base}:\n"
      assert output =~ "GET    /rt/page — #{inspect(live_mod)} (test)"
      assert output =~ "POST   /rt/hooks — #{inspect(controller)}, action: :create (test)"
    end

    @tag web: [prefix: "/app"]
    test "states the prefix and keeps it out of the paths", ctx do
      mod = define_live!(ctx)
      quietly(fn -> Host.Router.live("/rt/page", mod) end)

      output = capture_io(&Host.Router.print_routes/0)

      assert output =~ "Paths are served under #{ctx.base}/app:\n"
      assert output =~ "GET    /rt/page"
      refute output =~ "/app/rt"
    end

    test "needs no principal", ctx do
      mod = define_live!(ctx)
      quietly(fn -> Host.Router.live("/rt/page", mod) end)

      Task.async(fn -> assert capture_io(&Host.Router.print_routes/0) =~ "/rt/page" end)
      |> Task.await()
    end

    test "annotates a route whose target is gone", ctx do
      {:ok, _route} =
        Routes.create(%{
          kind: :live_view,
          path: "/rt/ghost",
          module: "No.Such.Live",
          principal: ctx.principal
        })

      assert capture_io(&Host.Router.print_routes/0) =~
               "/rt/ghost — No.Such.Live (test) — not served: the target is missing"
    end

    test "shows a malformed row on one line, quoted, with the fields at fault" do
      Host.Repo.query!(
        "INSERT INTO __routes (kind, verb, path, module, principal, inserted_at) " <>
          "VALUES ('live_view', 'get', ?, 'My.PageLive', '{}', ?)",
        [~s|/x"\n  live "/y|, DateTime.to_iso8601(DateTime.utc_now(:second))]
      )

      output = capture_io(&Host.Router.print_routes/0)

      assert output =~
               ~s|GET    "/x\\"\\n  live \\"/y" — My.PageLive (an unknown token) — | <>
                 "not served: the row is malformed (path) " <>
                 "and is deleted the next time the router is built"
    end

    test "annotates a controller route whose target stopped being a controller", ctx do
      ns = unique_namespace()
      mod = define_controller!(ctx, ns)
      quietly(fn -> Host.Router.post("/rt/hooks", mod, :create) end)

      code = """
      defmodule #{ns}.HookController do
        import Plug.Conn

        def create(conn, _params), do: send_resp(conn, 201, "created")
      end
      """

      {:ok, _summary} = Code.define([entry(code, replace: true)], ctx.principal)

      assert capture_log(fn -> assert Routes.regenerate() == :ok end) =~ "not served"

      assert capture_io(&Host.Router.print_routes/0) =~
               "/rt/hooks — #{inspect(mod)}, action: :create (test) — not served"
    end
  end

  describe "call/4" do
    defp mount_fixture!(ctx, kind, verb, path, action) do
      {:ok, _route} =
        Routes.create(%{
          kind: kind,
          verb: verb,
          path: path,
          module: ctx.echo,
          action: action,
          principal: ctx.principal
        })

      :ok
    end

    setup ctx do
      fixtures = Beamlet.RouteFixtures.define!(ctx.principal)
      ctx = Map.merge(ctx, fixtures)

      mount_fixture!(ctx, :controller, :get, "/rt/echo", "show")
      mount_fixture!(ctx, :controller, :post, "/rt/echo", "create")
      mount_fixture!(ctx, :controller, :get, "/rt/text", "plain")
      mount_fixture!(ctx, :controller, :get, "/rt/crash", "crash")
      mount_fixture!(ctx, :controller, :get, "/rt/whoami", "whoami")

      {:ok, _route} =
        Routes.create(%{
          kind: :live_view,
          path: "/rt/hello/:id",
          module: ctx.hello,
          principal: ctx.principal
        })

      assert :ok = Routes.regenerate()
      fixtures
    end

    test "GET sends a map as the query string and decodes a JSON response" do
      response = Host.Router.call(:get, "/rt/echo", %{"limit" => "2"})

      assert response.status == 200
      assert response.headers["content-type"] =~ "application/json"
      assert response.body == %{"echo" => "show", "params" => %{"limit" => "2"}}
    end

    test "POST sends a map as a JSON body through the parser" do
      response = Host.Router.call(:post, "/rt/echo", %{"action" => "opened"})

      assert response.status == 200
      assert response.body["params"] == %{"action" => "opened"}
    end

    test "a string is the raw body, with the caller's headers" do
      response =
        Host.Router.call(:post, "/rt/echo", ~s({"raw": true}),
          headers: [{"Content-Type", "application/json"}]
        )

      assert response.body["params"] == %{"raw" => true}
    end

    test "a non-JSON body comes back as the raw string" do
      assert %{status: 200, body: "plain"} = Host.Router.call(:get, "/rt/text")
    end

    test "a LiveView page answers GET with its rendered HTML" do
      response = Host.Router.call(:get, "/rt/hello/7")

      assert response.status == 200
      assert response.headers["content-type"] =~ "text/html"
      assert response.body =~ "hello from HelloLive, id=7"
    end

    test "a miss is a 404 response, not an error" do
      assert %{status: 404} = Host.Router.call(:get, "/rt/nowhere")
    end

    test "the root path reaches the root route", ctx do
      {:ok, _route} =
        Routes.create(%{kind: :live_view, path: "/", module: ctx.hello, principal: ctx.principal})

      assert :ok = Routes.regenerate()

      assert %{status: 200, body: body} = Host.Router.call(:get, "/")
      assert body =~ "hello from HelloLive"
    end

    @tag web: [prefix: "/app"]
    test "the path is the mounted path, never the browser path" do
      assert %{status: 200} = Host.Router.call(:get, "/rt/text")

      assert_raise RuntimeError, ~r/paths never include the prefix \/app/, fn ->
        Host.Router.call(:get, "/app/rt/text")
      end
    end

    test "the route acts as nobody, and the caller's principal comes back after", ctx do
      assert Principal.current() == ctx.principal

      assert %{status: 200, body: %{"acting" => false}} = Host.Router.call(:get, "/rt/whoami")
      assert Principal.current() == ctx.principal

      assert_raise RuntimeError, fn -> Host.Router.call(:get, "/rt/crash") end
      assert Principal.current() == ctx.principal
    end

    test "a crashing route re-raises with the route's stacktrace", ctx do
      {error, stack} =
        try do
          Host.Router.call(:get, "/rt/crash")
        rescue
          error -> {error, __STACKTRACE__}
        end

      assert error.message == "GET /rt/crash crashed: ** (RuntimeError) boom"

      echo = Module.concat([ctx.echo])
      assert [{^echo, :crash, 2, _location} | _rest] = stack
      refute Enum.any?(stack, &match?({Beamlet.TestEndpoint, _fun, _arity, _loc}, &1))
    end

    test "leaves no adapter messages behind" do
      _response = Host.Router.call(:get, "/rt/echo")
      assert_raise RuntimeError, fn -> Host.Router.call(:get, "/rt/crash") end

      refute_received {:plug_conn, :sent}
      refute_received {_ref, {_status, _headers, _body}}
    end

    test "teaches the verb set, the path form, and the data shapes" do
      assert_raise RuntimeError, ~r/verb must be one of :get, :post/, fn ->
        Host.Router.call(:live, "/rt/echo")
      end

      assert_raise RuntimeError, ~r/must be a string starting with \//, fn ->
        Host.Router.call(:get, "rt/echo")
      end

      assert_raise RuntimeError, ~r/\/beamlet\/mcp cannot be mounted/, fn ->
        Host.Router.call(:post, "/beamlet/mcp")
      end

      assert_raise RuntimeError, ~r/data must be a map or a string/, fn ->
        Host.Router.call(:post, "/rt/echo", as_given([1, 2]))
      end

      assert_raise RuntimeError, ~r/headers must be name\/value string pairs/, fn ->
        Host.Router.call(:get, "/rt/echo", nil, headers: %{"x" => 1})
      end

      assert_raise RuntimeError, ~r/call takes a headers option/, fn ->
        Host.Router.call(:get, "/rt/echo", nil, query: %{})
      end
    end
  end

  describe "end to end through the endpoint" do
    test "a defined LiveView mounts, serves, and unmounts", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, "PageLive"])

      define!(
        ctx,
        """
        defmodule #{ns}.PageLive do
          use Host.Web, :live_view

          def render(assigns) do
            ~H"<div>e2e page, action {inspect(@live_action)}</div>"
          end
        end
        """,
        [mod]
      )

      quietly(fn -> Host.Router.live("/e2e/page", mod, :show) end)
      public = Host.Router.path("/e2e/page")
      assert public == "/e2e/page"

      {:ok, _view, html} = live(ctx.conn, public)
      assert html =~ "e2e page, action :show"

      quietly(fn -> Host.Router.unmount("/e2e/page") end)
      assert ctx.conn |> get(public) |> response(404)
    end

    @tag web: [prefix: "/app"]
    test "a LiveView under a prefix serves at its browser path", ctx do
      mod = define_live!(ctx)

      quietly(fn -> Host.Router.live("/e2e/page", mod) end)
      public = Host.Router.path("/e2e/page")
      assert public == "/app/e2e/page"

      {:ok, _view, html} = live(ctx.conn, public)
      assert html =~ "page 1"
      assert ctx.conn |> get("/e2e/page") |> response(404)
    end

    test "a defined controller mounts and answers its verb only", ctx do
      mod = define_controller!(ctx)

      quietly(fn -> Host.Router.post("/e2e/hooks", mod, :create) end)

      assert ctx.conn |> post("/e2e/hooks") |> response(201) == "created"
      assert ctx.conn |> get("/e2e/hooks") |> response(404)
    end

    test "Host.File works inside a served route's own process", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, "StoreController"])

      define!(
        ctx,
        """
        defmodule #{ns}.StoreController do
          use Host.Web, :controller

          def create(conn, params) do
            Host.File.write!("hooks/#{ns}.json", JSON.encode!(params))
            send_resp(conn, 201, "stored")
          end
        end
        """,
        [mod]
      )

      quietly(fn -> Host.Router.post("/e2e/store", mod, :create) end)

      assert ctx.conn
             |> put_req_header("content-type", "application/json")
             |> post("/e2e/store", JSON.encode!(%{note: "hi"}))
             |> response(201) == "stored"

      assert Host.File.read!("hooks/#{ns}.json") =~ "hi"
    end

    test "a served route has no principal: Host.Code raises as it would in a browser", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, "AdminController"])

      define!(
        ctx,
        """
        defmodule #{ns}.AdminController do
          use Host.Web, :controller

          def show(conn, _params) do
            Host.Code.print_modules()
            send_resp(conn, 200, "listed")
          end
        end
        """,
        [mod]
      )

      quietly(fn -> Host.Router.get("/e2e/admin", mod, :show) end)

      # Phoenix.ConnTest dispatches in the calling process; a browser's
      # request runs in a process with no principal, like this task.
      Task.async(fn ->
        assert_raise RuntimeError, ~r/Host\.Code\.print_modules works from eval/, fn ->
          get(ctx.conn, "/e2e/admin")
        end
      end)
      |> Task.await()

      assert_raise RuntimeError, ~r/Host\.Code\.print_modules works from eval/, fn ->
        Host.Router.call(:get, "/e2e/admin")
      end
    end

    test "a LiveView subscribed through Host.PubSub re-renders on a broadcast", ctx do
      ns = unique_namespace()
      mod = Module.concat([ns, "FeedLive"])
      topic = "e2e:#{ns}"

      define!(
        ctx,
        """
        defmodule #{ns}.FeedLive do
          use Host.Web, :live_view

          def mount(_params, _session, socket) do
            if connected?(socket), do: Host.PubSub.subscribe("#{topic}")
            {:ok, assign(socket, latest: "nothing yet")}
          end

          def handle_info({:note_saved, text}, socket) do
            {:noreply, assign(socket, latest: text)}
          end

          def render(assigns) do
            ~H"<div>latest: {@latest}</div>"
          end
        end
        """,
        [mod]
      )

      quietly(fn -> Host.Router.live("/e2e/feed", mod) end)

      {:ok, view, html} = live(ctx.conn, "/e2e/feed")
      assert html =~ "latest: nothing yet"

      assert Host.PubSub.broadcast(topic, {:note_saved, "hello from the hook"}) == :ok
      assert render(view) =~ "latest: hello from the hook"
    end
  end
end
