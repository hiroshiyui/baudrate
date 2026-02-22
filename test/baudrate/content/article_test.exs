defmodule Baudrate.Content.ArticleTest do
  use Baudrate.DataCase

  alias Baudrate.Content.Article

  describe "body length validation" do
    test "changeset rejects body exceeding 65536 bytes" do
      attrs = %{
        title: "Test",
        body: String.duplicate("x", 65_537),
        slug: "test-slug"
      }

      changeset = Article.changeset(%Article{}, attrs)
      assert %{body: ["should be at most 65536 character(s)"]} = errors_on(changeset)
    end

    test "changeset accepts body at exactly 65536 bytes" do
      attrs = %{
        title: "Test",
        body: String.duplicate("x", 65_536),
        slug: "test-slug"
      }

      changeset = Article.changeset(%Article{}, attrs)
      refute Map.has_key?(errors_on(changeset), :body)
    end

    test "update_changeset rejects oversized body" do
      changeset = Article.update_changeset(%Article{}, %{title: "T", body: String.duplicate("x", 65_537)})
      assert %{body: ["should be at most 65536 character(s)"]} = errors_on(changeset)
    end

    test "remote_changeset rejects oversized body" do
      attrs = %{
        title: "T",
        body: String.duplicate("x", 65_537),
        slug: "test",
        ap_id: "https://example.com/1",
        remote_actor_id: 1
      }

      changeset = Article.remote_changeset(%Article{}, attrs)
      assert %{body: ["should be at most 65536 character(s)"]} = errors_on(changeset)
    end

    test "update_remote_changeset rejects oversized body" do
      changeset = Article.update_remote_changeset(%Article{}, %{title: "T", body: String.duplicate("x", 65_537)})
      assert %{body: ["should be at most 65536 character(s)"]} = errors_on(changeset)
    end
  end
end
