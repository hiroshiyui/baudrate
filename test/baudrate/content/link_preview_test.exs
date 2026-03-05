defmodule Baudrate.Content.LinkPreviewTest do
  use Baudrate.DataCase

  alias Baudrate.Content.LinkPreview

  describe "changeset/2" do
    test "valid attributes create a changeset with computed url_hash and domain" do
      changeset = LinkPreview.changeset(%LinkPreview{}, %{url: "https://example.com/page"})
      assert changeset.valid?
      assert get_change(changeset, :url_hash) == LinkPreview.hash_url("https://example.com/page")
      assert get_change(changeset, :domain) == "example.com"
    end

    test "requires url" do
      changeset = LinkPreview.changeset(%LinkPreview{}, %{})
      refute changeset.valid?
      assert %{url: ["can't be blank"]} = errors_on(changeset)
    end

    test "extracts domain from URL" do
      changeset = LinkPreview.changeset(%LinkPreview{}, %{url: "https://sub.EXAMPLE.COM/path"})
      assert get_change(changeset, :domain) == "sub.example.com"
    end
  end

  describe "fetched_changeset/2" do
    test "sets fetched_at when status is fetched" do
      preview = %LinkPreview{
        url: "https://example.com",
        url_hash: LinkPreview.hash_url("https://example.com")
      }

      changeset =
        LinkPreview.fetched_changeset(preview, %{
          title: "Example",
          description: "A test page",
          status: "fetched"
        })

      assert changeset.valid?
      assert get_change(changeset, :fetched_at)
    end

    test "validates title length" do
      preview = %LinkPreview{
        url: "https://example.com",
        url_hash: LinkPreview.hash_url("https://example.com")
      }

      changeset =
        LinkPreview.fetched_changeset(preview, %{
          title: String.duplicate("a", 301),
          status: "fetched"
        })

      refute changeset.valid?
      assert %{title: ["should be at most 300 character(s)"]} = errors_on(changeset)
    end

    test "validates status inclusion" do
      preview = %LinkPreview{
        url: "https://example.com",
        url_hash: LinkPreview.hash_url("https://example.com")
      }

      changeset = LinkPreview.fetched_changeset(preview, %{status: "invalid"})
      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "hash_url/1" do
    test "produces consistent SHA-256 hash" do
      hash1 = LinkPreview.hash_url("https://example.com")
      hash2 = LinkPreview.hash_url("https://example.com")
      assert hash1 == hash2
      assert byte_size(hash1) == 32
    end

    test "different URLs produce different hashes" do
      hash1 = LinkPreview.hash_url("https://example.com/a")
      hash2 = LinkPreview.hash_url("https://example.com/b")
      refute hash1 == hash2
    end
  end

  describe "database operations" do
    test "insert and enforce unique url_hash" do
      attrs = %{url: "https://example.com/unique"}

      {:ok, _preview} =
        %LinkPreview{}
        |> LinkPreview.changeset(attrs)
        |> Repo.insert()

      {:error, changeset} =
        %LinkPreview{}
        |> LinkPreview.changeset(attrs)
        |> Repo.insert()

      assert %{url_hash: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
