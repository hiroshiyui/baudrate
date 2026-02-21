defmodule Baudrate.Federation.KeyStore do
  @moduledoc """
  Generates and manages RSA-2048 keypairs for ActivityPub actors.

  Each actor (user, board, site) gets a unique RSA-2048 keypair.
  Public keys are stored as PEM-encoded text; private keys are
  encrypted at rest using `Baudrate.Federation.KeyVault` (AES-256-GCM).

  Site-level keys are stored in the `settings` table via `Setup.set_setting/2`,
  with the encrypted private key Base64-encoded for string storage.
  """

  alias Baudrate.Repo
  alias Baudrate.Setup
  alias Baudrate.Federation.KeyVault

  @doc """
  Generates an RSA-2048 keypair and returns `{public_pem, private_pem}`.
  """
  def generate_keypair do
    rsa_key = :public_key.generate_key({:rsa, 2048, 65_537})

    private_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa_key)])

    # Extract public key from private key
    {:RSAPrivateKey, :"two-prime", n, e, _, _, _, _, _, _, _} = rsa_key
    public_key = {:RSAPublicKey, n, e}

    public_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)])

    {public_pem, private_pem}
  end

  @doc """
  Ensures the user has an ActivityPub keypair. If `ap_public_key` is nil,
  generates a new keypair, encrypts the private key, and stores both.

  Returns `{:ok, user}` with the updated user.
  """
  def ensure_user_keypair(%{ap_public_key: key} = user) when is_binary(key), do: {:ok, user}

  def ensure_user_keypair(user) do
    {public_pem, private_pem} = generate_keypair()
    encrypted = KeyVault.encrypt(private_pem)

    user
    |> Baudrate.Setup.User.ap_key_changeset(%{
      ap_public_key: public_pem,
      ap_private_key_encrypted: encrypted
    })
    |> Repo.update()
  end

  @doc """
  Ensures the board has an ActivityPub keypair. If `ap_public_key` is nil,
  generates a new keypair, encrypts the private key, and stores both.

  Returns `{:ok, board}` with the updated board.
  """
  def ensure_board_keypair(%{ap_public_key: key} = board) when is_binary(key), do: {:ok, board}

  def ensure_board_keypair(board) do
    {public_pem, private_pem} = generate_keypair()
    encrypted = KeyVault.encrypt(private_pem)

    board
    |> Baudrate.Content.Board.ap_key_changeset(%{
      ap_public_key: public_pem,
      ap_private_key_encrypted: encrypted
    })
    |> Repo.update()
  end

  @doc """
  Ensures the site has an ActivityPub keypair stored in the settings table.

  Returns `{:ok, %{public_pem: public_pem}}`.
  """
  def ensure_site_keypair do
    case Setup.get_setting("ap_site_public_key") do
      nil ->
        {public_pem, private_pem} = generate_keypair()
        encrypted = KeyVault.encrypt(private_pem)
        encoded = Base.encode64(encrypted)

        {:ok, _} = Setup.set_setting("ap_site_public_key", public_pem)
        {:ok, _} = Setup.set_setting("ap_site_private_key_encrypted", encoded)
        {:ok, %{public_pem: public_pem}}

      public_pem ->
        {:ok, %{public_pem: public_pem}}
    end
  end

  @doc """
  Returns the PEM-encoded public key for a user or board.
  """
  def get_public_key_pem(%{ap_public_key: pem}) when is_binary(pem), do: pem
  def get_public_key_pem(_), do: nil

  @doc """
  Returns the site's PEM-encoded public key from settings.
  """
  def get_site_public_key_pem do
    Setup.get_setting("ap_site_public_key")
  end

  @doc """
  Decrypts and returns the PEM-encoded private key for a user or board.

  Returns `{:ok, private_pem}` or `:error`.
  """
  def decrypt_private_key(%{ap_private_key_encrypted: encrypted}) when is_binary(encrypted) do
    KeyVault.decrypt(encrypted)
  end

  def decrypt_private_key(_), do: :error

  @doc """
  Decrypts and returns the site's PEM-encoded private key from settings.

  Returns `{:ok, private_pem}` or `:error`.
  """
  def decrypt_site_private_key do
    case Setup.get_setting("ap_site_private_key_encrypted") do
      nil ->
        :error

      encoded ->
        case Base.decode64(encoded) do
          {:ok, encrypted} -> KeyVault.decrypt(encrypted)
          :error -> :error
        end
    end
  end
end
