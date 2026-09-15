defmodule BaudrateWeb.Features.ComposerTest do
  use BaudrateWeb.FeatureCase, async: false

  alias Baudrate.Content.{ArticleImage, ArticleImageStorage}
  alias Baudrate.Repo

  @moduletag :feature

  setup do
    %{user: setup_user("user"), board: create_board(%{})}
  end

  feature "the Markdown toolbar previews the body", %{session: session, user: user, board: board} do
    session
    |> log_in_via_browser(user)
    |> visit("/boards/#{board.slug}/articles/new")
    |> fill_in(Query.css("#article_body"), with: "Some **bold** words")
    |> click(Query.css("#article_body-md-toolbar button[aria-label='Preview']"))
    |> assert_has(Query.css("#article_body-md-preview strong", text: "bold"))
  end

  feature "an unsent article is kept as a draft, restored, and cleared when posted", %{
    session: session,
    user: user,
    board: board
  } do
    title = "Draft title #{System.unique_integer([:positive])}"

    session
    |> log_in_via_browser(user)
    |> visit("/boards/#{board.slug}/articles/new")
    |> fill_in(Query.css("#article_title"), with: title)
    |> fill_in(Query.css("#article_body"), with: "Half-written thoughts")
    |> assert_has(Query.css("#draft-indicator-new", text: "Draft saved"))
    |> visit("/boards/#{board.slug}")
    |> visit("/boards/#{board.slug}/articles/new")

    # Restored on mount; the indicator fades out, so check the fields.
    assert wait_for_value(session, "article_title", title)
    assert field_value(session, "article_body") == "Half-written thoughts"

    session
    |> click(Query.css("#article-new-submit"))
    |> assert_has(Query.css("h1", text: title))
    |> visit("/boards/#{board.slug}/articles/new")
    |> assert_has(Query.css("#article_title"))

    assert field_value(session, "article_title") == ""
  end

  feature "an article with a poll is posted and voted on", %{
    session: session,
    user: user,
    board: board
  } do
    voter = setup_user("user")

    session
    |> log_in_via_browser(user)
    |> visit("/boards/#{board.slug}/articles/new")
    |> fill_in(Query.css("#article_title"), with: "Lunch vote")
    |> fill_in(Query.css("#article_body"), with: "Where shall we eat?")
    |> click(Query.css("#article-new-toggle-poll"))
    |> fill_in(Query.css("#article-new-poll-option-0"), with: "Noodles")
    |> fill_in(Query.css("#article-new-poll-option-1"), with: "Curry")
    |> click(Query.css("#article-new-submit"))
    |> assert_has(Query.css("#article-poll", text: "Curry"))
    |> log_out_via_browser()
    |> log_in_via_browser(voter)
    |> visit(current_article_path(user))
    |> click(Query.css("#article-poll-vote-options label", text: "Curry"))
    |> click(Query.css("#poll-vote-submit"))
    |> assert_has(Query.css("#article-poll", text: "1 voter"))
    |> assert_has(Query.css(".article-poll-result", text: "100.0% (1)"))
  end

  feature "an image uploads, shows a thumbnail, and is attached to the posted article", %{
    session: session,
    user: user,
    board: board
  } do
    png = Path.join(System.tmp_dir!(), "composer-test-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(64, 48, color: [30, 120, 200])
    Image.write!(image, png)

    on_exit(fn -> File.rm(png) end)

    session =
      session
      |> log_in_via_browser(user)
      |> visit("/boards/#{board.slug}/articles/new")

    # Browser and test share a filesystem, so the path is typed into the file
    # input (Wallaby's attach_file uploads through a Selenium endpoint that
    # the W3C shim does not support).
    session
    |> find(Query.css(".article-new-image-input"))
    |> Wallaby.Element.set_value(png)

    session
    |> assert_has(Query.css(".article-new-image img"))
    |> fill_in(Query.css("#article_title"), with: "With a picture")
    |> fill_in(Query.css("#article_body"), with: "See attached.")
    |> click(Query.css("#article-new-submit"))
    |> assert_has(Query.css("h1", text: "With a picture"))

    [attached] = Repo.all(ArticleImage)
    stored = Path.join(ArticleImageStorage.upload_dir(), attached.filename)
    assert attached.article_id
    assert String.ends_with?(attached.filename, ".webp")
    assert File.exists?(stored)

    File.rm!(stored)
  end

  defp wait_for_value(session, id, expected, tries \\ 30) do
    cond do
      field_value(session, id) == expected -> true
      tries == 0 -> false
      true -> Process.sleep(100) && wait_for_value(session, id, expected, tries - 1)
    end
  end

  defp field_value(session, id),
    do: js_value(session, "return document.getElementById('#{id}').value")

  defp current_article_path(user) do
    import Ecto.Query

    slug =
      Repo.one!(
        from(a in Baudrate.Content.Article,
          where: a.user_id == ^user.id,
          order_by: [desc: a.id],
          limit: 1,
          select: a.slug
        )
      )

    "/articles/#{slug}"
  end
end
