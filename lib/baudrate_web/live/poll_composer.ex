defmodule BaudrateWeb.PollComposer do
  @moduledoc """
  Keeps a composer's poll inputs in socket assigns while the form is edited.

  The poll inputs (`poll_options[i]`, `poll_mode`, `poll_expires`) sit inside
  the article form of `ArticleNewLive` and `TimelineLive`, so their changes arrive
  with the form's own change event: LiveView honours `phx-change` only on a
  form or an input, not on the `<fieldset>` around the poll. Every change
  re-renders the form, and LiveView resets each input to its rendered value,
  so the change handler must pass the params through `assign_poll_params/2`.
  Before, it did not: typing a poll option erased the others, and typing the
  title erased them all, so no poll could be created in a browser.
  """

  import Phoenix.Component, only: [assign: 3]

  @max_options 4

  @doc "The most poll options a composer offers."
  def max_options, do: @max_options

  @doc """
  Copies the poll fields from a form change's `params` into `:poll_options`
  (ordered by input index, at most `max_options/0`), `:poll_mode` and
  `:poll_expires`. Leaves the socket unchanged when the params carry no poll.
  """
  def assign_poll_params(socket, %{"poll_options" => options} = params) when is_map(options) do
    options =
      options
      |> Enum.flat_map(fn {index, value} ->
        case {Integer.parse(index), value} do
          {{n, ""}, value} when is_binary(value) -> [{n, value}]
          _ -> []
        end
      end)
      |> Enum.sort()
      |> Enum.take(@max_options)
      |> Enum.map(&elem(&1, 1))

    socket
    |> assign(:poll_options, options)
    |> assign(:poll_mode, string_param(params, "poll_mode", socket.assigns.poll_mode))
    |> assign(:poll_expires, string_param(params, "poll_expires", socket.assigns.poll_expires))
  end

  def assign_poll_params(socket, _params), do: socket

  defp string_param(params, key, default) do
    case params[key] do
      value when is_binary(value) -> value
      _ -> default
    end
  end
end
