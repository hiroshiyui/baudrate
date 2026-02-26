defmodule Baudrate.Timezone do
  @moduledoc """
  Provides IANA timezone identifiers extracted from the `tz` library's
  compiled data at compile time.
  """

  # Extract timezone names from the compiled Tz.PeriodsProvider module at compile time
  @identifiers (
                 {:ok, {_, [{:abstract_code, {_, abstract_code}}]}} =
                   :beam_lib.chunks(:code.which(Tz.PeriodsProvider), [:abstract_code])

                 abstract_code
                 |> Enum.filter(fn
                   {:function, _, :periods, 1, _} -> true
                   _ -> false
                 end)
                 |> Enum.flat_map(fn {:function, _, :periods, 1, clauses} ->
                   clauses
                   |> Enum.filter(fn
                     {:clause, _, [{:bin, _, [{:bin_element, _, {:string, _, _}, _, _}]}], _, _} ->
                       true

                     _ ->
                       false
                   end)
                   |> Enum.map(fn
                     {:clause, _, [{:bin, _, [{:bin_element, _, {:string, _, chars}, _, _}]}], _,
                      _} ->
                       to_string(chars)
                   end)
                 end)
                 |> Enum.sort()
               )

  @doc """
  Returns a sorted list of all known IANA timezone identifiers.

  Extracted at compile time from `Tz.PeriodsProvider` beam data.
  """
  @spec identifiers() :: [String.t()]
  def identifiers do
    @identifiers
  end
end
