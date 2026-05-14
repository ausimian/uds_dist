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
      # The socket goes away during net_kernel:terminate, but the peer's
      # controller gen_server only dies once the BEAM port closes —
      # wait for that before asserting :peer.stop trips an exit.
      :ok = wait_until(fn -> not Process.alive?(p) end, 5_000)
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

  describe "stress" do
    @describetag :stress
    @describetag timeout: :timer.minutes(2)

    test "many concurrent rpc.calls multiplex over a single connection", ctx do
      {:ok, p1, _n1} = start_peer(:stress_rpc_a, ctx.tmp, ctx.ebin)
      {:ok, p2, n2} = start_peer(:stress_rpc_b, ctx.tmp, ctx.ebin)

      try do
        true = :peer.call(p1, :net_kernel, :connect_node, [n2])

        n = 500

        results =
          1..n
          |> Task.async_stream(
            fn i ->
              payload = <<i::32, :crypto.strong_rand_bytes(512)::binary>>

              echoed =
                :peer.call(p1, :rpc, :call, [n2, :erlang, :byte_size, [payload]])

              {echoed, byte_size(payload)}
            end,
            max_concurrency: n,
            timeout: 60_000,
            ordered: false
          )
          |> Enum.map(fn {:ok, r} -> r end)

        assert length(results) == n
        assert Enum.all?(results, fn {echoed, expected} -> echoed == expected end)
      after
        :peer.stop(p2)
        :peer.stop(p1)
      end
    end

    test "bidirectional traffic spans the 64 KiB frame boundary", ctx do
      {:ok, p1, n1} = start_peer(:stress_bidir_a, ctx.tmp, ctx.ebin)
      {:ok, p2, n2} = start_peer(:stress_bidir_b, ctx.tmp, ctx.ebin)

      try do
        true = :peer.call(p1, :net_kernel, :connect_node, [n2])

        # Cycle below and above 64 KiB so frame lengths exercise both
        # short and long header paths in the input handler.
        sizes = Stream.cycle([64, 4_096, 70_000, 200_000]) |> Enum.take(80)

        shoot = fn sender, receiver ->
          Task.async(fn ->
            sizes
            |> Task.async_stream(
              fn size ->
                payload = :crypto.strong_rand_bytes(size)

                echoed =
                  :peer.call(sender, :rpc, :call, [
                    receiver,
                    :erlang,
                    :byte_size,
                    [payload]
                  ])

                {echoed, size}
              end,
              max_concurrency: 10,
              timeout: 60_000,
              ordered: false
            )
            |> Enum.map(fn {:ok, r} -> r end)
          end)
        end

        a_to_b = shoot.(p1, n2)
        b_to_a = shoot.(p2, n1)

        results_ab = Task.await(a_to_b, 120_000)
        results_ba = Task.await(b_to_a, 120_000)

        assert length(results_ab) == length(sizes)
        assert length(results_ba) == length(sizes)
        assert Enum.all?(results_ab, fn {echoed, expected} -> echoed == expected end)
        assert Enum.all?(results_ba, fn {echoed, expected} -> echoed == expected end)
      after
        :peer.stop(p2)
        :peer.stop(p1)
      end
    end

    test "many peers connect to a single hub concurrently", ctx do
      # Far in excess of the original BACKLOG=5; relies on the accept
      # loop spawning per-connection handshake helpers so it can drain
      # the kernel listen queue without waiting on each setup.
      k = 50
      {:ok, hub, hub_node} = start_peer(:stress_hub, ctx.tmp, ctx.ebin)

      spokes =
        for i <- 1..k do
          {:ok, p, n} = start_peer(:"stress_spoke_#{i}", ctx.tmp, ctx.ebin)
          {p, n}
        end

      try do
        spokes
        |> Task.async_stream(
          fn {p, _n} ->
            assert :peer.call(p, :net_kernel, :connect_node, [hub_node]) == true
          end,
          max_concurrency: k,
          timeout: 30_000
        )
        |> Stream.run()

        seen = :peer.call(hub, :erlang, :nodes, [])
        expected = Enum.map(spokes, fn {_, n} -> n end)
        assert Enum.sort(seen) == Enum.sort(expected)

        results =
          spokes
          |> Task.async_stream(
            fn {p, _n} ->
              :peer.call(p, :rpc, :call, [hub_node, :erlang, :node, []])
            end,
            max_concurrency: k,
            timeout: 30_000
          )
          |> Enum.map(fn {:ok, r} -> r end)

        assert Enum.all?(results, &(&1 == hub_node))
      after
        for {p, _n} <- spokes, do: :peer.stop(p)
        :peer.stop(hub)
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
