defmodule Baudrate.Federation.DurableDeliveryTest do
  @moduledoc """
  Acceptance gate for Phase 2C: stopping the node between a change and its
  delivery loses nothing (ADR 0034).

  Publishing used to run in a background task started after the change had
  committed, so a restart in that window saved the post and silently dropped
  its activities. Now the delivery jobs are written by the transaction that
  makes the change. Two checks hold that in place:

    * **Behaviour.** With `federation_async: :discard`, every background task is
      dropped, exactly as a restart would drop it. Each kind of change must
      still leave its delivery job behind.
    * **Structure.** No function handed to `schedule_federation_task/1` or a
      `Task` may call a publisher or enqueue a delivery. A new call site written
      the old way fails here, whether or not a behaviour test covers it.
  """

  use Baudrate.DataCase, async: false

  alias Baudrate.{Content, Federation, Messaging, Setup}
  alias Baudrate.Content.Board
  alias Baudrate.Federation.{DeliveryJob, KeyStore, RemoteActor}

  setup do
    Setup.seed_roles_and_permissions()

    previous = Application.get_env(:baudrate, :federation_async)
    Application.put_env(:baudrate, :federation_async, :discard)
    on_exit(fn -> Application.put_env(:baudrate, :federation_async, previous) end)

    user = create_user()
    remote = create_remote_actor()

    {:ok, _} =
      Federation.create_follower(
        Federation.actor_uri(:user, user.username),
        remote,
        "https://remote.example/activities/follow-#{System.unique_integer([:positive])}"
      )

    board = Repo.insert!(Board.changeset(%Board{}, %{name: "Durable", slug: "durable-#{uid()}"}))

    %{user: user, remote: remote, board: board}
  end

  describe "with every background task lost" do
    test "an article's Create is queued", %{user: user, remote: remote, board: board} do
      {:ok, %{article: _}} = create_article(user, board)

      assert queued?("Create", remote.inbox)
    end

    test "an edit, and a deletion, are queued", %{user: user, remote: remote, board: board} do
      {:ok, %{article: article}} = create_article(user, board)

      {:ok, article} = Content.update_article(article, %{body: "edited"}, user)
      assert queued?("Update", remote.inbox)

      {:ok, _} = Content.soft_delete_article(article, deleted_by: user.id)
      assert queued?("Delete", remote.inbox)
    end

    test "a comment's Create(Note) is queued", %{user: user, remote: remote, board: board} do
      {:ok, %{article: article}} = create_article(user, board)
      Repo.delete_all(DeliveryJob)

      {:ok, _} =
        Content.create_comment(%{
          "body" => "hi",
          "article_id" => article.id,
          "user_id" => user.id
        })

      assert queued?("Create", remote.inbox)
    end

    test "a like and a boost of a remote article reach its author",
         %{user: user, remote: remote, board: board} do
      article = remote_article(remote, board)

      {:ok, _} = Content.toggle_article_like(user.id, article.id)
      assert queued?("Like", remote.inbox)

      {:ok, _} = Content.toggle_article_boost(user.id, article.id)
      assert queued?("Announce", remote.inbox)
    end

    test "a follow, and an unfollow, of a remote account are queued",
         %{user: user, remote: remote} do
      {:ok, _} = Federation.follow_remote_actor(user, remote)
      assert queued?("Follow", remote.inbox)

      {:ok, _} = Federation.unfollow_remote_actor(user, remote)
      assert queued?("Undo", remote.inbox)
    end

    test "a direct message to a remote account is queued", %{user: user, remote: remote} do
      {:ok, conversation} = Messaging.find_or_create_remote_conversation(user, remote)
      {:ok, _} = Messaging.create_message(conversation, user, %{body: "private"})

      assert queued?("Create", remote.inbox)
    end

    # ADR 0072: the account's Delete(Person) commits with the tombstone.
    test "a deleted account's Delete(Person) is queued", %{user: user, remote: remote} do
      {:ok, deletion} =
        Baudrate.AccountDeletion.request(user, %{password: "Password123!x"},
          ip_address: "203.0.113.4"
        )

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(d in Baudrate.AccountDeletion.Deletion, where: d.id == ^deletion.id),
        set: [execute_after: past]
      )

      Baudrate.AccountDeletion.sweep()

      assert queued?("Delete", remote.inbox)
    end
  end

  describe "atomicity" do
    test "a change that fails queues nothing", %{user: user, board: board} do
      {:error, _step, _changeset, _} =
        Content.create_article(%{title: "", body: "", slug: "", user_id: user.id}, [board.id])

      assert Repo.aggregate(DeliveryJob, :count) == 0
    end

    test "a change rolled back after publishing takes its jobs with it",
         %{user: user, board: board} do
      {:error, :simulated_crash} =
        Repo.transaction(fn ->
          {:ok, _} = create_article(user, board)
          assert Repo.aggregate(DeliveryJob, :count) > 0
          Repo.rollback(:simulated_crash)
        end)

      assert Repo.aggregate(DeliveryJob, :count) == 0
    end
  end

  describe "no publishing from a background task" do
    test "no function handed to a task publishes or enqueues" do
      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(&task_bodies_that_publish/1)

      assert offenders == [],
             "publishing must run in the change's transaction (Federation.federate/2), " <>
               "not in a background task:\n" <> Enum.join(offenders, "\n")
    end
  end

  # --- Structure check ---

  defp task_bodies_that_publish(path) do
    path
    |> File.read!()
    |> Code.string_to_quoted!(columns: true)
    |> Macro.prewalk([], fn
      {{:., _, [_, :schedule_federation_task]}, meta, args} = node, acc ->
        {node, flag(args, path, meta, acc)}

      {:schedule_federation_task, meta, args} = node, acc when is_list(args) ->
        {node, flag(args, path, meta, acc)}

      {{:., _, [{:__aliases__, _, [:Task | _]}, _fun]}, meta, args} = node, acc ->
        {node, flag(args, path, meta, acc)}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp flag(args, path, meta, acc) do
    if Enum.any?(List.wrap(args), &publishes?/1),
      do: ["#{path}:#{meta[:line]}" | acc],
      else: acc
  end

  # `Publisher.publish_*` and the `Delivery` functions that enqueue. Sending an
  # already-queued job (`Delivery.deliver_one/1`) is what tasks are for.
  defp publishes?(ast) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, parts}, fun]}, _, _} = node, found ->
          {node, found or publishing_call?(List.last(parts), Atom.to_string(fun))}

        node, found ->
          {node, found}
      end)

    found
  end

  defp publishing_call?(:Publisher, "publish" <> _), do: true
  defp publishing_call?(:Delivery, "enqueue" <> _), do: true
  defp publishing_call?(:Delivery, fun) when fun in ["deliver_follow", "deliver_flag"], do: true
  defp publishing_call?(_module, _fun), do: false

  # --- Fixtures ---

  defp queued?(type, inbox) do
    DeliveryJob
    |> where([j], j.inbox_url == ^inbox and j.status == "pending")
    |> Repo.all()
    |> Enum.any?(&(Jason.decode!(&1.activity_json)["type"] == type))
  end

  defp create_article(user, board) do
    Content.create_article(
      %{title: "Durable", body: "Saved and sent.", slug: "durable-#{uid()}", user_id: user.id},
      [board.id]
    )
  end

  defp remote_article(remote, board) do
    {:ok, %{article: article}} =
      Content.create_remote_article(
        %{
          title: "Remote",
          body: "From elsewhere",
          slug: "remote-#{uid()}",
          ap_id: "https://remote.example/articles/#{uid()}",
          remote_actor_id: remote.id
        },
        [board.id]
      )

    article
  end

  defp create_user do
    role = Repo.one!(from(r in Setup.Role, where: r.name == "user"))

    {:ok, user} =
      %Setup.User{}
      |> Setup.User.registration_changeset(%{
        "username" => "durable_#{uid()}",
        "password" => "Password123!x",
        "password_confirmation" => "Password123!x",
        "role_id" => role.id
      })
      |> Repo.insert()

    {:ok, user} = KeyStore.ensure_user_keypair(user)
    Repo.preload(user, :role)
  end

  defp create_remote_actor do
    id = uid()

    %RemoteActor{}
    |> RemoteActor.changeset(%{
      ap_id: "https://remote.example/users/durable-#{id}",
      username: "durable_#{id}",
      domain: "remote.example",
      public_key_pem: elem(KeyStore.generate_keypair(), 0),
      inbox: "https://remote.example/users/durable-#{id}/inbox",
      actor_type: "Person",
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp uid, do: System.unique_integer([:positive])
end
