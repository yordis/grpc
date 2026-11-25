defmodule GRPC.Server.Adapters.Cowboy.DeadlineAfterReplyTest do
  # The deadline timer of a call fires on its own schedule. If it lands after the reply
  # is out, and before the handler process has seen the end of the RPC process, it must
  # not send a second reply. The handler is driven here through its `:cowboy_loop`
  # callbacks, with the test process standing in for Cowboy's connection process, so the
  # order of the events is fixed and no clock is involved.
  use ExUnit.Case, async: true

  alias GRPC.Server.Adapters.Cowboy.Handler

  defmodule HelloServer do
    use GRPC.Server, service: Helloworld.Greeter.Service

    def say_hello(_req, _stream), do: %Helloworld.HelloReply{message: "ok"}
  end

  defp req do
    %{
      pid: self(),
      streamid: 1,
      method: "POST",
      version: :"HTTP/2",
      headers: %{},
      ref: :test,
      scheme: "http",
      host: "localhost",
      port: 80,
      path: "/helloworld.Greeter/SayHello",
      qs: ""
    }
  end

  defp state(access_mode, content_type, timer) do
    rpc_pid = spawn(fn -> Process.sleep(:infinity) end)

    %{
      pid: rpc_pid,
      endpoint: nil,
      route: "/helloworld.Greeter/SayHello",
      started_at: System.monotonic_time(),
      stream: %GRPC.Server.Stream{
        server: HelloServer,
        http_request_headers: %{"content-type" => content_type},
        access_mode: access_mode
      },
      access_mode: access_mode,
      handling_timer: timer,
      exception_log_filter: nil
    }
  end

  defp timer, do: Process.send_after(self(), :never, 60_000)

  defp responses do
    receive do
      {{_pid, 1}, {:response, status, _headers, _body}} -> [status | responses()]
    after
      0 -> []
    end
  end

  describe "a Connect unary call" do
    test "does not reply twice when the deadline fires after the reply" do
      state = state(:connectrpc, "application/proto", timer())

      {:ok, req, state} = Handler.info({:stream_body, "x", [], :nofin, false}, req(), state)
      {:ok, req, state} = Handler.info({:stream_trailers, %{}}, req, state)
      assert [200] = responses()

      assert {:ok, _req, _state} = Handler.info({:handling_timeout, self()}, req, state)
      assert [] = responses()
    end

    test "cancels the deadline timer when the reply completes" do
      timer = timer()
      state = state(:connectrpc, "application/proto", timer)

      {:ok, req, state} = Handler.info({:stream_body, "x", [], :nofin, false}, req(), state)
      {:ok, _req, _state} = Handler.info({:stream_trailers, %{}}, req, state)

      assert Process.read_timer(timer) == false
    end
  end

  describe "a gRPC call" do
    test "cancels the deadline timer when the reply completes" do
      timer = timer()
      state = state(:grpc, "application/grpc", timer)

      {:ok, _req, _state} = Handler.info({:stream_trailers, %{}}, req(), state)

      assert Process.read_timer(timer) == false
    end

    test "ignores a deadline that fires after the reply" do
      state = state(:grpc, "application/grpc", timer())

      {:ok, req, state} = Handler.info({:stream_trailers, %{}}, req(), state)

      assert {:ok, _req, _state} = Handler.info({:handling_timeout, self()}, req, state)
    end
  end
end
