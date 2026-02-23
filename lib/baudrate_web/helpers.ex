defmodule BaudrateWeb.Helpers do
  @moduledoc """
  Shared helper functions for LiveView and controller parameter handling.
  """

  @doc """
  Safely parses a string parameter to a positive integer.
  Returns `{:ok, integer}` on success, `:error` on failure.

  ## Examples

      iex> BaudrateWeb.Helpers.parse_id("42")
      {:ok, 42}

      iex> BaudrateWeb.Helpers.parse_id("abc")
      :error

      iex> BaudrateWeb.Helpers.parse_id("-1")
      :error

      iex> BaudrateWeb.Helpers.parse_id("0")
      :error
  """
  def parse_id(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  def parse_id(_), do: :error
end
