defmodule UdsDistPeerTest do
  use ExUnit.Case, async: false

  @moduletag :peer

  setup do
    tmp = Path.join(System.tmp_dir!(), "uds_dist_peer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp, ebin: to_charlist(:code.lib_dir(:uds_dist) |> Path.join("ebin"))}
  end

  describe "filesystem UDS distribution" do
    test "two peers can connect and exchange messages", ctx do
      {:ok, p1, n1} = start_peer(:alpha, ctx.tmp, ctx.ebin)
      {:ok, p2, n2} = start_peer(:beta, ctx.tmp, ctx.ebin)

      try do
        assert :peer.call(p1, :net_kernel, :connect_node, [n2]) == true
        assert :peer.call(p1, :erlang, :nodes, []) == [n2]
        assert :peer.call(p2, :erlang, :nodes, []) == [n1]

        assert :peer.call(p2, :erlang, :node, []) == n2
        assert :peer.call(p1, :rpc, :call, [n2, :erlang, :node, []]) == n2

        assert File.exists?(Path.join(ctx.tmp, "alpha.sock"))
        assert File.exists?(Path.join(ctx.tmp, "beta.sock"))
      after
        :peer.stop(p2)
        :peer.stop(p1)
      end
    end

    test "graceful init:stop removes the socket file", ctx do
      {:ok, p, _node} = start_peer(:cleanup, ctx.tmp, ctx.ebin)
      sock = Path.join(ctx.tmp, "cleanup.sock")
      assert File.exists?(sock)

      # init:stop returns :ok immediately and asynchronously triggers
      # the application shutdown chain — kernel_sup → net_sup → net_kernel
      # — which calls uds_dist:close/1 from net_kernel:terminate.
      :ok = :peer.call(p, :init, :stop, [], 5_000)

      :ok = wait_until(fn -> not File.exists?(sock) end, 5_000)
      catch_exit(:peer.stop(p))
    end

    test "stale socket files from an abrupt shutdown are reaped on next listen", ctx do
      {:ok, p1, _} = start_peer(:reaper, ctx.tmp, ctx.ebin)
      sock = Path.join(ctx.tmp, "reaper.sock")
      assert File.exists?(sock)

      # halt/0 exits the BEAM without invoking close/1 — file is left behind.
      catch_exit(:peer.call(p1, :erlang, :halt, [0]))
      catch_exit(:peer.stop(p1))

      # The same name should still be bindable: handle_eaddrinuse detects
      # the stale file (probe connect fails) and unlinks it before retrying.
      {:ok, p2, _} = start_peer(:reaper, ctx.tmp, ctx.ebin)
      assert File.exists?(sock)
      :peer.stop(p2)
    end

    test "rpc round-trips a large binary", ctx do
      {:ok, p1, _n1} = start_peer(:big_a, ctx.tmp, ctx.ebin)
      {:ok, p2, n2} = start_peer(:big_b, ctx.tmp, ctx.ebin)

      try do
        true = :peer.call(p1, :net_kernel, :connect_node, [n2])
        payload = :crypto.strong_rand_bytes(256 * 1024)

        echoed =
          :peer.call(p1, :rpc, :call, [n2, :erlang, :byte_size, [payload]])

        assert echoed == byte_size(payload)
      after
        :peer.stop(p2)
        :peer.stop(p1)
      end
    end
  end

  describe "abstract namespace sockets" do
    @describetag :linux_only

    test "two peers can connect over abstract sockets", ctx do
      ns = "uds_dist_test_#{System.unique_integer([:positive])}"

      {:ok, p1, _n1} = start_peer(:abs_a, "@" <> ns, ctx.ebin)
      {:ok, p2, n2} = start_peer(:abs_b, "@" <> ns, ctx.ebin)

      try do
        true = :peer.call(p1, :net_kernel, :connect_node, [n2])
        assert :peer.call(p1, :rpc, :call, [n2, :erlang, :node, []]) == n2

        # No filesystem entries should exist for either socket
        refute File.exists?("/tmp/" <> ns)
      after
        :peer.stop(p2)
        :peer.stop(p1)
      end
    end
  end

  defp start_peer(name, socket_dir, ebin) do
    :peer.start_link(%{
      name: name,
      connection: :standard_io,
      args: [
        ~c"-proto_dist",
        ~c"uds",
        ~c"-no_epmd",
        ~c"-dist_listen",
        ~c"true",
        ~c"-setcookie",
        ~c"uds_dist_test_cookie",
        ~c"-pa",
        ebin,
        ~c"-uds_dist",
        ~c"socket_dir",
        quote_erl_string(socket_dir)
      ]
    })
  end

  defp quote_erl_string(s) do
    # Erlang's -App Key Value parser evaluates Value as a term, so a string
    # must look like a quoted literal: "/tmp/foo" → `"\"/tmp/foo\""`.
    (~s("#{s}")) |> to_charlist()
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        Process.sleep(50)
        :continue
      end
    end)
    |> Enum.find(fn
      :ok -> true
      :continue -> System.monotonic_time(:millisecond) >= deadline
    end)
    |> case do
      :ok -> :ok
      :continue -> flunk("wait_until timed out after #{timeout_ms}ms")
    end
  end
end
