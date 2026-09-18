defmodule Baudrate.Content.BoardTest do
  @moduledoc """
  The two predicates every federation gate is built on.

  `federated?/1` is an *and*: guest-viewable **and** AP-enabled. Only the
  first half was covered anywhere, so nothing failed when a caller treated
  `ap_enabled: false` as federated — which is the switch an admin flips to
  take a board off the fediverse while leaving it readable on the site.
  """
  use ExUnit.Case, async: true

  alias Baudrate.Content.Board

  describe "public?/1" do
    test "only a guest-viewable board is public" do
      assert Board.public?(%Board{min_role_to_view: "guest"})
      refute Board.public?(%Board{min_role_to_view: "user"})
      refute Board.public?(%Board{min_role_to_view: "moderator"})
      refute Board.public?(%Board{min_role_to_view: "admin"})
    end

    test "is indifferent to ap_enabled" do
      # `public?/1` answers a question about the site, not the fediverse.
      assert Board.public?(%Board{min_role_to_view: "guest", ap_enabled: false})
    end
  end

  describe "federated?/1" do
    test "guest-viewable and AP-enabled" do
      assert Board.federated?(%Board{min_role_to_view: "guest", ap_enabled: true})
    end

    test "a guest-viewable board with ap_enabled: false is NOT federated" do
      refute Board.federated?(%Board{min_role_to_view: "guest", ap_enabled: false}),
             "ap_enabled is the other half of the gate: a board taken off the " <>
               "fediverse must not federate its content"
    end

    test "a non-public board is not federated whatever ap_enabled says" do
      for role <- ["user", "moderator", "admin"], ap <- [true, false] do
        refute Board.federated?(%Board{min_role_to_view: role, ap_enabled: ap}),
               "min_role_to_view=#{role} ap_enabled=#{ap} must not be federated"
      end
    end
  end
end
