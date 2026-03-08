defmodule Baudrate.Content.BoostsTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Content
  alias Baudrate.Content.{ArticleBoost, CommentBoost}

  import BaudrateWeb.ConnCase, only: [setup_user: 1]

  setup do
    user = setup_user("user")
    other = setup_user("user")
    {:ok, user: user, other: other}
  end

  defp create_test_article(user) do
    slug = "boost-test-#{System.unique_integer([:positive])}"

    {:ok, %{article: article}} =
      Content.create_article(
        %{"title" => "Boost Test", "body" => "Body", "slug" => slug, "user_id" => user.id},
        []
      )

    article
  end

  defp create_test_comment(user, article) do
    {:ok, comment} =
      Content.create_comment(%{
        "body" => "Test comment",
        "article_id" => article.id,
        "user_id" => user.id
      })

    comment
  end

  # --- Article Boosts ---

  describe "boost_article/2" do
    test "creates a boost with an AP ID", %{user: user, other: other} do
      article = create_test_article(user)
      {:ok, boost} = Content.boost_article(other.id, article.id)
      assert boost.article_id == article.id
      assert boost.user_id == other.id
      assert boost.ap_id =~ "#announce-"
    end

    test "returns error on duplicate boost", %{user: user, other: other} do
      article = create_test_article(user)
      {:ok, _} = Content.boost_article(other.id, article.id)
      {:error, _changeset} = Content.boost_article(other.id, article.id)
    end
  end

  describe "unboost_article/2" do
    test "removes the boost", %{user: user, other: other} do
      article = create_test_article(user)
      {:ok, _} = Content.boost_article(other.id, article.id)
      assert Content.article_boosted?(other.id, article.id)
      {1, _} = Content.unboost_article(other.id, article.id)
      refute Content.article_boosted?(other.id, article.id)
    end
  end

  describe "article_boosted?/2" do
    test "returns true when boosted, false otherwise", %{user: user, other: other} do
      article = create_test_article(user)
      refute Content.article_boosted?(other.id, article.id)
      {:ok, _} = Content.boost_article(other.id, article.id)
      assert Content.article_boosted?(other.id, article.id)
    end
  end

  describe "count_article_boosts/1" do
    test "counts boosts on an article", %{user: user, other: other} do
      article = create_test_article(user)
      assert Content.count_article_boosts(article) == 0
      {:ok, _} = Content.boost_article(other.id, article.id)
      assert Content.count_article_boosts(article) == 1
    end
  end

  describe "toggle_article_boost/2" do
    test "creates a boost on first toggle", %{user: user, other: other} do
      article = create_test_article(user)
      {:ok, %ArticleBoost{}} = Content.toggle_article_boost(other.id, article.id)
      assert Content.article_boosted?(other.id, article.id)
    end

    test "removes boost on second toggle", %{user: user, other: other} do
      article = create_test_article(user)
      {:ok, %ArticleBoost{}} = Content.toggle_article_boost(other.id, article.id)
      {:ok, :removed} = Content.toggle_article_boost(other.id, article.id)
      refute Content.article_boosted?(other.id, article.id)
    end

    test "rejects self-boost", %{user: user} do
      article = create_test_article(user)
      assert {:error, :self_boost} = Content.toggle_article_boost(user.id, article.id)
    end

    test "rejects boost on deleted article", %{user: user, other: other} do
      article = create_test_article(user)
      {:ok, _} = Content.soft_delete_article(article)
      assert {:error, :deleted} = Content.toggle_article_boost(other.id, article.id)
    end
  end

  describe "article_boosts_by_user/2" do
    test "returns MapSet of boosted article IDs", %{user: user, other: other} do
      a1 = create_test_article(user)
      a2 = create_test_article(user)
      {:ok, _} = Content.boost_article(other.id, a1.id)

      result = Content.article_boosts_by_user(other.id, [a1.id, a2.id])
      assert MapSet.member?(result, a1.id)
      refute MapSet.member?(result, a2.id)
    end

    test "returns empty MapSet for empty list", %{other: other} do
      assert Content.article_boosts_by_user(other.id, []) == MapSet.new()
    end
  end

  describe "article_boost_counts/1" do
    test "returns map of boost counts", %{user: user, other: other} do
      a1 = create_test_article(user)
      {:ok, _} = Content.boost_article(other.id, a1.id)

      counts = Content.article_boost_counts([a1.id])
      assert Map.get(counts, a1.id) == 1
    end

    test "returns empty map for empty list" do
      assert Content.article_boost_counts([]) == %{}
    end
  end

  # --- Comment Boosts ---

  describe "boost_comment/2" do
    test "creates a boost with an AP ID", %{user: user, other: other} do
      article = create_test_article(user)
      comment = create_test_comment(user, article)
      {:ok, boost} = Content.boost_comment(other.id, comment.id)
      assert boost.comment_id == comment.id
      assert boost.user_id == other.id
      assert boost.ap_id =~ "#comment-announce-"
    end
  end

  describe "toggle_comment_boost/2" do
    test "creates a boost on first toggle", %{user: user, other: other} do
      article = create_test_article(user)
      comment = create_test_comment(user, article)
      {:ok, %CommentBoost{}} = Content.toggle_comment_boost(other.id, comment.id)
      assert Content.comment_boosted?(other.id, comment.id)
    end

    test "removes boost on second toggle", %{user: user, other: other} do
      article = create_test_article(user)
      comment = create_test_comment(user, article)
      {:ok, %CommentBoost{}} = Content.toggle_comment_boost(other.id, comment.id)
      {:ok, :removed} = Content.toggle_comment_boost(other.id, comment.id)
      refute Content.comment_boosted?(other.id, comment.id)
    end

    test "rejects self-boost", %{user: user} do
      article = create_test_article(user)
      comment = create_test_comment(user, article)
      assert {:error, :self_boost} = Content.toggle_comment_boost(user.id, comment.id)
    end

    test "rejects boost on deleted comment", %{user: user, other: other} do
      article = create_test_article(user)
      comment = create_test_comment(user, article)
      {:ok, _} = Content.soft_delete_comment(comment)
      assert {:error, :deleted} = Content.toggle_comment_boost(other.id, comment.id)
    end
  end

  describe "comment_boosts_by_user/2" do
    test "returns MapSet of boosted comment IDs", %{user: user, other: other} do
      article = create_test_article(user)
      c1 = create_test_comment(user, article)
      c2 = create_test_comment(user, article)
      {:ok, _} = Content.boost_comment(other.id, c1.id)

      result = Content.comment_boosts_by_user(other.id, [c1.id, c2.id])
      assert MapSet.member?(result, c1.id)
      refute MapSet.member?(result, c2.id)
    end
  end

  describe "comment_boost_counts/1" do
    test "returns map of boost counts", %{user: user, other: other} do
      article = create_test_article(user)
      c1 = create_test_comment(user, article)
      {:ok, _} = Content.boost_comment(other.id, c1.id)

      counts = Content.comment_boost_counts([c1.id])
      assert Map.get(counts, c1.id) == 1
    end
  end

  # --- Remote Boosts ---

  describe "create_remote_article_boost/1" do
    test "creates a remote article boost", %{user: user} do
      article = create_test_article(user)
      remote_actor = insert_remote_actor()

      {:ok, boost} =
        Content.create_remote_article_boost(%{
          ap_id: "https://remote.example/activities/#{System.unique_integer([:positive])}",
          article_id: article.id,
          remote_actor_id: remote_actor.id
        })

      assert boost.article_id == article.id
      assert boost.remote_actor_id == remote_actor.id
    end
  end

  describe "create_remote_comment_boost/1" do
    test "creates a remote comment boost", %{user: user} do
      article = create_test_article(user)
      comment = create_test_comment(user, article)
      remote_actor = insert_remote_actor()

      {:ok, boost} =
        Content.create_remote_comment_boost(%{
          ap_id: "https://remote.example/activities/#{System.unique_integer([:positive])}",
          comment_id: comment.id,
          remote_actor_id: remote_actor.id
        })

      assert boost.comment_id == comment.id
      assert boost.remote_actor_id == remote_actor.id
    end
  end

  describe "delete_article_boost_by_ap_id/1" do
    test "deletes by ap_id", %{user: user, other: other} do
      article = create_test_article(user)
      {:ok, boost} = Content.boost_article(other.id, article.id)
      assert Content.article_boosted?(other.id, article.id)

      {1, _} = Content.delete_article_boost_by_ap_id(boost.ap_id)
      refute Content.article_boosted?(other.id, article.id)
    end
  end

  describe "delete_comment_boost_by_ap_id/1" do
    test "deletes by ap_id", %{user: user, other: other} do
      article = create_test_article(user)
      comment = create_test_comment(user, article)
      {:ok, boost} = Content.boost_comment(other.id, comment.id)
      assert Content.comment_boosted?(other.id, comment.id)

      {1, _} = Content.delete_comment_boost_by_ap_id(boost.ap_id)
      refute Content.comment_boosted?(other.id, comment.id)
    end
  end

  # --- Helpers ---

  defp insert_remote_actor do
    uniq = System.unique_integer([:positive])

    Baudrate.Repo.insert!(%Baudrate.Federation.RemoteActor{
      ap_id: "https://remote.example/users/actor-#{uniq}",
      username: "actor#{uniq}",
      domain: "remote.example",
      inbox: "https://remote.example/users/actor-#{uniq}/inbox",
      public_key_pem: "fake-key",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end
end
