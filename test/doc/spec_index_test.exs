defmodule Doc.SpecIndexTest do
  @moduledoc """
  Keeps `doc/baudrate-spec.md` — the conformance index — from becoming the
  fifth place an invariant is stated and the first place one goes stale.

  The index exists because a 2026-09-19 audit of all 46 ADRs then on file found
  eight real defects, and most of them were in the cells this table makes
  visible: a rule with no gate, code with no record, a record whose gate did
  not cover the case. Building that table by hand *was* the audit. This test
  makes the table cheap to keep instead of expensive to rebuild.

  It checks only what is mechanically checkable:

    * every ADR on disk has at least one row, so a new record cannot be omitted;
    * every test file a row names exists;
    * every function a row names exists, at the arity given;
    * every test file a record names in its own **Acceptance gate** section
      appears in that record's rows, so adding a gate to an ADR cannot leave
      the index behind.

  It cannot check whether a summary is *true*. Nothing can, which is why the
  index says the record wins over the row and the code wins over the record.
  """

  use ExUnit.Case, async: true

  @spec_path "doc/baudrate-spec.md"
  @adr_glob "doc/adr/0*.md"

  # A row: | invariant | [NNNN](adr/file.md) | `Mod.fun/n`, … | gate |
  @row_re ~r/^\|\s*(?<inv>[^|]+?)\s*\|\s*\[(?<adr>\d{4})\]\((?<link>[^)]+)\)\s*\|\s*(?<enf>[^|]*?)\s*\|\s*(?<gate>[^|]*?)\s*\|\s*$/

  # An ADR's own gate section. A section that opens with "None" is an explicit
  # declaration that there is no gate — ADR 0047 is exactly that, and it names
  # a test only as the shape it is *not* adopting. Scraping filenames out of
  # that prose is how the index would acquire a gate the record disclaims.
  @gate_section_re ~r/^##\s*Acceptance gate\s*$(?<body>.*?)(?=^##\s|\z)/ms

  setup_all do
    spec = File.read!(@spec_path)

    rows =
      spec
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.named_captures(@row_re, line) do
          nil -> []
          %{"inv" => inv} = c when inv not in ["Invariant", "---"] -> [c]
          _ -> []
        end
      end)
      |> Enum.reject(&(&1["inv"] == "Invariant"))

    %{spec: spec, rows: rows, adrs: Path.wildcard(@adr_glob)}
  end

  test "the index parses, and is not silently empty", %{rows: rows} do
    assert length(rows) > 100,
           "parsed only #{length(rows)} rows from #{@spec_path}. If the table " <>
             "format changed, fix @row_re — an index this test cannot read is " <>
             "an index nothing checks."
  end

  test "every ADR on disk has at least one row", %{rows: rows, adrs: adrs} do
    have = rows |> Enum.map(& &1["adr"]) |> MapSet.new()

    missing =
      adrs
      |> Enum.map(&(Path.basename(&1) |> String.slice(0, 4)))
      |> Enum.reject(&MapSet.member?(have, &1))
      |> Enum.sort()

    assert missing == [],
           "these ADRs have no row in #{@spec_path}: #{Enum.join(missing, ", ")}. " <>
             "A new record needs a row — even one whose gate is **none**, which " <>
             "is itself the finding."
  end

  test "every row's ADR link resolves to a real record", %{rows: rows} do
    broken =
      rows
      |> Enum.map(& &1["link"])
      |> Enum.uniq()
      |> Enum.reject(&File.exists?(Path.join("doc", &1)))

    assert broken == [], "dead ADR links: #{Enum.join(broken, ", ")}"
  end

  test "every test file a row names exists", %{rows: rows} do
    missing =
      rows
      |> Enum.flat_map(&gate_files(&1["gate"]))
      |> Enum.uniq()
      |> Enum.reject(&(Path.wildcard("test/**/#{&1}") != []))
      |> Enum.sort()

    assert missing == [],
           "gates named in #{@spec_path} that do not exist: #{Enum.join(missing, ", ")}. " <>
             "A renamed test file leaves the row pointing at nothing."
  end

  test "every function a row names exists, at the arity given", %{rows: rows} do
    bad =
      rows
      |> Enum.flat_map(fn row ->
        row["enf"]
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.flat_map(&symbol_problem(&1, row["adr"]))
      end)
      |> Enum.sort()
      |> Enum.uniq()

    assert bad == [],
           "enforcement points named in #{@spec_path} that do not exist as " <>
             "written:\n  " <> Enum.join(bad, "\n  ")
  end

  test "a gate an ADR names for itself appears in that ADR's rows", %{rows: rows, adrs: adrs} do
    by_adr =
      rows
      |> Enum.group_by(& &1["adr"], &gate_files(&1["gate"]))
      |> Map.new(fn {adr, lists} -> {adr, lists |> List.flatten() |> MapSet.new()} end)

    drift =
      for path <- adrs,
          num = Path.basename(path) |> String.slice(0, 4),
          declared = declared_gates(File.read!(path)),
          declared != [],
          indexed = Map.get(by_adr, num, MapSet.new()),
          missing = Enum.reject(declared, &MapSet.member?(indexed, &1)),
          missing != [] do
        "#{num} names #{Enum.join(missing, ", ")} in its Acceptance gate section, " <>
          "but no row for #{num} cites it"
      end

    assert drift == [],
           "the index is behind the records:\n  " <> Enum.join(drift, "\n  ")
  end

  # --- helpers ---

  defp gate_files("**none**"), do: []
  defp gate_files("—"), do: []

  defp gate_files(cell) do
    Regex.scan(~r/([a-z0-9_]+_test\.exs)/, cell, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  # An ADR's self-declared gates. "None" opens the section when the record
  # deliberately has no gate; anything it mentions after that is illustration.
  defp declared_gates(source) do
    case Regex.named_captures(@gate_section_re, source) do
      nil ->
        []

      %{"body" => body} ->
        if String.trim_leading(body) |> String.starts_with?("None") do
          []
        else
          Regex.scan(~r/([a-z0-9_]+_test\.exs)/, body, capture: :all_but_first)
          |> List.flatten()
          |> Enum.uniq()
        end
    end
  end

  defp symbol_problem("—", _adr), do: []
  defp symbol_problem("", _adr), do: []

  defp symbol_problem(cell, adr) do
    case Regex.run(~r/^`([A-Z][\w.]*)\.([a-z_][\w]*[?!]?)\/(\d+)`$/, cell) do
      [_, mod, fun, arity] ->
        m = Module.concat([mod])
        f = String.to_atom(fun)
        a = String.to_integer(arity)

        if defined?(m, f, a), do: [], else: ["#{adr}: #{mod}.#{fun}/#{arity}"]

      _ ->
        # Not a Module.fun/arity cell: a bare module, a file path, or a dash.
        # Those are checked only for shape, because a path in the repo is not
        # a symbol and a bare module has no arity to check.
        case Regex.run(~r/^`([A-Z][\w.]*)`$/, cell) do
          [_, mod] ->
            m = Module.concat([mod])
            if Code.ensure_loaded?(m), do: [], else: ["#{adr}: module #{mod}"]

          _ ->
            case Regex.run(~r{^`([\w./-]+\.(?:sh|yml|eex|ex|exs)|[\w./-]*Dockerfile)`$}, cell) do
              [_, path] ->
                if File.exists?(path), do: [], else: ["#{adr}: path #{path}"]

              _ ->
                []
            end
        end
    end
  end

  # `function_exported?/3` cannot see a `defp`, and some enforcement really is
  # private (`InboxHandler.article_federated?/1`), so there has to be a source
  # fallback. But the fallback matches on the *name* only, so letting it run
  # for a public function made the arity check useless: `same_host?/7` passed
  # because `same_host?` appears in the source. So the fallback is reachable
  # only when the module exports nothing by that name at any arity — that is,
  # when the function is genuinely private.
  defp defined?(mod, fun, arity) do
    cond do
      not Code.ensure_loaded?(mod) -> false
      function_exported?(mod, fun, arity) -> true
      macro_exported?(mod, fun, arity) -> true
      public_by_name?(mod, fun) -> false
      true -> private_defined?(mod, fun)
    end
  end

  defp public_by_name?(mod, fun) do
    exported = mod.__info__(:functions) ++ mod.__info__(:macros)
    Enum.any?(exported, fn {name, _arity} -> name == fun end)
  rescue
    _ -> false
  end

  defp private_defined?(mod, fun) do
    with source when not is_nil(source) <- mod.module_info(:compile)[:source],
         path = to_string(source),
         true <- File.exists?(path) do
      File.read!(path) =~ ~r/^\s*defp?\s+#{Regex.escape(to_string(fun))}[^[:alnum:]_]/m
    else
      _ -> false
    end
  end
end
