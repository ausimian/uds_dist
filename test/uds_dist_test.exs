defmodule UdsDistTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:uds_dist, :socket_dir)
    tmp = Path.join(System.tmp_dir!(), "uds_dist_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:uds_dist, :socket_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)

      case previous do
        nil -> Application.delete_env(:uds_dist, :socket_dir)
        v -> Application.put_env(:uds_dist, :socket_dir, v)
      end
    end)

    %{tmp: tmp}
  end

  describe "select/1" do
    test "returns true for any node name" do
      assert :uds_dist.select(:"foo@bar") == true
      assert :uds_dist.select(:"name@127.0.0.1") == true
      assert :uds_dist.select(:bare) == true
    end
  end

  describe "address/0" do
    test "returns a net_address with local family and stream protocol" do
      addr = :uds_dist.address()
      assert {:net_address, _addr, :localhost, :stream, :local} = addr
    end
  end

  describe "strip_host/1" do
    test "drops everything from @ onwards on shortnames" do
      assert :uds_dist.strip_host(:"node@host") == ~c"node"
    end

    test "drops everything from @ onwards on longnames" do
      assert :uds_dist.strip_host(:"node@host.example.com") == ~c"node"
    end

    test "returns the whole name when there is no @" do
      assert :uds_dist.strip_host(:lone) == ~c"lone"
    end

    test "accepts a list as input" do
      assert :uds_dist.strip_host(~c"node@host") == ~c"node"
    end
  end

  describe "resolve_path/1" do
    test "uses configured socket_dir for filesystem paths", %{tmp: tmp} do
      assert :uds_dist.resolve_path(~c"node") ==
               :erlang.iolist_to_binary(Path.join(tmp, "node.sock"))
    end

    test "defaults to cwd when no config is set" do
      Application.delete_env(:uds_dist, :socket_dir)
      assert :uds_dist.resolve_path(~c"node") == "./node.sock"
    end

    @tag :linux_only
    test "produces an abstract path for socket_dir starting with @" do
      Application.put_env(:uds_dist, :socket_dir, ~c"@uds_dist_test")

      path = :uds_dist.resolve_path(~c"node")
      assert <<0, "uds_dist_test/node">> == path
    end

    test "raises on non-linux when abstract is requested" do
      if :uds_dist.abstract_supported() do
        :ok
      else
        Application.put_env(:uds_dist, :socket_dir, ~c"@foo")

        assert_raise ErlangError, fn ->
          :uds_dist.resolve_path(~c"node")
        end
      end
    end
  end

  describe "abstract_supported/0" do
    test "agrees with os:type/0" do
      expected =
        case :os.type() do
          {:unix, :linux} -> true
          _ -> false
        end

      assert :uds_dist.abstract_supported() == expected
    end
  end

  describe "setopts/2 and getopts/2" do
    test "are no-ops with the expected return shapes" do
      assert :uds_dist.setopts(:fake_listen, []) == :ok
      assert :uds_dist.getopts(:fake_listen, []) == {:ok, []}
    end
  end

  describe "accept/1" do
    test "spawns an acceptor that exits when the listen socket is closed", %{tmp: _tmp} do
      Process.flag(:trap_exit, true)
      {:ok, {listen, _, _}} = :uds_dist.listen(:acceptor)
      pid = :uds_dist.accept(listen)
      assert is_pid(pid)

      ref = Process.monitor(pid)
      :ok = :uds_dist.close(listen)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end
  end

  describe "listen/1 and close/1" do
    test "creates a socket file under socket_dir and removes it on close", %{tmp: tmp} do
      {:ok, {listen, addr, creation}} = :uds_dist.listen(:smoke)
      sock_path = Path.join(tmp, "smoke.sock")

      assert File.exists?(sock_path)
      assert is_integer(creation) and creation > 3
      assert {:net_address, {:local, _}, :localhost, :stream, :local} = addr

      :ok = :uds_dist.close(listen)
      refute File.exists?(sock_path)
    end

    test "two listens on the same name reject the live duplicate" do
      {:ok, {listen1, _, _}} = :uds_dist.listen(:dup)
      assert {:error, :duplicate_name} = :uds_dist.listen(:dup)
      :ok = :uds_dist.close(listen1)
    end

    test "a stale socket file is reaped and the listen succeeds", %{tmp: tmp} do
      stale = Path.join(tmp, "stale.sock")
      :ok = :socket.open(:local, :stream, :default) |> elem(1) |> :socket.close()
      File.touch!(stale)

      assert File.exists?(stale)
      {:ok, {listen, _, _}} = :uds_dist.listen(:stale)
      assert File.exists?(stale)
      :ok = :uds_dist.close(listen)
    end

    @tag :linux_only
    test "abstract sockets bind and close without a filesystem entry" do
      Application.put_env(:uds_dist, :socket_dir, ~c"@uds_dist_test_abs")

      {:ok, {listen, addr, _}} = :uds_dist.listen(:abs1)
      assert {:net_address, {:local, <<0, "uds_dist_test_abs/abs1">>}, _, _, _} = addr

      :ok = :uds_dist.close(listen)
    end
  end
end
