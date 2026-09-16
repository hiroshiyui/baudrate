defmodule Baudrate.Federation.DomainBlocksTest do
  use Baudrate.DataCase, async: false

  alias Baudrate.Federation.{DomainBlock, DomainBlocks}
  alias Baudrate.Setup

  defp setup_admin do
    Setup.seed_roles_and_permissions()
    role = Repo.one!(from r in Setup.Role, where: r.name == "admin")

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "admin_#{System.unique_integer([:positive])}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    user
  end

  describe "block_domain/3" do
    test "records who blocked it and why" do
      admin = setup_admin()

      {:ok, block} =
        DomainBlocks.block_domain("spam.example", admin, %{
          reason: "ongoing harassment",
          public_comment: "spam"
        })

      assert block.domain == "spam.example"
      assert block.blocked_by_id == admin.id
      assert block.reason == "ongoing harassment"
      assert block.public_comment == "spam"
    end

    test "stores the domain downcased" do
      {:ok, block} = DomainBlocks.block_domain("Spam.EXAMPLE")

      assert block.domain == "spam.example"
    end

    test "refuses a second block of the same domain" do
      {:ok, _} = DomainBlocks.block_domain("spam.example")

      assert {:error, :already_blocked} = DomainBlocks.block_domain("spam.example")
      assert {:error, :already_blocked} = DomainBlocks.block_domain("SPAM.example")
      assert DomainBlocks.count_domain_blocks() == 1
    end

    test "refuses this instance's own domain" do
      local = BaudrateWeb.Endpoint.url() |> URI.parse() |> Map.get(:host)

      assert {:error, changeset} = DomainBlocks.block_domain(local)
      assert "is this instance's own domain" in errors_on(changeset).domain
    end

    test "refuses something that is not a domain" do
      for value <- ["", "   ", "not a domain", "localhost", "-bad.example", "bad-.example"] do
        assert {:error, %Ecto.Changeset{}} = DomainBlocks.block_domain(value),
               "expected #{inspect(value)} to be refused"
      end
    end
  end

  describe "normalize_domain/1" do
    test "reduces what an admin might paste to a bare host" do
      for {input, expected} <- [
            {"spam.example", "spam.example"},
            {"  Spam.Example  ", "spam.example"},
            {"https://spam.example", "spam.example"},
            {"https://spam.example/users/bob", "spam.example"},
            {"http://spam.example:8443/", "spam.example"},
            {"@bob@spam.example", "spam.example"},
            {"bob@spam.example", "spam.example"},
            {"acct:bob@spam.example", "spam.example"},
            {"spam.example.", "spam.example"}
          ] do
        assert DomainBlock.normalize_domain(input) == expected,
               "#{inspect(input)} normalized to #{inspect(DomainBlock.normalize_domain(input))}"
      end
    end

    test "a pasted profile URL finds the block made from a bare domain" do
      {:ok, _} = DomainBlocks.block_domain("spam.example")

      assert %DomainBlock{domain: "spam.example"} =
               DomainBlocks.get_domain_block("https://spam.example/@bob")
    end
  end

  describe "unblock_domain/1" do
    test "removes the row" do
      {:ok, _} = DomainBlocks.block_domain("spam.example")

      assert {:ok, _} = DomainBlocks.unblock_domain("spam.example")
      refute DomainBlocks.blocked?("spam.example")
      assert DomainBlocks.count_domain_blocks() == 0
    end

    test "says so when the domain was not blocked" do
      assert {:error, :not_found} = DomainBlocks.unblock_domain("never-blocked.example")
    end

    test "blocking again after an unblock is allowed" do
      {:ok, _} = DomainBlocks.block_domain("spam.example")
      {:ok, _} = DomainBlocks.unblock_domain("spam.example")

      assert {:ok, _} = DomainBlocks.block_domain("spam.example")
    end
  end

  describe "list_domain_blocks/0" do
    test "preloads the blocking admin" do
      admin = setup_admin()
      {:ok, _} = DomainBlocks.block_domain("spam.example", admin)

      assert [block] = DomainBlocks.list_domain_blocks()
      assert block.blocked_by.id == admin.id
    end

    test "survives the blocking admin being deleted" do
      admin = setup_admin()
      {:ok, _} = DomainBlocks.block_domain("spam.example", admin)

      Repo.delete!(admin)

      # A block outliving the account that made it is the point of the row: the
      # decision stands even when the admin is gone.
      assert [block] = DomainBlocks.list_domain_blocks()
      assert block.domain == "spam.example"
      assert block.blocked_by_id == nil
      assert DomainBlocks.blocked?("spam.example")
    end
  end
end
