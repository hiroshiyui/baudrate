defmodule Baudrate.Logger.JSONFormatterTest do
  use ExUnit.Case, async: true

  alias Baudrate.Logger.JSONFormatter

  @time 1_789_634_102_114_000

  test "writes one JSON object per line with time, level and message" do
    line = format(%{level: :info, msg: {:string, "delivery ok"}, meta: %{time: @time}})

    assert String.ends_with?(line, "\n")
    assert [_one_line, ""] = String.split(line, "\n")

    assert %{"time" => "2026-09-17T08:35:02.114Z", "level" => "info", "message" => "delivery ok"} =
             Jason.decode!(line)
  end

  test "formats format strings and reports the way the text format does" do
    assert %{"message" => "count=3"} =
             decode(%{level: :warning, msg: {~c"count=~p", [3]}, meta: %{time: @time}})

    assert %{"message" => message} =
             decode(%{level: :error, msg: {:report, %{event: :stopped}}, meta: %{time: @time}})

    assert message =~ "stopped"
  end

  test "a newline in a message cannot forge a second log line" do
    line =
      format(%{
        level: :info,
        msg: {:string, "user input\n{\"level\":\"error\"}"},
        meta: %{time: @time}
      })

    assert [_one_line, ""] = String.split(line, "\n")
    assert %{"level" => "info"} = Jason.decode!(line)
  end

  test "invalid UTF-8 is replaced instead of crashing the handler" do
    assert %{"message" => message} =
             decode(%{
               level: :info,
               msg: {:string, <<"bad ", 0xFF, " byte">>},
               meta: %{time: @time}
             })

    assert message == "bad � byte"
  end

  test "keeps only allow-listed metadata" do
    decoded =
      decode(%{
        level: :info,
        msg: {:string, "signed in"},
        meta: %{
          time: @time,
          request_id: "F1abc",
          mfa: {BaudrateWeb.SessionController, :create, 2},
          password: "hunter2",
          remote_ip: "203.0.113.9"
        }
      })

    assert decoded == %{
             "time" => "2026-09-17T08:35:02.114Z",
             "level" => "info",
             "message" => "signed in",
             "request_id" => "F1abc",
             "module" => "BaudrateWeb.SessionController",
             "function" => "create/2"
           }
  end

  test "an event it cannot format still produces a line" do
    assert [line] =
             [JSONFormatter.format(%{level: :info, msg: :not_a_message, meta: %{}}, %{})]
             |> IO.iodata_to_binary()
             |> String.split("\n", trim: true)

    assert %{"message" => "log event could not be formatted"} = Jason.decode!(line)
  end

  defp format(event), do: event |> JSONFormatter.format(%{}) |> IO.iodata_to_binary()
  defp decode(event), do: event |> format() |> Jason.decode!()

  describe "never takes logging down with it" do
    test "an event missing :level and :meta still formats" do
      # A head-match failure happens before `rescue` can catch anything, and
      # `:logger` removes a handler that raises — ending all logging.
      line = JSONFormatter.format(%{unexpected: true}, %{}) |> IO.iodata_to_binary()

      assert line =~ "could not be formatted"
      assert String.ends_with?(line, "\n")
      assert {:ok, _} = Jason.decode(String.trim(line))
    end
  end
end
