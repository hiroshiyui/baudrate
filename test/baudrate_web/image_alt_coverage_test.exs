defmodule BaudrateWeb.ImageAltCoverageTest do
  @moduledoc """
  ADR 0061's structural half: a member who uploads an image must be offered
  somewhere to describe it.

  Five composers accept image uploads and all five render the control today.
  Nothing but this test stops a sixth from shipping without it — and the way
  that failure presents is the reason it needs a gate: everything works, every
  other test passes, and the only people who find out are the ones who cannot
  see the picture.
  """
  use ExUnit.Case, async: true

  # Templates live in .heex files and in the ~H sigils inside component
  # modules; the comment composer and the timeline reply composer are the
  # latter, so scanning only .heex would miss two of the five.
  @sources Path.wildcard("lib/baudrate_web/**/*.heex") ++
             Path.wildcard("lib/baudrate_web/**/*.ex")

  # An avatar is the one upload that needs no free-text description: its
  # accessible name is the account's display name, applied by
  # `CoreComponents.avatar/1`, and a second description of the same person
  # would be read out twice.
  @no_description_needed ~w(avatar)

  @control "image_alt_input"

  describe "every image upload surface" do
    test "offers a field to describe what was uploaded" do
      offenders =
        for path <- @sources,
            source = File.read!(path),
            describable_uploads(source) != [],
            not String.contains?(source, @control),
            do: {path, describable_uploads(source)}

      assert offenders == [],
             """
             These templates render an image upload with no <.image_alt_input>:

             #{Enum.map_join(offenders, "\n", fn {path, keys} -> "  #{path} — #{Enum.join(keys, ", ")}" end)}

             Every uploaded image needs somewhere for its uploader to describe
             it (ADR 0061). If this upload genuinely needs no description —
             which so far is only an avatar, whose accessible name is the
             display name — add its key to @no_description_needed with the
             reason, rather than deleting the case.
             """
    end

    test "is actually found by this test, so it cannot pass vacuously" do
      found =
        @sources
        |> Enum.flat_map(&describable_uploads(File.read!(&1)))
        |> Enum.uniq()
        |> Enum.sort()

      # If a refactor renames the assign this scans for, the test above would
      # go green by finding nothing at all. Naming the surfaces is what stops
      # a silent pass; add to this list when a composer is added.
      assert found == ["article_images", "comment_images", "dm_images", "reply_images"]
    end
  end

  defp describable_uploads(source) do
    ~r/@uploads\.([a-z_]+)/
    |> Regex.scan(source)
    |> Enum.map(fn [_, key] -> key end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @no_description_needed))
    |> Enum.sort()
  end
end
