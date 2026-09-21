defmodule Baudrate.Federation.RemoteFollow do
  @moduledoc """
  Sending a visitor to their own instance to follow someone here.

  A reader arrives from the fediverse, finds a user or a board worth
  following, and has no account here — following from an account they already
  have is the whole point of federation, and until now the site offered them
  nothing but a handle to copy.

  The mechanism is the OStatus subscribe template, which every major
  implementation still advertises in its WebFinger document:

      {"rel": "http://ostatus.org/schema/1.0/subscribe",
       "template": "https://mastodon.social/authorize_interaction?uri={uri}"}

  So the visitor gives us **their** handle, we ask **their** server where its
  follow page is, and we substitute the local actor's URI into the answer.
  Discovering it beats guessing: Mastodon uses `/authorize_interaction`,
  Akkoma `/ostatus_subscribe`, Misskey `/authorize-follow`, and a guess would
  work on one of them.

  ## What this module refuses, and why each one matters

  The domain comes from a visitor and the template comes from that domain, so
  both are attacker-chosen and neither may be trusted:

    * **A blocked domain.** `Discovery.webfinger_document/3` passes
      `refuse_blocked: true` (ADR 0030 decision 9) — without it, a guest
      typing a handle would make this instance fetch from a server its
      operator has blocked.
    * **A template that is not HTTPS**, or that is **not on the domain the
      visitor typed.** Otherwise a hostile server answers WebFinger with
      `https://evil.example/{uri}` and we render a link to it, on our page,
      about to receive the visitor. The host check is what makes this a
      redirect to *their* instance rather than to anywhere at all.
    * **A template with no `{uri}` placeholder.** A template that cannot carry
      the actor is not a subscribe template, and substituting nothing would
      send the visitor to a bare page with no idea why they are there.

  Nothing here writes anything, so ADR 0047 leaves it callable directly rather
  than through the `Baudrate.Federation` facade.
  """

  alias Baudrate.Federation.Discovery

  require Logger

  # Somebody is watching a page load. The federation defaults (30 s per read,
  # 60 s whole-request) are sized for a delivery retrying in the background.
  @timeout_ms 5_000

  @subscribe_rel "http://ostatus.org/schema/1.0/subscribe"

  @typedoc "A `user@domain` pair taken from a handle the visitor typed."
  @type handle :: {String.t(), String.t()}

  @doc """
  Resolves the URL that lets `handle`'s instance follow `actor_uri`.

  Returns `{:ok, url}`, or `{:error, reason}` for every refusal above. Callers
  render one message for all of them: which of these failed is information
  about somebody else's server, and telling a visitor them apart turns this
  into a probe.
  """
  @spec subscribe_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def subscribe_url(handle, actor_uri) when is_binary(handle) and is_binary(actor_uri) do
    with {:ok, {user, domain}} <- parse_handle(handle),
         {:ok, jrd} <- fetch(user, domain),
         {:ok, template} <- extract_template(jrd),
         :ok <- validate_template(template, domain) do
      {:ok, String.replace(template, "{uri}", URI.encode_www_form(actor_uri))}
    end
  end

  @doc """
  Splits `@user@domain` (or `user@domain`) into its parts.

  Deliberately not `URI.parse/1`, for the reason `BaudrateWeb.Helpers`
  records about `local_path/2`: it accepts several strings a browser resolves
  differently from Elixir, and this value is about to become part of a URL.
  A handle is a narrow shape, so it is checked as one.
  """
  @spec parse_handle(String.t()) :: {:ok, handle()} | {:error, :invalid_handle}
  def parse_handle(handle) when is_binary(handle) do
    handle
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split("@")
    |> case do
      [user, domain] -> validate_parts(user, domain)
      _ -> {:error, :invalid_handle}
    end
  end

  def parse_handle(_), do: {:error, :invalid_handle}

  defp validate_parts(user, domain) do
    if valid_user?(user) and valid_domain?(domain),
      do: {:ok, {user, String.downcase(domain)}},
      else: {:error, :invalid_handle}
  end

  # Conservative on purpose. Anything outside these shapes is refused rather
  # than escaped, because the value is interpolated into a URL and a rejected
  # handle costs a visitor one retype.
  defp valid_user?(user),
    do: user != "" and byte_size(user) <= 64 and Regex.match?(~r/^[A-Za-z0-9._-]+$/, user)

  defp valid_domain?(domain) do
    domain != "" and byte_size(domain) <= 253 and
      Regex.match?(
        ~r/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/,
        domain
      )
  end

  defp fetch(user, domain) do
    case Discovery.webfinger_document(user, domain, timeout: @timeout_ms) do
      {:ok, jrd} ->
        {:ok, jrd}

      {:error, reason} ->
        Logger.info("remote_follow.webfinger_failed: domain=#{domain} reason=#{inspect(reason)}")
        {:error, :lookup_failed}
    end
  end

  defp extract_template(%{"links" => links}) when is_list(links) do
    links
    |> Enum.find(fn
      %{"rel" => @subscribe_rel, "template" => t} when is_binary(t) -> true
      _ -> false
    end)
    |> case do
      %{"template" => template} -> {:ok, template}
      nil -> {:error, :no_subscribe_template}
    end
  end

  defp extract_template(_), do: {:error, :no_subscribe_template}

  defp validate_template(template, domain) do
    uri = URI.parse(template)

    cond do
      not String.contains?(template, "{uri}") -> {:error, :template_has_no_uri}
      uri.scheme != "https" -> {:error, :template_not_https}
      normalize_host(uri.host) != domain -> {:error, :template_off_domain}
      true -> :ok
    end
  end

  defp normalize_host(nil), do: nil
  defp normalize_host(host), do: String.downcase(host)
end
