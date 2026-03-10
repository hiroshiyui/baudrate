defmodule Baudrate.Federation.VisibilityTest do
  use ExUnit.Case, async: true

  alias Baudrate.Federation.Visibility

  @as_public "https://www.w3.org/ns/activitystreams#Public"

  describe "from_addressing/1" do
    test "returns public when as:Public is in to" do
      assert "public" ==
               Visibility.from_addressing(%{
                 "to" => [@as_public],
                 "cc" => ["https://example.com/users/alice/followers"]
               })
    end

    test "returns unlisted when as:Public is in cc only" do
      assert "unlisted" ==
               Visibility.from_addressing(%{
                 "to" => ["https://example.com/users/alice/followers"],
                 "cc" => [@as_public]
               })
    end

    test "returns followers_only when addressed to followers collection without public" do
      assert "followers_only" ==
               Visibility.from_addressing(%{
                 "to" => ["https://example.com/users/alice/followers"],
                 "cc" => []
               })
    end

    test "returns direct when addressed to specific actors only" do
      assert "direct" ==
               Visibility.from_addressing(%{
                 "to" => ["https://example.com/users/bob"],
                 "cc" => []
               })
    end

    test "handles missing to/cc fields" do
      assert "direct" == Visibility.from_addressing(%{})
    end

    test "handles single string values (non-list)" do
      assert "public" == Visibility.from_addressing(%{"to" => @as_public})
    end

    test "public takes priority over followers in to" do
      assert "public" ==
               Visibility.from_addressing(%{
                 "to" => [@as_public, "https://example.com/users/alice/followers"]
               })
    end

    test "followers_only with followers in cc" do
      assert "followers_only" ==
               Visibility.from_addressing(%{
                 "to" => ["https://example.com/users/bob"],
                 "cc" => ["https://example.com/users/alice/followers"]
               })
    end
  end
end
