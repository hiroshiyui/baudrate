defmodule Baudrate.Federation.ActorRenderer do
  @moduledoc """
  Builds ActivityPub JSON-LD actor representations for local actors.

  Produces `Person` (user), `Group` (board), and `Organization` (site)
  actor maps suitable for serving at AP actor endpoints.
  """

  alias Baudrate.Content
  alias Baudrate.Content.Board
  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Federation.KeyStore

  @as_context "https://www.w3.org/ns/activitystreams"
  @security_context "https://w3id.org/security/v1"
  @schema_context %{
    "schema" => "http://schema.org/",
    "PropertyValue" => "schema:PropertyValue",
    "value" => "schema:value"
  }

  @doc """
  Returns a Person JSON-LD map for the given user.
  """
  def user_actor(user) do
    uri = actor_uri(:user, user.username)

    %{
      "@context" => [@as_context, @security_context, @schema_context],
      "id" => uri,
      "type" => "Person",
      "preferredUsername" => user.username,
      "inbox" => "#{uri}/inbox",
      "outbox" => "#{uri}/outbox",
      "followers" => "#{uri}/followers",
      "following" => "#{uri}/following",
      "url" => "#{base_url()}/@#{user.username}",
      "published" => DateTime.to_iso8601(user.inserted_at),
      "endpoints" => %{"sharedInbox" => "#{base_url()}/ap/inbox"},
      "publicKey" => %{
        "id" => "#{uri}#main-key",
        "owner" => uri,
        "publicKeyPem" => KeyStore.get_public_key_pem(user)
      }
    }
    |> put_if("name", user.display_name)
    |> put_if("summary", render_bio_html(user.bio))
    |> put_if("icon", user_avatar_icon(user))
    |> put_if("attachment", render_profile_fields(user.profile_fields))
  end

  @doc """
  Returns a Group JSON-LD map for the given board.
  """
  def board_actor(board) do
    uri = actor_uri(:board, board.slug)

    sub_boards =
      Content.list_sub_boards(board)
      |> Enum.filter(&Board.federated?/1)
      |> Enum.map(&actor_uri(:board, &1.slug))

    parent_uri =
      if board.parent_id do
        parent = Repo.get(Board, board.parent_id)

        if parent && Board.federated?(parent),
          do: actor_uri(:board, parent.slug)
      end

    %{
      "@context" => [@as_context, @security_context],
      "id" => uri,
      "type" => "Group",
      "preferredUsername" => board.slug,
      "name" => board.name,
      "summary" => board.description,
      "inbox" => "#{uri}/inbox",
      "outbox" => "#{uri}/outbox",
      "followers" => "#{uri}/followers",
      "following" => "#{uri}/following",
      "url" => "#{base_url()}/boards/#{board.slug}",
      "endpoints" => %{"sharedInbox" => "#{base_url()}/ap/inbox"},
      "publicKey" => %{
        "id" => "#{uri}#main-key",
        "owner" => uri,
        "publicKeyPem" => KeyStore.get_public_key_pem(board)
      }
    }
    |> put_if("baudrate:parentBoard", parent_uri)
    |> put_if("baudrate:subBoards", if(sub_boards != [], do: sub_boards))
  end

  @doc """
  Returns an Organization JSON-LD map for the site actor.
  """
  def site_actor do
    uri = actor_uri(:site, nil)
    site_name = Setup.get_setting("site_name") || "Baudrate"

    {:ok, %{public_pem: public_pem}} = KeyStore.ensure_site_keypair()

    %{
      "@context" => [@as_context, @security_context],
      "id" => uri,
      "type" => "Organization",
      "preferredUsername" => "site",
      "name" => site_name,
      "inbox" => "#{uri}/inbox",
      "outbox" => "#{uri}/outbox",
      "followers" => "#{uri}/followers",
      "url" => base_url(),
      "endpoints" => %{"sharedInbox" => "#{base_url()}/ap/inbox"},
      "publicKey" => %{
        "id" => "#{uri}#main-key",
        "owner" => uri,
        "publicKeyPem" => public_pem
      }
    }
  end

  @doc false
  def render_bio_html(nil), do: nil
  def render_bio_html(""), do: nil

  def render_bio_html(bio) when is_binary(bio) do
    bio
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> String.replace("\n", "<br>")
    |> Baudrate.Content.Markdown.linkify_hashtags()
  end

  # --- Private ---

  defp render_profile_fields(nil), do: nil
  defp render_profile_fields([]), do: nil

  defp render_profile_fields(fields) when is_list(fields) do
    rendered =
      fields
      |> Enum.filter(fn
        %{"name" => name, "value" => value} -> name != "" and value != ""
        _ -> false
      end)
      |> Enum.map(fn %{"name" => name, "value" => value} ->
        %{
          "type" => "PropertyValue",
          "name" => name,
          "value" => Phoenix.HTML.html_escape(value) |> Phoenix.HTML.safe_to_string()
        }
      end)

    if rendered == [], do: nil, else: rendered
  end

  defp user_avatar_icon(%{avatar_id: nil}), do: nil

  defp user_avatar_icon(%{avatar_id: avatar_id}) do
    %{
      "type" => "Image",
      "mediaType" => "image/webp",
      "url" => "#{base_url()}#{Baudrate.Avatar.avatar_url(avatar_id, 48)}"
    }
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, ""), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp actor_uri(type, id), do: Baudrate.Federation.actor_uri(type, id)
  defp base_url, do: Baudrate.Federation.base_url()
end
