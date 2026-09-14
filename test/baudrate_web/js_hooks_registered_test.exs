defmodule BaudrateWeb.JsHooksRegisteredTest do
  @moduledoc """
  Every `phx-hook` used in a template must be registered with the LiveSocket in
  `assets/js/app.js` (or be a colocated hook). LiveView only logs an unknown
  hook in the browser console, so a wrong name fails silently: the DM page
  asked for `ScrollBottom` while the hook is registered as `ScrollBottomHook`,
  and the conversation never scrolled to its newest messages.
  """

  use ExUnit.Case, async: true

  test "all phx-hook names in templates are registered" do
    app_js = File.read!("assets/js/app.js")
    [_, hooks] = Regex.run(~r/hooks:\s*\{([^}]*)\}/, app_js)
    registered = ~r/\b[A-Z]\w+\b/ |> Regex.scan(hooks) |> List.flatten() |> MapSet.new()

    sources =
      Path.wildcard("lib/baudrate_web/**/*.{ex,heex}")
      |> Enum.map(&{&1, File.read!(&1)})

    colocated =
      sources
      |> Enum.flat_map(fn {_, s} -> Regex.scan(~r/ColocatedHook\}\s*name="\.?(\w+)"/, s) end)
      |> Enum.map(fn [_, name] -> name end)
      |> MapSet.new()

    unknown =
      for {file, source} <- sources,
          [_, name] <- Regex.scan(~r/phx-hook="([^"]+)"/, source),
          bare = String.trim_leading(name, "."),
          not MapSet.member?(registered, bare) and not MapSet.member?(colocated, bare) do
        {file, name}
      end

    assert unknown == []
  end
end
