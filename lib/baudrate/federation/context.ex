defmodule Baudrate.Federation.Context do
  @moduledoc """
  The JSON-LD `@context` values this instance publishes.

  One definition, because a context that differs between an object and the
  activity carrying it is a document that means two things. Before this, four
  modules each held their own copy of the ActivityStreams URI and the
  `baudrate:*` terms were used in two of them **without being declared
  anywhere** — which makes them undefined terms in JSON-LD, dropped by any
  consumer that expands the document rather than reading it as plain JSON.

  ## The extension terms

  `@namespace` is the prefix for fields this software adds to the standard
  vocabulary. Like Mastodon's `http://joinmastodon.org/ns#` and Lemmy's
  `https://join-lemmy.org/ns#`, it identifies the vocabulary rather than
  serving a document — it does not have to dereference, and none of theirs
  does either. It is the **software's** namespace, not the instance's, so it
  must not be built from `base_url/0`: two Baudrate instances use the same
  terms and a per-instance prefix would make them incomparable.

  | Term | On | Meaning |
  |---|---|---|
  | `baudrate:pinned` | Article | pinned in its board |
  | `baudrate:locked` | Article | closed to new comments |
  | `baudrate:commentCount` | Article | comments, excluding deleted |
  | `baudrate:likeCount` | Article | likes |
  | `baudrate:parentBoard` | Group | the board this one sits under |
  | `baudrate:subBoards` | Group | the federated boards beneath it |

  Adding a `baudrate:` field means adding a row here. A term with no row is a
  term nobody outside this repository can interpret.

  ## Other vocabularies' terms

  Three terms a `Person` carries come from elsewhere, and are declared the
  way Mastodon declares them (ADR 0073):

  | Term | Expands to | Meaning |
  |---|---|---|
  | `manuallyApprovesFollowers` | `as:manuallyApprovesFollowers` | follows wait for the member's approval |
  | `discoverable` | `toot:discoverable` | may be listed in directories and member search |
  | `indexable` | `toot:indexable` | may be indexed by search |
  """

  @as "https://www.w3.org/ns/activitystreams"
  @security "https://w3id.org/security/v1"
  @namespace "https://github.com/hiroshiyui/baudrate/ns#"

  @terms %{
    "baudrate" => @namespace,
    "schema" => "http://schema.org/",
    "PropertyValue" => "schema:PropertyValue",
    "value" => "schema:value",
    "as" => "https://www.w3.org/ns/activitystreams#",
    "manuallyApprovesFollowers" => "as:manuallyApprovesFollowers",
    "toot" => "http://joinmastodon.org/ns#",
    "discoverable" => "toot:discoverable",
    "indexable" => "toot:indexable"
  }

  @doc "The ActivityStreams 2.0 context URI."
  @spec as() :: String.t()
  def as, do: @as

  @doc "The namespace URI for this software's extension terms."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  Context for an object that may carry `baudrate:*` terms — an Article, a
  Note, a Question.
  """
  @spec object() :: [String.t() | map()]
  def object, do: [@as, @terms]

  @doc """
  Context for an outgoing activity. Includes the security vocabulary, which
  `publicKey` resolution needs, and the extension terms, because the object
  is embedded in the activity and a consumer expands the whole document.
  """
  @spec activity() :: [String.t() | map()]
  def activity, do: [@as, @security, @terms]

  @doc """
  Context for an actor document. The same as `activity/0` — a `Group` carries
  `baudrate:parentBoard` and a `Person` carries `schema:PropertyValue`
  attachments, and one context for both beats two that drift.
  """
  @spec actor() :: [String.t() | map()]
  def actor, do: activity()
end
