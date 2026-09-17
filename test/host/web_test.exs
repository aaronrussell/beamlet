defmodule Host.WebTest do
  # Defined modules and the dynamic router are VM-global, so nothing
  # here can run async.
  use Beamlet.Case, async: false

  import ExUnit.CaptureIO

  alias Beamlet.Code
  alias Beamlet.Define

  setup %{token: token} do
    act_as(token)
    %{principal: principal(token)}
  end

  defp define!(ctx, code, modules) do
    purge_on_exit(modules)
    {:ok, _summary} = Code.define(code, modules, false, ctx.principal)
    :ok
  end

  defp mount!(fun), do: capture_io(fn -> assert fun.() == :ok end)

  test "a :live_view page links through ~p and renders its :html components", ctx do
    ns = unique_namespace()
    components = Module.concat([ns, "Components"])
    page = Module.concat([ns, "WebLive"])

    define!(
      ctx,
      """
      defmodule #{ns}.Components do
        use Host.Web, :html

        attr :name, :string, required: true

        def greeting(assigns) do
          ~H"<span>hello {@name}</span>"
        end
      end

      defmodule #{ns}.WebLive do
        use Host.Web, :live_view

        import #{ns}.Components

        def mount(_params, _session, socket), do: {:ok, assign(socket, id: 1)}

        def render(assigns) do
          ~H\"\"\"
          <.greeting name="web" />
          <.link navigate={~p"/rt/web/\#{@id}"}>next</.link>
          \"\"\"
        end
      end
      """,
      [components, page]
    )

    mount!(fn -> Host.Router.live("/rt/web", page) end)

    response = Host.Router.call(:get, "/rt/web")

    assert response.status == 200
    assert response.body =~ "hello web"
    assert response.body =~ ~s|href="/rt/web/1"|
  end

  @tag web: [prefix: "/app"]
  test "~p in a template carries the prefix", ctx do
    ns = unique_namespace()
    page = Module.concat([ns, "WebLive"])

    define!(
      ctx,
      """
      defmodule #{ns}.WebLive do
        use Host.Web, :live_view

        def render(assigns) do
          ~H|<.link navigate={~p"/rt/web/next"}>next</.link>|
        end
      end
      """,
      [page]
    )

    mount!(fn -> Host.Router.live("/rt/web", page) end)

    assert Host.Router.call(:get, "/rt/web").body =~ ~s|href="/app/rt/web/next"|
  end

  test "a :controller action answers JSON", ctx do
    ns = unique_namespace()
    mod = Module.concat([ns, "Api"])

    define!(
      ctx,
      """
      defmodule #{ns}.Api do
        use Host.Web, :controller

        def create(conn, params) do
          conn |> put_status(201) |> json(%{got: params["note"], at: ~p"/rt/api"})
        end
      end
      """,
      [mod]
    )

    mount!(fn -> Host.Router.post("/rt/api", mod, :create) end)

    response = Host.Router.call(:post, "/rt/api", %{"note" => "hi"})

    assert response.status == 201
    assert response.body == %{"got" => "hi", "at" => "/rt/api"}
  end

  test "a :live_component is a LiveComponent", ctx do
    ns = unique_namespace()
    mod = Module.concat([ns, "Card"])

    define!(
      ctx,
      """
      defmodule #{ns}.Card do
        use Host.Web, :live_component

        def render(assigns), do: ~H"<div>card</div>"
      end
      """,
      [mod]
    )

    assert function_exported?(mod, :__live__, 0)
    assert mod.__live__()[:kind] == :component
  end

  @tag web: [prefix: "/app"]
  test "a prefixed ~p in a template surfaces the teaching error through call/4", ctx do
    ns = unique_namespace()
    mod = Module.concat([ns, "BadLive"])

    define!(
      ctx,
      """
      defmodule #{ns}.BadLive do
        use Host.Web, :live_view

        def render(assigns) do
          ~H|<a href={~p"/app/rt/bad"}>bad</a>|
        end
      end
      """,
      [mod]
    )

    mount!(fn -> Host.Router.live("/rt/bad", mod) end)

    error = assert_raise RuntimeError, fn -> Host.Router.call(:get, "/rt/bad") end

    assert error.message =~ "GET /rt/bad crashed"
    assert error.message =~ "paths never include the prefix /app"
  end

  test "an unknown role is a teaching error at define time", ctx do
    ns = unique_namespace()

    assert {:error, message} =
             quiet(fn ->
               Define.run(
                 """
                 defmodule #{ns}.Odd do
                   @moduledoc "Odd."
                   use Host.Web, :channel
                 end
                 """,
                 ctx.principal
               )
             end)

    assert message =~ "use Host.Web takes :live_view, :controller, :live_component or :html"
    assert message =~ "got: :channel"
  end

  test "the authoring shape passes the scanner and the docs gate", ctx do
    ns = unique_namespace()
    mod = Module.concat([ns, "PageLive"])
    purge_on_exit([mod])

    assert {:ok, summary} =
             Define.run(
               """
               defmodule #{ns}.PageLive do
                 @moduledoc "A page."
                 use Host.Web, :live_view

                 def mount(_params, _session, socket) do
                   {:ok, assign(socket, next: ~p"/notes")}
                 end

                 def render(assigns) do
                   ~H"<div>{@next}</div>"
                 end
               end
               """,
               ctx.principal
             )

    assert summary =~ "#{ns}.PageLive"
    mount!(fn -> Host.Router.live("/rt/page", mod) end)
    assert Host.Router.call(:get, "/rt/page").body =~ "/notes"
  end
end
