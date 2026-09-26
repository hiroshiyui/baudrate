defmodule BaudrateWeb.Features.AvatarCropTest do
  @moduledoc """
  The avatar editor crops in the browser, with Cropper.js loaded on demand
  (Phase 8D): it is a bundle of its own (`/assets/js/cropper.js`), fetched by
  `AvatarCropHook` the first time a crop is needed, and no other page loads
  it. Nothing but a browser can tell that the lazy load works.
  """

  use BaudrateWeb.FeatureCase, async: false

  alias Baudrate.Repo
  alias Baudrate.Setup.User

  @moduletag :feature

  setup do
    %{user: setup_user("user")}
  end

  feature "cropping a new avatar loads the cropper and saves the avatar", %{
    session: session,
    user: user
  } do
    png = Path.join(System.tmp_dir!(), "avatar-test-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(160, 120, color: [200, 80, 40])
    Image.write!(image, png)
    on_exit(fn -> File.rm(png) end)

    session =
      session
      |> log_in_via_browser(user)
      |> visit("/profile")
      |> assert_has(Query.css("[data-phx-main].phx-connected"))

    # Not on the page until a crop is needed.
    refute_has(session, Query.css("script[src*='cropper']"))

    # The file input sits in a hidden form (a button opens the picker). Show
    # it so the path can be typed in: browser and test share a filesystem, and
    # Wallaby's attach_file does not work through the W3C shim.
    session
    |> execute_script("document.getElementById('avatar-upload-form').classList.remove('hidden')")
    |> find(Query.css("#avatar-upload-form input[type=file]"))
    |> Wallaby.Element.set_value(png)

    session
    |> assert_has(Query.css("#crop-modal[open]"))
    |> assert_has(Query.css("script[src*='cropper']", visible: false))
    |> assert_has(Query.css("#avatar-crop-container #avatar-crop-canvas"))
    # The square selection starts on the image: shown once the image is ready.
    |> assert_has(Query.css("#avatar-crop-canvas cropper-selection:not([hidden])"))
    |> execute_script(
      """
      const canvas = document.getElementById("avatar-crop-canvas").getBoundingClientRect();
      const image = document.querySelector("#avatar-crop-canvas cropper-image").getBoundingClientRect();
      const s = document.querySelector("#avatar-crop-canvas cropper-selection");
      return [image.left - canvas.left, image.top - canvas.top, image.width, image.height,
              s.x, s.y, s.width, s.height];
      """,
      [],
      fn [ix, iy, iw, ih, sx, sy, sw, sh] ->
        # The largest square on the image, centred on it (a 4:3 image here).
        assert sw == sh
        assert_in_delta sw, min(iw, ih), 1
        assert_in_delta sx + sw / 2, ix + iw / 2, 1
        assert_in_delta sy + sh / 2, iy + ih / 2, 1
      end
    )
    # The selection cannot leave the image.
    |> execute_script(
      """
      const s = document.querySelector("#avatar-crop-canvas cropper-selection");
      const before = [s.x, s.y];
      s.$moveTo(-500, -500);
      return [before, [s.x, s.y]];
      """,
      [],
      fn [before, moved] -> assert before == moved end
    )
    |> click(Query.css("#crop-modal .modal-action .btn-primary"))

    assert wait_until(fn -> Repo.get!(User, user.id).avatar_id != nil end),
           "the cropped avatar was not saved"
  end

  # The cropper is a separate script. When it cannot load, Save must still
  # save (the server takes the centred square) rather than do nothing while
  # the dialog stays open.
  feature "Save still saves when the cropper cannot load", %{session: session, user: user} do
    png = Path.join(System.tmp_dir!(), "avatar-test-#{System.unique_integer([:positive])}.png")
    {:ok, image} = Image.new(160, 120, color: [40, 80, 200])
    Image.write!(image, png)
    on_exit(fn -> File.rm(png) end)

    session =
      session
      |> log_in_via_browser(user)
      |> visit("/profile")
      |> assert_has(Query.css("[data-phx-main].phx-connected"))

    # Fail the cropper's script the way a dropped connection would. Changing
    # data-cropper-src is not enough: LiveView patches it back when the
    # dialog opens.
    session
    |> execute_script("""
    const append = document.head.appendChild.bind(document.head);
    document.head.appendChild = (el) => {
      if (el.tagName === "SCRIPT" && el.src.includes("cropper")) {
        setTimeout(() => el.onerror && el.onerror(new Event("error")), 0);
        return el;
      }
      return append(el);
    };
    document.getElementById("avatar-upload-form").classList.remove("hidden");
    """)
    |> find(Query.css("#avatar-upload-form input[type=file]"))
    |> Wallaby.Element.set_value(png)

    session
    |> assert_has(Query.css("#crop-modal[open]"))
    |> refute_has(Query.css("#avatar-crop-container #avatar-crop-canvas"))
    |> click(Query.css("#crop-modal .modal-action .btn-primary"))

    assert wait_until(fn -> Repo.get!(User, user.id).avatar_id != nil end),
           "Save did nothing without the cropper"
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100) && wait_until(fun, tries - 1)
    end
  end
end
