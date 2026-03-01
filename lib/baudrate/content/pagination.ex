defmodule Baudrate.Content.Pagination do
  @moduledoc """
  Delegates to `Baudrate.Pagination` for backward compatibility.

  New code should use `Baudrate.Pagination` directly.
  """

  defdelegate paginate_opts(opts, default_per_page), to: Baudrate.Pagination
  defdelegate paginate_query(base_query, pagination, opts), to: Baudrate.Pagination
end
