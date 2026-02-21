defmodule Baudrate.Federation.Delivery do
  @moduledoc """
  Minimal delivery module for sending Accept(Follow) responses.

  Signs the outgoing request with the local actor's private key
  and POSTs to the remote actor's inbox.
  """

  require Logger

  alias Baudrate.Federation
  alias Baudrate.Federation.{HTTPClient, HTTPSignature, KeyStore}

  @as_context "https://www.w3.org/ns/activitystreams"

  @doc """
  Sends an Accept(Follow) activity to the remote actor's inbox.

  Builds the JSON-LD, signs it with the local actor's private key,
  and POSTs to `remote_actor.inbox`.
  """
  def send_accept(follow_activity, local_actor_uri, remote_actor) do
    accept = build_accept(follow_activity, local_actor_uri)
    body = Jason.encode!(accept)

    with {:ok, private_key_pem} <- get_private_key(local_actor_uri),
         key_id = "#{local_actor_uri}#main-key",
         headers = HTTPSignature.sign(:post, remote_actor.inbox, body, private_key_pem, key_id),
         header_list = headers_to_list(headers) do
      HTTPClient.post(remote_actor.inbox, body, header_list)
    end
  end

  defp build_accept(follow_activity, local_actor_uri) do
    %{
      "@context" => @as_context,
      "id" => "#{local_actor_uri}#accept-#{System.unique_integer([:positive])}",
      "type" => "Accept",
      "actor" => local_actor_uri,
      "object" => follow_activity
    }
  end

  defp get_private_key(actor_uri) do
    base = Federation.base_url()

    cond do
      String.starts_with?(actor_uri, "#{base}/ap/users/") ->
        username = actor_uri |> String.replace_prefix("#{base}/ap/users/", "")
        user = Baudrate.Repo.get_by!(Baudrate.Setup.User, username: username)
        KeyStore.decrypt_private_key(user)

      String.starts_with?(actor_uri, "#{base}/ap/boards/") ->
        slug = actor_uri |> String.replace_prefix("#{base}/ap/boards/", "")
        board = Baudrate.Repo.get_by!(Baudrate.Content.Board, slug: slug)
        KeyStore.decrypt_private_key(board)

      String.starts_with?(actor_uri, "#{base}/ap/site") ->
        KeyStore.decrypt_site_private_key()

      true ->
        {:error, :unknown_actor}
    end
  end

  defp headers_to_list(headers) do
    Enum.map(headers, fn {k, v} -> {k, v} end)
  end
end
