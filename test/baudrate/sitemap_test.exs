defmodule Baudrate.SitemapTest do
  use Baudrate.DataCase, async: true

  alias Baudrate.Sitemap

  import BaudrateWeb.ConnCase, only: [setup_user: 1]

  describe "build_xml/0" do
    test "generates valid sitemap XML with XML declaration and urlset" do
      xml = Sitemap.build_xml()

      assert xml =~ ~s(<?xml version="1.0" encoding="UTF-8"?>)
      assert xml =~ ~s(<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">)
      assert xml =~ ~s(</urlset>)
    end

    test "always includes homepage" do
      xml = Sitemap.build_xml()
      base = BaudrateWeb.Endpoint.url()

      assert xml =~ "<loc>#{base}/</loc>"
      assert xml =~ "<priority>1.0</priority>"
    end

    test "includes public boards" do
      {:ok, board} =
        Baudrate.Content.create_board(%{
          name: "Sitemap Public Board",
          slug: "sitemap-public-board",
          min_role_to_view: "guest"
        })

      xml = Sitemap.build_xml()
      base = BaudrateWeb.Endpoint.url()

      assert xml =~ "<loc>#{base}/boards/#{board.slug}</loc>"
    end

    test "excludes non-public boards" do
      {:ok, board} =
        Baudrate.Content.create_board(%{
          name: "Sitemap Private Board",
          slug: "sitemap-private-board",
          min_role_to_view: "user"
        })

      xml = Sitemap.build_xml()

      refute xml =~ "/boards/#{board.slug}"
    end

    test "includes articles in public boards" do
      user = setup_user("user")

      {:ok, board} =
        Baudrate.Content.create_board(%{
          name: "Sitemap Test Board",
          slug: "sitemap-test-board",
          min_role_to_view: "guest"
        })

      {:ok, %{article: article}} =
        Baudrate.Content.create_article(
          %{title: "Sitemap Test Article", body: "Test body content", slug: "sitemap-test-article", user_id: user.id},
          [board.id]
        )

      xml = Sitemap.build_xml()
      base = BaudrateWeb.Endpoint.url()

      assert xml =~ "<loc>#{base}/articles/#{article.slug}</loc>"
    end

    test "excludes articles in non-public boards" do
      user = setup_user("user")

      {:ok, board} =
        Baudrate.Content.create_board(%{
          name: "Private Sitemap Board",
          slug: "private-sitemap-board",
          min_role_to_view: "user"
        })

      {:ok, %{article: article}} =
        Baudrate.Content.create_article(
          %{title: "Private Article", body: "Private body", slug: "private-sitemap-article", user_id: user.id},
          [board.id]
        )

      xml = Sitemap.build_xml()

      refute xml =~ "/articles/#{article.slug}"
    end

    test "excludes soft-deleted articles" do
      user = setup_user("user")

      {:ok, board} =
        Baudrate.Content.create_board(%{
          name: "Sitemap Deleted Board",
          slug: "sitemap-deleted-board",
          min_role_to_view: "guest"
        })

      {:ok, %{article: article}} =
        Baudrate.Content.create_article(
          %{title: "Deleted Article", body: "Will be deleted", slug: "deleted-sitemap-article", user_id: user.id},
          [board.id]
        )

      Baudrate.Content.soft_delete_article(article)

      xml = Sitemap.build_xml()

      refute xml =~ "/articles/#{article.slug}"
    end

    test "excludes user profiles for privacy" do
      setup_user("user")

      xml = Sitemap.build_xml()

      refute xml =~ "/users/"
    end

    test "escapes special XML characters in URLs" do
      xml = Sitemap.build_xml()

      # Ensure no unescaped ampersands (outside &amp;)
      refute Regex.match?(~r/<loc>[^<]*[^&]&[^a]/, xml)
    end
  end

  describe "generate/0" do
    test "writes sitemap.xml to priv/static" do
      assert :ok = Sitemap.generate()

      path = Application.app_dir(:baudrate, Path.join(["priv", "static", "sitemap.xml"]))
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "<?xml version="
      assert content =~ "<urlset"

      # Cleanup
      File.rm(path)
    end
  end
end
