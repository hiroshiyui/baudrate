defmodule BaudrateWeb.PollComposerTest do
  use ExUnit.Case, async: true

  alias BaudrateWeb.PollComposer

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, poll_options: ["", ""], poll_mode: "single", poll_expires: ""}
    }
  end

  test "keeps typed options in input order, with the mode and expiry" do
    params = %{
      "poll_options" => %{"1" => "Curry", "0" => "Noodles", "2" => "Salad"},
      "poll_mode" => "multiple",
      "poll_expires" => "1d"
    }

    assigns = PollComposer.assign_poll_params(socket(), params).assigns

    assert assigns.poll_options == ["Noodles", "Curry", "Salad"]
    assert assigns.poll_mode == "multiple"
    assert assigns.poll_expires == "1d"
  end

  test "orders by numeric index, drops malformed entries, and caps the count" do
    options =
      %{"10" => "k", "2" => "c", "x" => "bad", "1" => %{"nested" => "bad"}}
      |> Map.merge(Map.new(3..9, &{Integer.to_string(&1), "o#{&1}"}))

    assigns = PollComposer.assign_poll_params(socket(), %{"poll_options" => options}).assigns

    assert assigns.poll_options == ["c", "o3", "o4", "o5"]
    assert length(assigns.poll_options) == PollComposer.max_options()
    assert assigns.poll_mode == "single"
  end

  test "leaves the socket alone when the change carries no poll" do
    assert PollComposer.assign_poll_params(socket(), %{"article" => %{}}).assigns ==
             socket().assigns
  end
end
