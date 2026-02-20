defmodule BaudrateWeb.PageController do
  use BaudrateWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
