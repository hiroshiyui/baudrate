defmodule BaudrateWeb.Plugs.AttachmentHeadersTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.Plugs.AttachmentHeaders

  defp build_conn(path) do
    Plug.Test.conn(:get, path)
  end

  defp run_before_send(conn) do
    callbacks = conn.private[:before_send] || []
    Enum.reduce(callbacks, conn, fn callback, acc -> callback.(acc) end)
  end

  describe "call/2" do
    test "registers before_send callback for attachment paths" do
      conn =
        build_conn("/uploads/attachments/abc123/file.pdf")
        |> AttachmentHeaders.call(AttachmentHeaders.init([]))

      assert length(conn.private[:before_send]) > 0
    end

    test "does not register callback for non-attachment paths" do
      conn =
        build_conn("/uploads/avatars/abc123/48.webp")
        |> AttachmentHeaders.call(AttachmentHeaders.init([]))

      before_send = conn.private[:before_send] || []
      assert before_send == []
    end

    test "adds nosniff for image responses" do
      conn =
        build_conn("/uploads/attachments/abc123/photo.jpg")
        |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
        |> AttachmentHeaders.call(AttachmentHeaders.init([]))
        |> run_before_send()

      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert Plug.Conn.get_resp_header(conn, "content-disposition") == []
    end

    test "adds attachment disposition for PDF responses" do
      conn =
        build_conn("/uploads/attachments/abc123/document.pdf")
        |> Plug.Conn.put_resp_header("content-type", "application/pdf")
        |> AttachmentHeaders.call(AttachmentHeaders.init([]))
        |> run_before_send()

      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert Plug.Conn.get_resp_header(conn, "content-disposition") == ["attachment"]
    end

    test "adds attachment disposition for ZIP responses" do
      conn =
        build_conn("/uploads/attachments/abc123/archive.zip")
        |> Plug.Conn.put_resp_header("content-type", "application/zip")
        |> AttachmentHeaders.call(AttachmentHeaders.init([]))
        |> run_before_send()

      assert Plug.Conn.get_resp_header(conn, "content-disposition") == ["attachment"]
    end

    test "keeps inline for webp images" do
      conn =
        build_conn("/uploads/attachments/abc123/image.webp")
        |> Plug.Conn.put_resp_header("content-type", "image/webp")
        |> AttachmentHeaders.call(AttachmentHeaders.init([]))
        |> run_before_send()

      assert Plug.Conn.get_resp_header(conn, "content-disposition") == []
    end

    test "keeps inline for png images" do
      conn =
        build_conn("/uploads/attachments/abc123/image.png")
        |> Plug.Conn.put_resp_header("content-type", "image/png")
        |> AttachmentHeaders.call(AttachmentHeaders.init([]))
        |> run_before_send()

      assert Plug.Conn.get_resp_header(conn, "content-disposition") == []
      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end
end
