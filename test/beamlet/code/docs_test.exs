defmodule Beamlet.Code.DocsTest do
  use ExUnit.Case, async: true

  alias Beamlet.Code.Docs

  defp check_error(code) do
    assert {:error, message} = Docs.check(code)
    message
  end

  describe "check/1" do
    test "a fully documented module passes" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.A do
                 @moduledoc "A fixture."

                 @doc "Adds."
                 def add(a, b), do: a + b
               end
               """)
    end

    test "a missing moduledoc is rejected" do
      message =
        check_error("""
        defmodule Docs.Fixture.B do
          @doc "Adds."
          def add(a, b), do: a + b
        end
        """)

      assert message =~ "Docs.Fixture.B is missing @moduledoc"
      assert message =~ "discovered later"
    end

    test "moduledoc false is rejected" do
      message =
        check_error("""
        defmodule Docs.Fixture.C do
          @moduledoc false
        end
        """)

      assert message =~ "@moduledoc false hides Docs.Fixture.C from discovery"
    end

    test "an undocumented public function names itself" do
      message =
        check_error("""
        defmodule Docs.Fixture.D do
          @moduledoc "D."

          def add(a, b), do: a + b
        end
        """)

      assert message =~ "Docs.Fixture.D.add/2 is missing @doc"
    end

    test "doc false satisfies the gate for functions" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.E do
                 @moduledoc "E."

                 @doc false
                 def internal(x), do: x
               end
               """)
    end

    test "clauses share one doc, tracked per name" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.F do
                 @moduledoc "F."

                 @doc "Sizes things."
                 def size([]), do: 0
                 def size([_ | rest]), do: 1 + size(rest)
               end
               """)
    end

    test "default arguments declare a head without needing a second doc" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.G do
                 @moduledoc "G."

                 @doc "Greets."
                 def greet(name, greeting \\\\ "hello")
                 def greet(name, greeting), do: "\#{greeting} \#{name}"
               end
               """)
    end

    test "guards are unwrapped" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.H do
                 @moduledoc "H."

                 @doc "Doubles."
                 def double(x) when is_integer(x), do: x * 2
               end
               """)
    end

    test "private functions need no doc" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.I do
                 @moduledoc "I."

                 @doc "Public."
                 def go, do: helper()

                 defp helper, do: :ok
               end
               """)
    end

    test "a doc consumed by a private function does not document the next public one" do
      message =
        check_error("""
        defmodule Docs.Fixture.J do
          @moduledoc "J."

          @doc "Attached to the defp."
          defp helper, do: :ok

          def go, do: helper()
        end
        """)

      assert message =~ "Docs.Fixture.J.go/0 is missing @doc"
    end

    test "defmacro and defdelegate need docs" do
      message =
        check_error("""
        defmodule Docs.Fixture.K do
          @moduledoc "K."

          defmacro twice(x) do
            quote do: unquote(x) * 2
          end

          defdelegate upcase(s), to: String
        end
        """)

      assert message =~ "Docs.Fixture.K.twice/1 is missing @doc"
      assert message =~ "Docs.Fixture.K.upcase/1 is missing @doc"
    end

    test "a parse error carries the line" do
      assert check_error("defmodule Docs.Fixture.M do\n  def broken(") =~ ~r/^line \d+: /
    end

    test "all violations are collected, one per line" do
      message =
        check_error("""
        defmodule Docs.Fixture.L do
          def a, do: 1
          def b, do: 2
        end
        """)

      assert [first, second, third] = String.split(message, "\n")
      assert first =~ "missing @moduledoc"
      assert second =~ "Docs.Fixture.L.a/0"
      assert third =~ "Docs.Fixture.L.b/0"
    end

    test "a LiveView's undocumented callbacks pass" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.N do
                 @moduledoc "A live view."
                 use Phoenix.LiveView

                 def mount(_params, _session, socket), do: {:ok, socket}
                 def render(assigns), do: ~H"<p>hi</p>"
                 def handle_event("go", _params, socket), do: {:noreply, socket}
               end
               """)
    end

    test "a controller's undocumented actions and helpers pass" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.O do
                 @moduledoc "A controller."
                 use Phoenix.Controller, formats: [:json]

                 def show(conn, params), do: json(conn, payload(params))
                 def payload(params), do: %{id: params["id"]}
               end
               """)
    end

    test "a LiveComponent's undocumented callbacks pass" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.P do
                 @moduledoc "A live component."
                 use Phoenix.LiveComponent

                 def update(assigns, socket), do: {:ok, assign(socket, assigns)}
                 def render(assigns), do: ~H"<p>hi</p>"
               end
               """)
    end

    test "use Host.Web, :live_view, :controller and :live_component exempt too" do
      for role <- [:live_view, :controller, :live_component] do
        assert :ok =
                 Docs.check("""
                 defmodule Docs.Fixture.W do
                   @moduledoc "Web."
                   use Host.Web, #{inspect(role)}

                   def render(assigns), do: ~H"<p>hi</p>"
                 end
                 """)
      end
    end

    test "use Host.Web, :html is not exempt — components are discoverable functions" do
      message =
        check_error("""
        defmodule Docs.Fixture.X do
          @moduledoc "Components."
          use Host.Web, :html

          def card(assigns), do: ~H"<p>hi</p>"
        end
        """)

      assert message =~ "Docs.Fixture.X.card/1 is missing @doc"
    end

    test "use Ecto.Migration, Ecto.Type and Ecto.ParameterizedType exempt their callbacks" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.M do
                 @moduledoc "Creates a table."
                 use Ecto.Migration

                 def change, do: create(table(:things))
               end
               """)

      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.T do
                 @moduledoc "A type."
                 use Ecto.Type

                 def type, do: :string
                 def cast(value), do: {:ok, value}
                 def load(value), do: {:ok, value}
                 def dump(value), do: {:ok, value}
               end
               """)

      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.P do
                 @moduledoc "A parameterized type."
                 use Ecto.ParameterizedType

                 def init(opts), do: opts
                 def type(_params), do: :string
               end
               """)
    end

    test "use Ecto.Schema is not exempt — changeset/2 is the module's API" do
      message =
        check_error("""
        defmodule Docs.Fixture.S do
          @moduledoc "A schema."
          use Ecto.Schema

          schema "things" do
            field :name, :string
          end

          def changeset(thing, attrs), do: Ecto.Changeset.cast(thing, attrs, [:name])
        end
        """)

      assert message =~ "Docs.Fixture.S.changeset/2 is missing @doc"
    end

    test "an exempt module still needs a moduledoc" do
      message =
        check_error("""
        defmodule Docs.Fixture.Q do
          use Phoenix.LiveView

          def mount(_params, _session, socket), do: {:ok, socket}
        end
        """)

      assert message =~ "Docs.Fixture.Q is missing @moduledoc"
      refute message =~ "mount/3"

      message =
        check_error("""
        defmodule Docs.Fixture.R do
          @moduledoc false
          use Phoenix.LiveView

          def mount(_params, _session, socket), do: {:ok, socket}
        end
        """)

      assert message =~ "@moduledoc false hides Docs.Fixture.R from discovery"
      refute message =~ "mount/3"
    end

    test "the use line exempts wherever it sits in the module" do
      assert :ok =
               Docs.check("""
               defmodule Docs.Fixture.S do
                 @moduledoc "A live view."

                 def mount(_params, _session, socket), do: {:ok, socket}

                 use Phoenix.LiveView
               end
               """)
    end

    test "the exemption is per module, not per buffer" do
      message =
        check_error("""
        defmodule Docs.Fixture.T do
          @moduledoc "A live view."
          use Phoenix.LiveView

          def mount(_params, _session, socket), do: {:ok, socket}
        end

        defmodule Docs.Fixture.U do
          @moduledoc "Plain."

          def add(a, b), do: a + b
        end
        """)

      assert [only] = String.split(message, "\n")
      assert only =~ "Docs.Fixture.U.add/2 is missing @doc"
    end
  end
end
