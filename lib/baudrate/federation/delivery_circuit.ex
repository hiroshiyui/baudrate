defmodule Baudrate.Federation.DeliveryCircuit do
  @moduledoc """
  Delivery health of one remote domain: a row of the per-domain circuit
  breaker. `Baudrate.Federation.DeliveryCircuits` is the only code that writes
  it.

  A domain has a row only while deliveries to it are failing. Any response that
  shows the server is reachable deletes the row, so "no row" means healthy.

    * `failures` — consecutive failures that say the server is unreachable.
    * `trips` — how many times the circuit has opened since the domain was last
      reachable. `0` means closed; the first trip happens at the threshold.
    * `open_until` — while in the future, no job for the domain is attempted.
      Once it passes, one job at a time is sent as a probe.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:domain, :string, autogenerate: false}
  schema "delivery_circuits" do
    field :failures, :integer, default: 0
    field :trips, :integer, default: 0
    field :open_until, :utc_datetime
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end
end
