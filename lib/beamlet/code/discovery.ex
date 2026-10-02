defmodule Beamlet.Code.Discovery do
  @moduledoc false

  # The rendering behind Host.Code: the listing, the docs, the source
  # and its pieces, the outline, a function and a line range. Every
  # function takes the effective policy, the principal's
  # policy with the defined modules merged in (Beamlet.Policy.grant/2),
  # so a defined module is granted like any other and needs no special
  # case; it returns {:ok, text} or {:error, text}, and Host.Code
  # prints the one and raises the other.
  #
  # Docs are served from compiled artifacts through Code.fetch_docs/1:
  # defined modules by beam path, since their beams are not on the
  # code path, everything else by name, so a granted package is
  # self-documenting. The listing leaves out the standard platform,
  # Elixir and Erlang/OTP: it carries exactly what a model cannot bring
  # from training, what this beamlet provides, what was built on it
  # before, and which packages it ships. The defined section is
  # code/lib: migrations live in code/migrations and are listed by
  # Host.Migrator, and the routes by Host.Router, which the footer
  # points at. A refused module gets the scanner's copy, so print_docs
  # teaches what a refused call does.

  alias Beamlet.Code.Docs
  alias Beamlet.Code.Source
  alias Beamlet.Policy
  alias Beamlet.Policy.Default
  alias Beamlet.Scanner

  @defined_heading "Defined modules (define):"
  @host_heading "Host modules (your beamlet's stdlib):"
  @framework_heading "Framework modules (what you write pages and data against; " <>
                       "print_docs for any):"
  @libraries_heading "Libraries (every module of each package is available):"

  @footer "Host.Code.print_docs(Module) for documentation; Host.Router.print_routes() " <>
            "for the routes; Host.Migrator.print_migrations() for the migrations."

  @format_note "(documentation is in a format your beamlet cannot render)"

  @spec list(Policy.t()) :: {:ok, String.t()}
  def list(%Policy{} = policy) do
    manifest = Beamlet.Code.manifest()
    {host_mods, framework_mods, libraries} = classify_granted(policy, manifest)

    defined_lines =
      manifest
      |> Enum.reject(fn {_mod, paths} -> paths.migration end)
      |> Enum.sort_by(fn {mod, _paths} -> inspect(mod) end)
      |> Enum.map(fn {mod, paths} -> entry_line(mod, moduledoc_summary(paths.beam_file)) end)

    text =
      Enum.join(
        [
          section(
            @defined_heading,
            defined_lines ++ quarantined_lines(),
            "(none yet — build something durable with define)"
          ),
          section(@host_heading, module_lines(host_mods), "(none)"),
          section(@framework_heading, framework_lines(framework_mods), "(none)"),
          section(@libraries_heading, library_lines(libraries), "(none)"),
          @footer
        ],
        "\n\n"
      )

    {:ok, text}
  end

  @spec doc(Policy.t(), module()) :: {:ok, String.t()} | {:error, String.t()}
  def doc(%Policy{} = policy, module) do
    with {:ok, target} <- resolve(policy, module),
         {:ok, chunk} <- fetch(module, target) do
      {:ok, render_module(module, chunk, policy)}
    end
  end

  @spec doc(Policy.t(), module(), atom(), arity() | :any) ::
          {:ok, String.t()} | {:error, String.t()}
  def doc(%Policy{} = policy, module, fun, arity \\ :any) do
    with {:ok, target} <- resolve(policy, module),
         {:ok, {:docs_v1, _, _, _, _, _, entries}} <- fetch(module, target) do
      matches =
        Enum.filter(entries, fn
          {{kind, name, _a}, _anno, _sig, _doc, _meta} = entry ->
            kind in [:function, :macro] and name == fun and
              (arity == :any or arity in arities(entry))

          _other ->
            false
        end)

      permitted = Enum.filter(matches, &entry_allowed?(&1, module, policy))

      cond do
        matches == [] -> {:error, no_function(module, fun, arity)}
        permitted == [] -> {:error, denied_function(policy, module, fun, arity)}
        true -> {:ok, Enum.map_join(permitted, "\n\n", &render_entry(module, &1))}
      end
    end
  end

  @spec source(Policy.t(), module()) :: {:ok, String.t()} | {:error, String.t()}
  def source(%Policy{} = policy, module) do
    with {:ok, _path, contents} <- read_source(policy, module, "print_source") do
      {:ok, String.trim_trailing(contents)}
    end
  end

  # ── Reading in pieces ─────────────────────────────────────────────

  # The outline is the map an agent reads before a function print or
  # a patch: one row per top-level item with the lines it spans, a
  # function's row covering all its clauses and the docs above them.
  # It shows what the module is made of and hides how: the moduledoc
  # and the attributes holding values have no row, and the gap they
  # leave is read by range. Function and range prints are the stored
  # text verbatim, with no line-number gutter, so what an agent copies
  # from them matches the source byte for byte.

  @hidden_kinds [:doc, :attribute]

  @spec outline(Policy.t(), module()) :: {:ok, String.t()} | {:error, String.t()}
  def outline(%Policy{} = policy, module) do
    with {:ok, path, contents} <- read_source(policy, module, "print_outline"),
         {:ok, items} <- parsed(module, path, contents, Source.outline(contents)) do
      {:ok, render_outline(module, path, contents, items)}
    end
  end

  @spec function(Policy.t(), module(), atom(), arity() | :any) ::
          {:ok, String.t()} | {:error, String.t()}
  def function(%Policy{} = policy, module, fun, arity) do
    with {:ok, path, contents} <- read_source(policy, module, "print_source"),
         {:ok, items} <- parsed(module, path, contents, Source.outline(contents)) do
      functions = Enum.filter(items, &(&1.name != nil))
      matches = Enum.filter(functions, &(&1.name == fun and (arity == :any or &1.arity == arity)))

      scattered =
        matches
        |> Enum.group_by(& &1.arity)
        |> Enum.filter(fn {_arity, pieces} -> length(pieces) > 1 end)
        |> Enum.map(fn {arity, _pieces} -> arity end)
        |> Enum.sort()

      cond do
        matches == [] -> {:error, no_source_function(module, fun, arity, functions)}
        scattered != [] -> {:error, scattered_function(module, fun, hd(scattered))}
        true -> {:ok, Enum.map_join(matches, "\n\n", & &1.text)}
      end
    end
  end

  @spec lines(Policy.t(), module(), Range.t()) :: {:ok, String.t()} | {:error, String.t()}
  def lines(%Policy{} = policy, module, first..last//1) do
    with {:ok, _path, contents} <- read_source(policy, module, "print_source") do
      count = Source.line_count(contents)

      if first > count,
        do: {:error, "#{inspect(module)} has #{count} lines — the range starts past the end"},
        else: {:ok, Source.lines(contents, first..min(last, count)//1)}
    end
  end

  defp read_source(policy, module, caller) do
    case Beamlet.Code.source_file(module) do
      {:ok, source_file} ->
        case File.read(source_file) do
          {:ok, contents} ->
            {:ok, Path.relative_to(source_file, Beamlet.Config.code_dir()), contents}

          {:error, reason} ->
            {:error, "could not read the source of #{inspect(module)} (#{inspect(reason)})"}
        end

      :error ->
        if Code.ensure_loaded?(module) do
          {:error,
           "Host.Code.#{caller} serves defined modules only — #{inspect(module)} is " <>
             "part of your beamlet. Use Host.Code.print_docs(#{inspect(module)}) for " <>
             "its documentation."}
        else
          {:error, Scanner.denied_module(policy, module)}
        end
    end
  end

  # Only a quarantined module can fail to parse. The range print is
  # the read that still works on it.
  defp parsed(_module, _path, _contents, {:ok, items}), do: {:ok, items}

  defp parsed(module, path, contents, {:error, {line, message}}) do
    {:error,
     "#{inspect(module)} does not parse — #{Scanner.locate(contents, path, line, message)}\n" <>
       "Read it by line range instead: Host.Code.print_source(#{inspect(module)}, " <>
       "1..#{Source.line_count(contents)})"}
  end

  defp render_outline(module, path, contents, items) do
    rows =
      items
      |> Enum.reject(&(&1.kind in @hidden_kinds))
      |> Enum.map(fn item -> {range_text(item.range), row_label(item)} end)

    width =
      rows |> Enum.map(fn {range, _label} -> String.length(range) end) |> Enum.max(fn -> 0 end)

    [
      "#{inspect(module)} — #{path}, #{Source.line_count(contents)} lines"
      | Enum.map(rows, fn {range, label} -> "  #{String.pad_trailing(range, width)}  #{label}" end)
    ]
    |> Enum.join("\n")
  end

  defp range_text(first..first//1), do: "#{first}"
  defp range_text(first..last//1), do: "#{first}-#{last}"

  defp row_label(%{clauses: clauses, label: label}) when is_integer(clauses) and clauses > 1,
    do: "#{label} (#{clauses} clauses)"

  defp row_label(%{label: label}), do: label

  # ── Resolution ────────────────────────────────────────────────────

  defp resolve(policy, module) do
    case Beamlet.Code.manifest() do
      %{^module => %{beam_file: beam_file}} ->
        {:ok, beam_file}

      _not_defined ->
        if Policy.allowed?(policy, module),
          do: {:ok, module},
          else: {:error, Scanner.denied_module(policy, module)}
    end
  end

  defp fetch(module, target) do
    case Code.fetch_docs(target) do
      {:docs_v1, _, _, _, _, _, _} = chunk -> {:ok, join_repo_docs(module, chunk)}
      {:error, _reason} -> {:error, "no documentation is available for #{inspect(module)}"}
    end
  end

  # `use Ecto.Repo` generates Host.Repo's functions without docs; the
  # documentation lives on Ecto.Repo's callbacks of the same name and
  # arity. Joining them here shows Ecto's real docs under Host.Repo
  # without granting Ecto.Repo or wrapping the repo. A one-module
  # special case; the adapter's additions (query, explain, to_sql)
  # arrive with docs of their own, and anything else undocumented
  # keeps its bare signature.
  defp join_repo_docs(Host.Repo, {:docs_v1, anno, lang, format, module_doc, meta, entries}) do
    callbacks =
      case Code.fetch_docs(Ecto.Repo) do
        {:docs_v1, _, _, _, _, _, callback_entries} ->
          for {{:callback, name, arity}, _anno, _sig, doc, _meta} <- callback_entries,
              into: %{},
              do: {{name, arity}, doc}

        {:error, _reason} ->
          %{}
      end

    joined =
      Enum.map(entries, fn
        {{:function, name, arity}, anno, sig, :none, meta} ->
          {{:function, name, arity}, anno, sig, Map.get(callbacks, {name, arity}, :none), meta}

        entry ->
          entry
      end)

    {:docs_v1, anno, lang, format, module_doc, meta, joined}
  end

  defp join_repo_docs(_module, chunk), do: chunk

  # ── Listing ───────────────────────────────────────────────────────

  # Three groupings of granted code beyond the defined modules, each
  # rendered its own way: the host stdlib, the framework modules
  # agents write against (curated per module, the rest of those
  # applications being machinery), and the libraries. Platform
  # modules are never listed, and neither are exception structs,
  # which are rescued, not called.
  defp classify_granted(policy, manifest) do
    framework = MapSet.new(Default.framework_modules())

    {host_mods, framework_mods, dep_mods} =
      policy.grants
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(manifest, &1))
      |> Enum.sort_by(&inspect/1)
      |> Enum.reduce({[], [], []}, fn mod, {host, fw, deps} ->
        cond do
          Scanner.host_module?(mod) -> {[mod | host], fw, deps}
          MapSet.member?(framework, mod) -> {host, [mod | fw], deps}
          platform_module?(mod) -> {host, fw, deps}
          exception?(mod) -> {host, fw, deps}
          true -> {host, fw, [mod | deps]}
        end
      end)

    {Enum.reverse(host_mods), Enum.reverse(framework_mods), libraries(Enum.reverse(dep_mods))}
  end

  # A package the beamlet ships renders as one line led by its primary
  # module, the shortest granted name, which for a whole package is
  # the module named after it. A module granted from any other package
  # renders as its own line, so the heading never overclaims.
  defp libraries(dep_mods) do
    packages = Default.packages()

    dep_mods
    |> Enum.group_by(fn mod ->
      {:ok, app} = :application.get_application(mod)
      app
    end)
    |> Enum.flat_map(fn {app, mods} ->
      if app in packages,
        do: [{:package, app, Enum.min_by(mods, &String.length(inspect(&1)))}],
        else: Enum.map(mods, &{:module, app, &1})
    end)
    |> Enum.sort_by(fn
      {:package, app, _primary} -> {inspect(app), ""}
      {:module, app, mod} -> {inspect(app), inspect(mod)}
    end)
  end

  defp library_lines(libraries) do
    Enum.map(libraries, fn
      {:package, app, primary} ->
        label = "#{inspect(primary)} (#{inspect(app)})"

        case app_description(app) do
          nil -> "  #{label}"
          summary -> "  #{label} — #{summary}"
        end

      {:module, app, mod} ->
        entry_line(mod, moduledoc_summary(mod), " (#{inspect(app)})")
    end)
  end

  # The .app description when the author wrote one; Mix's fallback is
  # the bare app name, which says nothing.
  defp app_description(app) do
    case Application.spec(app, :description) do
      nil ->
        nil

      description ->
        description = description |> List.to_string() |> String.trim()
        if description == Atom.to_string(app), do: nil, else: description
    end
  end

  defp quarantined_lines do
    for entry <- Beamlet.Code.quarantined(), mod <- entry.modules do
      "  #{inspect(mod)} — quarantined: #{entry.error} (patch it, define it again " <>
        "with replace: true, or Host.Code.remove it)"
    end
  end

  defp exception?(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :__struct__, 0) and
      match?(%{__exception__: true}, mod.__struct__())
  end

  defp platform_module?(mod) do
    case :application.get_application(mod) do
      {:ok, app} -> platform_app?(app)
      :undefined -> true
    end
  end

  defp platform_app?(app) do
    case :code.lib_dir(app) do
      {:error, :bad_name} ->
        false

      dir ->
        dir = List.to_string(dir)
        String.starts_with?(dir, otp_root()) or String.starts_with?(dir, elixir_lib_root())
    end
  end

  defp otp_root, do: List.to_string(:code.root_dir())

  defp elixir_lib_root, do: :elixir |> :code.lib_dir() |> List.to_string() |> Path.dirname()

  defp module_lines(mods), do: Enum.map(mods, &entry_line(&1, moduledoc_summary(&1)))

  # Names only, wrapped: the framework modules are ones the model
  # knows, and their moduledoc openers say nothing a name does not.
  @wrap_at 76

  defp framework_lines([]), do: []

  defp framework_lines(mods) do
    mods
    |> Enum.map(&inspect/1)
    |> Enum.reduce([], fn
      name, [] ->
        [name]

      name, [line | rest] when byte_size(line) + byte_size(name) + 2 > @wrap_at ->
        [name, line | rest]

      name, [line | rest] ->
        [line <> ", " <> name | rest]
    end)
    |> Enum.reverse()
    |> Enum.join(",\n")
    |> String.split("\n")
    |> Enum.map(&("  " <> &1))
  end

  defp entry_line(mod, summary, suffix \\ "")
  defp entry_line(mod, nil, suffix), do: "  #{inspect(mod)}#{suffix}"
  defp entry_line(mod, summary, suffix), do: "  #{inspect(mod)}#{suffix} — #{summary}"

  defp section(title, [], placeholder), do: "#{title}\n  #{placeholder}"
  defp section(title, lines, _placeholder), do: "#{title}\n#{Enum.join(lines, "\n")}"

  defp moduledoc_summary(target) do
    case Code.fetch_docs(target) do
      {:docs_v1, _, _, _, module_doc, _, _} -> module_doc |> doc_text() |> Docs.summary()
      {:error, _reason} -> nil
    end
  end

  # ── Rendering ─────────────────────────────────────────────────────

  defp render_module(module, {:docs_v1, _, _, _, module_doc, _, entries}, policy) do
    {index_lines, omitted} = function_index(module, entries, policy)

    sections = ["# #{inspect(module)}", doc_text(module_doc) || "(no module documentation)"]

    sections =
      if index_lines == [],
        do: sections,
        else: sections ++ ["## Functions\n\n" <> Enum.join(index_lines, "\n")]

    sections =
      if omitted > 0,
        do: sections ++ [omitted_note(omitted)],
        else: sections

    Enum.join(sections, "\n\n")
  end

  defp function_index(module, entries, policy) do
    {allowed, denied} =
      entries
      |> Enum.filter(fn
        {{kind, _name, _a}, _anno, _sig, doc, _meta} ->
          kind in [:function, :macro] and doc != :hidden

        _other ->
          false
      end)
      |> Enum.split_with(&entry_allowed?(&1, module, policy))

    lines =
      allowed
      |> Enum.sort_by(fn {{_kind, name, a}, _anno, _sig, _doc, _meta} -> {name, a} end)
      |> Enum.map(fn {{_kind, name, a}, _anno, sig, doc, _meta} ->
        "  " <> index_entry(format_signature(sig, name, a), doc |> doc_text() |> Docs.summary())
      end)

    {lines, length(denied)}
  end

  # A docs entry collapses default arguments into one head: puts/1
  # and puts/2 are a single puts/2 entry with defaults: 1. So an entry
  # stands for a range of callable arities, and it is permitted when
  # any of them is.
  defp arities({{_kind, _name, arity}, _anno, _sig, _doc, meta}) do
    (arity - Map.get(meta, :defaults, 0))..arity
  end

  defp entry_allowed?(entry, module, policy) do
    {{_kind, name, _arity}, _anno, _sig, _doc, _meta} = entry
    Enum.any?(arities(entry), &Policy.allowed?(policy, module, name, &1))
  end

  defp index_entry(signature, nil), do: signature
  defp index_entry(signature, summary), do: "#{signature} — #{summary}"

  defp omitted_note(1), do: "(1 function not shown — not permitted by your policy)"
  defp omitted_note(n), do: "(#{n} functions not shown — not permitted by your policy)"

  defp render_entry(module, {{_kind, name, arity}, _anno, sig, doc, _meta}) do
    "# #{inspect(module)}.#{format_signature(sig, name, arity)}\n\n" <>
      (doc_text(doc) || "(no documentation)")
  end

  defp format_signature([sig | _rest], _name, _arity) when is_binary(sig), do: sig
  defp format_signature(_sig, name, arity), do: "#{name}/#{arity}"

  defp doc_text(%{} = doc) do
    case doc["en"] || doc |> Map.values() |> List.first() do
      text when is_binary(text) -> String.trim_trailing(text)
      _unrenderable -> @format_note
    end
  end

  defp doc_text(_none_or_hidden), do: nil

  # ── Error copy ────────────────────────────────────────────────────

  defp no_function(module, fun, arity) do
    "#{inspect(module)} has no public function or macro named #{fun}#{arity_suffix(arity)} — " <>
      "Host.Code.print_docs(#{inspect(module)}) lists what it has"
  end

  defp denied_function(policy, module, fun, arity) do
    "#{inspect(module)}.#{fun}#{arity_suffix(arity)} #{Scanner.not_permitted(policy, module, fun)}"
  end

  defp arity_suffix(:any), do: ""
  defp arity_suffix(arity), do: "/#{arity}"

  defp no_source_function(module, fun, arity, []) do
    "#{inspect(module)} has no function #{fun}#{arity_suffix(arity)} — it defines no " <>
      "functions; Host.Code.print_outline(#{inspect(module)}) shows what it holds"
  end

  defp no_source_function(module, fun, arity, functions) do
    "#{inspect(module)} has no function #{fun}#{arity_suffix(arity)} — " <>
      "Host.Code.print_outline(#{inspect(module)}) lists what it has: " <>
      Enum.map_join(functions, ", ", &Source.fa/1)
  end

  defp scattered_function(module, fun, arity) do
    "#{inspect(module)}.#{fun}/#{arity} has clauses separated by other definitions, so it " <>
      "cannot be printed as one block — Host.Code.print_outline(#{inspect(module)}) shows " <>
      "where each clause is; read them with Host.Code.print_source(#{inspect(module)}, " <>
      "first..last)"
  end
end
