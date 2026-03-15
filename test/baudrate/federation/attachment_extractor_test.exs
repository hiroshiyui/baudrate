defmodule Baudrate.Federation.AttachmentExtractorTest do
  use ExUnit.Case, async: true

  alias Baudrate.Federation.AttachmentExtractor

  describe "extract_image_attachments/1" do
    test "extracts Document attachments with image mediaType" do
      object = %{
        "attachment" => [
          %{
            "type" => "Document",
            "mediaType" => "image/jpeg",
            "url" => "https://example.com/image1.jpg",
            "name" => "A photo"
          },
          %{
            "type" => "Document",
            "mediaType" => "image/png",
            "url" => "https://example.com/image2.png",
            "name" => nil
          }
        ]
      }

      result = AttachmentExtractor.extract_image_attachments(object)

      assert length(result) == 2
      assert Enum.at(result, 0)["url"] == "https://example.com/image1.jpg"
      assert Enum.at(result, 0)["name"] == "A photo"
      assert Enum.at(result, 1)["url"] == "https://example.com/image2.png"
    end

    test "extracts Image type attachments" do
      object = %{
        "attachment" => [
          %{"type" => "Image", "url" => "https://example.com/photo.jpg"}
        ]
      }

      result = AttachmentExtractor.extract_image_attachments(object)
      assert length(result) == 1
      assert Enum.at(result, 0)["url"] == "https://example.com/photo.jpg"
    end

    test "filters out non-image attachments" do
      object = %{
        "attachment" => [
          %{
            "type" => "Document",
            "mediaType" => "video/mp4",
            "url" => "https://example.com/video.mp4"
          },
          %{
            "type" => "Document",
            "mediaType" => "image/jpeg",
            "url" => "https://example.com/photo.jpg"
          },
          %{"type" => "Link", "href" => "https://example.com"}
        ]
      }

      result = AttachmentExtractor.extract_image_attachments(object)
      assert length(result) == 1
      assert Enum.at(result, 0)["url"] == "https://example.com/photo.jpg"
    end

    test "handles url as map with href" do
      object = %{
        "attachment" => [
          %{
            "type" => "Document",
            "mediaType" => "image/webp",
            "url" => %{"href" => "https://example.com/image.webp"}
          }
        ]
      }

      result = AttachmentExtractor.extract_image_attachments(object)
      assert length(result) == 1
      assert Enum.at(result, 0)["url"] == "https://example.com/image.webp"
    end

    test "handles url as list" do
      object = %{
        "attachment" => [
          %{
            "type" => "Document",
            "mediaType" => "image/png",
            "url" => ["https://example.com/first.png", "https://example.com/second.png"]
          }
        ]
      }

      result = AttachmentExtractor.extract_image_attachments(object)
      assert length(result) == 1
      assert Enum.at(result, 0)["url"] == "https://example.com/first.png"
    end

    test "limits to 4 attachments" do
      attachments =
        for i <- 1..6 do
          %{
            "type" => "Document",
            "mediaType" => "image/jpeg",
            "url" => "https://example.com/image#{i}.jpg"
          }
        end

      object = %{"attachment" => attachments}
      result = AttachmentExtractor.extract_image_attachments(object)
      assert length(result) == 4
    end

    test "returns empty list for objects without attachment" do
      assert AttachmentExtractor.extract_image_attachments(%{}) == []
      assert AttachmentExtractor.extract_image_attachments(%{"content" => "hello"}) == []
    end

    test "returns empty list for non-list attachment" do
      assert AttachmentExtractor.extract_image_attachments(%{"attachment" => "not a list"}) == []
    end

    test "filters out attachments with nil url" do
      object = %{
        "attachment" => [
          %{"type" => "Document", "mediaType" => "image/jpeg", "url" => nil}
        ]
      }

      assert AttachmentExtractor.extract_image_attachments(object) == []
    end
  end
end
