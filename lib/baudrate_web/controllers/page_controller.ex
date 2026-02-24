defmodule BaudrateWeb.PageController do
  @moduledoc """
  Controller for static pages (home page).
  """

  use BaudrateWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
