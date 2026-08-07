defmodule Baudrate.Media.Proxy do
  @moduledoc """
  Signs and verifies URLs for the local media proxy.

  Baudrate never emits an `<img>` pointing at a third-party host: doing so would
  disclose every viewer's IP address, User-Agent, and reading times to every
  remote instance whose content appears on the page. Remote image URLs are
  instead rewritten to `/media/<signature>/<encoded-url>`, which
  `BaudrateWeb.MediaController` serves from a local, re-encoded copy.

  ## Signing

  The signature is an HMAC-SHA256 of the URL under a key derived from
  `secret_key_base`. Because it covers only the URL, the same remote URL always
  produces the same proxied path — which matters twice over:

    * browsers can cache the result, and
    * a LiveView re-render produces an identical `src`, so avatars do not
      generate a diff on every patch.

  `Phoenix.Token.sign/3` is deliberately not used: it embeds a timestamp, so
  every render would mint a different URL and defeat both properties.

  Signing also means the endpoint is **not an open proxy** — it can only ever be
  asked for a URL this instance itself emitted into a page.
  """

  @salt "baudrate media proxy v1"
  @signature_bytes 32

  @doc """
  Rewrites a remote image URL to its proxied path.

  Returns `nil` for `nil`, and passes any already-local path (`/uploads/...`,
  `/media/...`, or any other same-origin path) through untouched so the helper
  is safe to apply indiscriminately and is idempotent.
  """
  @spec url(String.t() | nil) :: String.t() | nil
  def url(nil), do: nil

  def url(remote_url) when is_binary(remote_url) do
    if remote?(remote_url) do
      "/media/#{sign(remote_url)}/#{Base.url_encode64(remote_url, padding: false)}"
    else
      remote_url
    end
  end

  def url(_), do: nil

  @doc """
  Returns true when the URL points at another origin.

  Protocol-relative URLs (`//host/path`) count as remote — they are the classic
  way to smuggle a third-party request past a scheme-matching filter.
  """
  @spec remote?(String.t() | any()) :: boolean()
  def remote?(url) when is_binary(url) do
    String.starts_with?(url, "http://") or
      String.starts_with?(url, "https://") or
      String.starts_with?(url, "//")
  end

  def remote?(_), do: false

  @doc """
  Verifies a proxied path's signature and returns the original URL.

  Returns `{:error, :bad_signature}` for a forged or tampered token,
  `{:error, :bad_encoding}` for a malformed payload, and
  `{:error, :not_remote}` if the decoded value is not a remote URL (which would
  otherwise let the endpoint be pointed at a local path).
  """
  @spec verify(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :bad_signature | :bad_encoding | :not_remote}
  def verify(signature, encoded) when is_binary(signature) and is_binary(encoded) do
    with {:ok, url} <- decode(encoded),
         :ok <- check_signature(signature, url),
         true <- remote?(url) do
      {:ok, url}
    else
      {:error, _reason} = error -> error
      false -> {:error, :not_remote}
    end
  end

  def verify(_, _), do: {:error, :bad_encoding}

  @doc false
  def sign(url) when is_binary(url) do
    :hmac
    |> :crypto.mac(:sha256, key(), url)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, @signature_bytes)
  end

  defp check_signature(signature, url) do
    if Plug.Crypto.secure_compare(signature, sign(url)) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp decode(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, url} -> {:ok, url}
      :error -> {:error, :bad_encoding}
    end
  end

  defp key do
    secret_key_base = Application.get_env(:baudrate, BaudrateWeb.Endpoint)[:secret_key_base]
    Plug.Crypto.KeyGenerator.generate(secret_key_base, @salt, length: 32)
  end
end
