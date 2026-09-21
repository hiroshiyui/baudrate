defmodule Baudrate.Repo.Migrations.AddAltToImages do
  use Ecto.Migration

  @moduledoc """
  A description for an uploaded image, federated as the attachment `name`.

  Before this, every gallery image rendered `alt="Image N"` — a position, not
  a description — and an inbound `name` supplied by a peer was discarded for
  want of a column to hold it.
  """

  def change do
    for table <- [:article_images, :comment_images, :timeline_item_reply_images] do
      alter table(table) do
        add :alt, :string
      end
    end
  end
end
