defmodule Baudrate.Moderation.ContentFilter do
  @moduledoc """
  Schema for an admin-managed filter on words, text or linked domains
  (Phase 5D, ADR 0065).

  ## Three kinds, and none of them is a regular expression

    * `word` — a whole word or a phrase: `casino` matches "Casino night" but
      not "casinos". Letters and numbers are what count; punctuation and
      spacing between words are ignored, so `buy followers` also matches
      "Buy... followers!". Languages written without spaces between words have
      no word boundaries to find, so they need `substring`.
    * `substring` — anywhere in the text: `casino` matches "casinos" and
      "onlinecasino". A `*` stands for any run of letters or numbers inside
      one word, so `c*sino` matches "cassino"; a pattern with a `*` may hold
      only letters, numbers and `*`.
    * `domain` — a link to the host or to any host under it: `spam.example`
      matches `https://spam.example/x` and `https://www.spam.example/`. An
      internationalized name is written in its ASCII (`xn--`) form, which is
      how a browser sends it.

  An admin-entered regular expression is refused on purpose. One that
  backtracks catastrophically hangs every write on the instance, and the
  person typing it is the one least placed to know. These three kinds are
  matched by `Baudrate.Moderation.ContentFilters` in time proportional to the
  text, whatever the pattern.

  ## Actions (P5-D3)

    * `block` — refuse the post, with a message that does not name the pattern.
    * `hold` — hold it for a moderator (`Baudrate.Moderation.HeldPosts`).
      Where nothing can be held — a bot, an edit, a timeline reply, anything
      arriving over federation — it is flagged instead, except that an edit is
      refused, because an edit that is merely flagged has already been
      published.
    * `flag` — publish it and open a report.

  Remote content can only be dropped or flagged.

  The pattern is stored normalized — NFKC, lower case, one space between
  words — so `Ｃａｓｉｎｏ` and `casino` are the same filter, and the unique
  index on `(kind, pattern)` compares what the matcher compares.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Baudrate.Setup.User

  @kinds ~w(word substring domain)
  @actions ~w(block hold flag)
  @scopes ~w(local remote both)
  @max_pattern 200
  @max_note 500

  schema "content_filters" do
    field :pattern, :string
    field :kind, :string
    field :action, :string
    field :applies_to, :string, default: "both"
    field :enabled, :boolean, default: true
    field :note, :string

    belongs_to :created_by, User

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc "The three kinds of pattern."
  def kinds, do: @kinds

  @doc "The three actions."
  def actions, do: @actions

  @doc "Where a filter applies."
  def scopes, do: @scopes

  @doc "The longest pattern accepted."
  def max_pattern_length, do: @max_pattern

  @doc """
  Changeset for creating or editing a filter.

  `created_by_id` is not castable: `Baudrate.Moderation.ContentFilters` sets it
  from the acting admin.
  """
  def changeset(filter, attrs) do
    filter
    |> cast(attrs, [:pattern, :kind, :action, :applies_to, :enabled, :note])
    |> validate_required([:pattern, :kind, :action, :applies_to])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:applies_to, @scopes)
    |> validate_length(:note, max: @max_note)
    |> normalize_pattern()
    |> validate_length(:pattern, min: 1, max: @max_pattern)
    |> validate_pattern()
    |> unique_constraint(:pattern,
      name: :content_filters_kind_pattern_index,
      message: "is already a filter"
    )
  end

  defp normalize_pattern(changeset) do
    kind = get_field(changeset, :kind)

    update_change(changeset, :pattern, fn pattern ->
      case kind do
        "domain" -> normalize_domain(pattern)
        _ -> normalize_text(pattern)
      end
    end)
  end

  @doc """
  The normal form text and patterns are compared in: NFKC (so fullwidth and
  compatibility forms fold to the ordinary letters), invisible format
  characters removed (a zero-width space inside a word is the oldest way
  round a word filter), lower case, and every run of whitespace reduced to
  one space.
  """
  @spec normalize_text(String.t()) :: String.t()
  def normalize_text(text) when is_binary(text) do
    text
    |> nfkc()
    |> String.replace(~r/\p{Cf}+/u, "")
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
  end

  defp nfkc(text) do
    case :unicode.characters_to_nfkc_binary(text) do
      normalized when is_binary(normalized) -> normalized
      _ -> text
    end
  end

  @doc """
  Reduces a pasted URL, `@user@host` handle or `*.host` to a bare lower-case
  host, the way `Baudrate.Federation.DomainBlock.normalize_domain/1` does for
  domain blocks.
  """
  @spec normalize_domain(String.t()) :: String.t()
  def normalize_domain(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    host =
      if String.contains?(value, "://") do
        URI.parse(value).host || ""
      else
        value
        |> String.split("/", parts: 2)
        |> hd()
        |> String.split("@")
        |> List.last()
        |> String.split(":", parts: 2)
        |> hd()
      end

    host
    |> String.trim_leading("*.")
    |> String.trim(".")
  end

  # Judged whatever the other fields say, so the form can say what is wrong
  # with the pattern while the action is still unchosen.
  defp validate_pattern(changeset) do
    pattern = get_field(changeset, :pattern)

    if is_nil(pattern) or Keyword.has_key?(changeset.errors, :pattern),
      do: changeset,
      else: validate_pattern(changeset, pattern)
  end

  defp validate_pattern(changeset, pattern) do
    case get_field(changeset, :kind) do
      "domain" ->
        if Regex.match?(~r/\A[a-z0-9-]+(\.[a-z0-9-]+)+\z/, pattern),
          do: changeset,
          else: add_error(changeset, :pattern, "is not a domain name")

      "word" ->
        if words(pattern) == [],
          do: add_error(changeset, :pattern, "has no letters or numbers"),
          else: changeset

      "substring" ->
        cond do
          not String.contains?(pattern, "*") ->
            changeset

          Regex.match?(~r/\A[\p{L}\p{N}\p{M}*]+\z/u, pattern) and
              String.replace(pattern, "*", "") != "" ->
            changeset

          true ->
            add_error(
              changeset,
              :pattern,
              "with a * may hold only letters, numbers and *"
            )
        end

      _ ->
        changeset
    end
  end

  @doc """
  Splits normalized text into its words — the runs of letters, numbers and
  combining marks. Everything else is a break.
  """
  @spec words(String.t()) :: [String.t()]
  def words(text), do: String.split(text, ~r/[^\p{L}\p{N}\p{M}]+/u, trim: true)
end
