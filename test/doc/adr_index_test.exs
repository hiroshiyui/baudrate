defmodule Doc.AdrIndexTest do
  @moduledoc """
  The ADR index is the only thing most readers see (ADR 0000).

  A record's Status line is the authoritative statement of what happened to it;
  the index row is a summary of that line, and a summary is allowed to be
  shorter. What it is not allowed to do is lose the pointer: a row that says
  `Accepted` while the record says `superseded by 0042` hands the reader the
  reversed answer and no way to find the reversal. The same goes the other way
  — a row naming an ADR the record itself does not mention is a claim nobody
  maintained.

  So the invariant is not textual equality (17 of 46 rows abbreviate, and are
  right to: 0010's Status runs to six lines), but:

    * the index lists exactly the records on disk,
    * a row references exactly the ADRs its record's Status references, and
    * where the Status uses a relationship verb, the row uses it too.

  This is the machine-checkable half of rule 5 in `doc/adr/README.md`. It
  exists because the drift is invisible by inspection: three records
  (0001, 0033, 0040) sat with a bare `Accepted` for a release after ADR 0041
  renamed things they name.
  """

  use ExUnit.Case, async: true

  @adr_dir "doc/adr"
  @index Path.join(@adr_dir, "README.md")

  # The verbs of ADR 0000's "How records relate". `renamed by` is deliberately
  # matched as `renamed`: the records phrase it several ways ("renamed by",
  # "were renamed to `timeline_*` by"), and the verb is the part that carries
  # the meaning.
  @verbs ["superseded", "amended", "refined", "renamed"]

  defp records do
    Path.wildcard(Path.join(@adr_dir, "[0-9][0-9][0-9][0-9]-*.md"))
    |> Map.new(fn path ->
      {Path.basename(path) |> String.slice(0, 4), File.read!(path)}
    end)
  end

  defp index_rows do
    Regex.scan(
      ~r/^\|\s*\[(\d{4})\]\([^)]+\)\s*\|[^|]*\|\s*(.+?)\s*\|\s*$/m,
      File.read!(@index)
    )
    |> Map.new(fn [_, number, status] -> {number, status} end)
  end

  # Everything between `- **Status:**` and the next `- **` field.
  defp status_line(body) do
    case Regex.run(~r/^- \*\*Status:\*\*\s*(.+?)(?=^- \*\*)/ms, body) do
      [_, status] -> status |> String.split() |> Enum.join(" ")
      nil -> nil
    end
  end

  defp referenced_adrs(text) do
    ~r/\[(\d{4})\]\(/
    |> Regex.scan(text)
    |> MapSet.new(fn [_, number] -> number end)
  end

  defp verbs_in(text) do
    downcased = String.downcase(text)
    MapSet.new(Enum.filter(@verbs, &String.contains?(downcased, &1)))
  end

  test "every record has an index row, and every row a record" do
    records = MapSet.new(Map.keys(records()))
    rows = MapSet.new(Map.keys(index_rows()))

    assert MapSet.difference(records, rows) |> MapSet.to_list() == [],
           "ADRs on disk with no row in #{@index}"

    assert MapSet.difference(rows, records) |> MapSet.to_list() == [],
           "rows in #{@index} naming no ADR on disk"
  end

  test "every record has a Status line" do
    missing = for {number, body} <- records(), is_nil(status_line(body)), do: number
    assert missing == [], "ADRs with no parseable `- **Status:**` field: #{inspect(missing)}"
  end

  test "an index row references exactly the ADRs its record's Status does" do
    rows = index_rows()

    drift =
      for {number, body} <- records(),
          status = status_line(body),
          status != nil,
          row = Map.get(rows, number, ""),
          in_record = referenced_adrs(status),
          in_row = referenced_adrs(row),
          not MapSet.equal?(in_record, in_row) do
        {number, MapSet.to_list(MapSet.difference(in_record, in_row)),
         MapSet.to_list(MapSet.difference(in_row, in_record))}
      end

    assert drift == [], """
    Index rows disagree with their record's Status line about which ADRs it
    refers to. Each entry is {ADR, missing from the row, extra in the row}:

    #{inspect(drift, pretty: true)}

    The row may abbreviate the Status line, but it must keep every ADR number
    the record points at — see rule 5 in #{@index}.
    """
  end

  test "an index row keeps the relationship verb its record's Status uses" do
    rows = index_rows()

    drift =
      for {number, body} <- records(),
          status = status_line(body),
          status != nil,
          row = Map.get(rows, number, ""),
          dropped = MapSet.difference(verbs_in(status), verbs_in(row)),
          not Enum.empty?(dropped) do
        {number, MapSet.to_list(dropped)}
      end

    assert drift == [], """
    Index rows drop a relationship verb their record's Status line uses:

    #{inspect(drift, pretty: true)}

    "superseded"/"amended"/"refined"/"renamed" is what tells a reader whether
    the decision still holds — see "How records relate" in #{@index}.
    """
  end

  test "every ADR link in a record or the index resolves to that record's file" do
    # Checking the bracketed number alone is vacuous: `[0011](0011-wrong.md)`
    # would pass, because 0011 exists. The href is what the reader clicks, so
    # the href is what has to resolve — and it has to resolve to the record the
    # link text names, not merely to some file.
    sources = Map.put(records(), "README.md", File.read!(@index))

    broken =
      for {source, text} <- sources,
          [_, number, href] <- Regex.scan(~r/\[(\d{4})\]\(([^)]+)\)/, text),
          not (String.starts_with?(href, "#") or href =~ ~r{^[a-z]+://}),
          reason = link_problem(number, href),
          reason != nil,
          do: {source, "[#{number}](#{href})", reason}

    assert broken == [], """
    ADR links that do not resolve to the record they name:

    #{inspect(broken, pretty: true)}
    """
  end

  defp link_problem(number, href) do
    path = Path.join(@adr_dir, href)

    cond do
      not File.exists?(path) -> :no_such_file
      not String.starts_with?(Path.basename(href), number <> "-") -> :wrong_record
      true -> nil
    end
  end

  test "no record is Deprecated, and none is wholly Superseded" do
    # ADR 0000, "How records relate": every reversal here has a replacement, so
    # `Deprecated` would be a status nothing takes; and every supersession is
    # partial, so a Status that opens with a bare `Superseded` would retire
    # decisions that are still load-bearing (rule 4).
    offenders =
      for {number, body} <- records(),
          status = status_line(body),
          status != nil,
          String.match?(status, ~r/^\s*(Deprecated|Superseded)\b/i),
          do: {number, status}

    assert offenders == [], """
    A record opens its Status with `Deprecated` or a bare `Superseded`:

    #{inspect(offenders, pretty: true)}

    Say what still stands — `Accepted, except decision 3 …, superseded by NNNN`.
    """
  end
end
