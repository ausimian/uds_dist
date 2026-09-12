defmodule UdsDistTest do
  use ExUnit.Case, async: false

  setup do
    previous = Application.get_env(:uds_dist, :socket_dir)
    previous_allowed_uids = Application.get_env(:uds_dist, :allowed_uids)
    previous_uds_dist_dir = System.get_env("UDS_DIST_DIR")
    previous_xdg_runtime_dir = System.get_env("XDG_RUNTIME_DIR")
    previous_path = System.get_env("PATH")
    tmp = Path.join(System.tmp_dir!(), "uds_dist_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.chmod!(tmp, 0o755)
    :persistent_term.erase({:uds_dist, :socket_dir})
    :persistent_term.erase({:uds_dist, :allowed_uids})
    Application.put_env(:uds_dist, :socket_dir, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      :persistent_term.erase({:uds_dist, :socket_dir})
      :persistent_term.erase({:uds_dist, :allowed_uids})
      restore_env("UDS_DIST_DIR", previous_uds_dist_dir)
      restore_env("XDG_RUNTIME_DIR", previous_xdg_runtime_dir)
      restore_env("PATH", previous_path)

      case previous do
        nil -> Application.delete_env(:uds_dist, :socket_dir)
        v -> Application.put_env(:uds_dist, :socket_dir, v)
      end

      case previous_allowed_uids do
        nil -> Application.delete_env(:uds_dist, :allowed_uids)
        v -> Application.put_env(:uds_dist, :allowed_uids, v)
      end
    end)

    %{tmp: tmp}
  end

  describe "configured_allowed_uids/0" do
    test "defaults to the listener's effective uid" do
      Application.delete_env(:uds_dist, :allowed_uids)

      assert :uds_dist.configured_allowed_uids() == [:uds_dist_posix.effective_uid()]
    end

    test "accepts any or a normalized list of numeric uids" do
      Application.put_env(:uds_dist, :allowed_uids, :any)
      assert :uds_dist.configured_allowed_uids() == :any

      Application.put_env(:uds_dist, :allowed_uids, [502, 501, 502])
      assert :uds_dist.configured_allowed_uids() == [501, 502]
    end

    test "interprets a charlist as its list of integer uid values" do
      Application.put_env(:uds_dist, :allowed_uids, ~c"1000")

      assert :uds_dist.configured_allowed_uids() == [48, 49]
    end

    test "rejects malformed policies" do
      for value <- [501, [:root], [-1], [501, "502"]] do
        Application.put_env(:uds_dist, :allowed_uids, value)

        assert_raise ErlangError, ~r/invalid_allowed_uids/, fn ->
          :uds_dist.configured_allowed_uids()
        end
      end
    end

    @tag :linux_only
    test "rejects Linux's unmapped uid sentinel in an explicit policy" do
      overflow_uid =
        "/proc/sys/kernel/overflowuid"
        |> File.read!()
        |> String.trim()
        |> String.to_integer()

      Application.put_env(:uds_dist, :allowed_uids, [overflow_uid])

      error =
        assert_raise ErlangError, ~r/contains_linux_overflow_uid/, fn ->
          :uds_dist.configured_allowed_uids()
        end

      assert {:invalid_allowed_uids,
              {:contains_linux_overflow_uid, ^overflow_uid, [^overflow_uid]}} = error.original
    end
  end

  describe "POSIX helper" do
    test "rejects peer credential lookup on an unconnected socket" do
      {:ok, socket} = :socket.open(:local, :stream, :default)

      try do
        assert {:error, _reason} = :uds_dist_posix.peer_effective_uid(socket)
      after
        :ok = :socket.close(socket)
      end
    end

    test "listen fails before binding when the NIF is unavailable", %{tmp: tmp} do
      staged_root = Path.join(tmp, "uds_dist-1.0.1")
      staged_ebin = Path.join(staged_root, "ebin")
      source_ebin = :code.lib_dir(:uds_dist) |> List.to_string() |> Path.join("ebin")
      File.mkdir_p!(staged_root)
      File.cp_r!(source_ebin, staged_ebin)

      name = "missing_nif_#{System.unique_integer([:positive])}"

      eval =
        ~c'First = uds_dist:listen(#{name}), Second = uds_dist:listen(#{name}), io:format("~tp~n~tp~n", [First, Second]), halt().'

      {output, 0} =
        System.cmd(
          System.find_executable("erl"),
          [
            "-pa",
            staged_ebin,
            "-uds_dist",
            "allowed_uids",
            "any",
            "-noshell",
            "-eval",
            List.to_string(eval)
          ],
          stderr_to_stdout: true,
          env: [{"ERL_CRASH_DUMP", Path.join(tmp, "missing_nif.dump")}]
        )

      assert output =~ "posix_helper_unavailable"
      assert output =~ "load_failed"
      refute File.exists?("/tmp/uds-dist-#{name}.sock")
    end
  end

  describe "select/1" do
    test "returns true for any node name" do
      assert :uds_dist.select(:foo@bar) == true
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
      assert :uds_dist.strip_host(:node@host) == ~c"node"
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

    test "application configuration takes precedence over environment", %{tmp: tmp} do
      System.put_env("UDS_DIST_DIR", Path.join(tmp, "from_env"))

      assert :uds_dist.resolve_path(~c"node") ==
               :erlang.iolist_to_binary(Path.join(tmp, "node.sock"))
    end

    test "uses UDS_DIST_DIR when application configuration is absent", %{tmp: tmp} do
      uds_dir = Path.join(tmp, "from_env")
      Application.delete_env(:uds_dist, :socket_dir)
      System.put_env("UDS_DIST_DIR", uds_dir)

      assert :uds_dist.resolve_path(~c"node") ==
               :erlang.iolist_to_binary(Path.join(uds_dir, "node.sock"))
    end

    test "ignores XDG_RUNTIME_DIR so independently started processes agree", %{tmp: tmp} do
      Application.delete_env(:uds_dist, :socket_dir)
      System.delete_env("UDS_DIST_DIR")
      System.put_env("XDG_RUNTIME_DIR", tmp)

      assert :uds_dist.resolve_path(~c"node") == "/tmp/uds-dist-node.sock"
    end

    test "defaults to a host-global node path under /tmp" do
      Application.delete_env(:uds_dist, :socket_dir)
      System.delete_env("UDS_DIST_DIR")

      assert :uds_dist.resolve_path(~c"node") == "/tmp/uds-dist-node.sock"
    end

    test "does not need a shell to resolve the default path" do
      Application.delete_env(:uds_dist, :socket_dir)
      System.delete_env("UDS_DIST_DIR")
      System.put_env("PATH", "")

      assert :uds_dist.resolve_path(~c"node") == "/tmp/uds-dist-node.sock"
    end

    @tag :linux_only
    test "produces an abstract path for a binary socket_dir starting with @" do
      Application.put_env(:uds_dist, :socket_dir, "@uds_dist_test")

      path = :uds_dist.resolve_path(~c"node")
      assert <<0, "uds_dist_test/node">> == path
    end

    test "continues to accept charlist socket_dir values" do
      Application.put_env(:uds_dist, :socket_dir, ~c"uds_dist_test")

      assert :uds_dist.resolve_path(~c"node") == "uds_dist_test/node.sock"
    end

    test "rejects invalid socket_dir values" do
      for value <- [:tmp, "", <<255>>] do
        Application.put_env(:uds_dist, :socket_dir, value)

        error =
          assert_raise ErlangError, ~r/invalid_socket_dir/, fn ->
            :uds_dist.resolve_path(~c"node")
          end

        assert {:invalid_socket_dir, ^value} = error.original
      end
    end

    test "raises a descriptive error for an overlong socket path" do
      Application.put_env(:uds_dist, :socket_dir, String.duplicate("x", 108))

      error =
        assert_raise ErlangError, ~r/socket_path_too_long/, fn ->
          :uds_dist.resolve_path(~c"node")
        end

      assert {:socket_path_too_long, path, limit} = error.original
      assert is_binary(path)
      assert byte_size(path) + 1 > limit
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

    test "creates a missing socket directory with mode 0755", %{tmp: tmp} do
      socket_dir = Path.join(tmp, "created_by_listen")
      Application.put_env(:uds_dist, :socket_dir, socket_dir)

      {:ok, {listen, _, _}} = :uds_dist.listen(:created)

      assert File.dir?(socket_dir)
      assert Bitwise.band(File.stat!(socket_dir).mode, 0o777) == 0o755

      assert Bitwise.band(File.stat!(Path.join(socket_dir, "created.sock")).mode, 0o777) ==
               0o666

      :ok = :uds_dist.close(listen)
    end

    test "reads the connecting process effective uid from an accepted socket" do
      {:ok, {listen, _, _}} = :uds_dist.listen(:peer_credentials)
      {:ok, client} = :socket.open(:local, :stream, :default)

      try do
        path = :uds_dist.resolve_path(~c"peer_credentials")
        :ok = :socket.connect(client, %{family: :local, path: path})
        {:ok, accepted} = :socket.accept(listen)

        try do
          assert :uds_dist_posix.peer_effective_uid(accepted) ==
                   {:ok, :uds_dist_posix.effective_uid()}
        after
          :ok = :socket.close(accepted)
        end
      after
        :ok = :socket.close(client)
        :ok = :uds_dist.close(listen)
      end
    end

    test "does not create missing parent directories", %{tmp: tmp} do
      socket_dir = Path.join([tmp, "missing", "leaf"])
      Application.put_env(:uds_dist, :socket_dir, socket_dir)

      assert {:error, :enoent} = :uds_dist.listen(:no_parents)
      refute File.exists?(Path.join(tmp, "missing"))
    end

    test "rejects a pre-existing directory with unsafe permissions", %{tmp: tmp} do
      socket_dir = Path.join(tmp, "world_writable")
      File.mkdir!(socket_dir)
      File.chmod!(socket_dir, 0o777)
      Application.put_env(:uds_dist, :socket_dir, socket_dir)

      path = :erlang.iolist_to_binary(socket_dir)

      assert {:error, {:unsafe_socket_dir, ^path, {:unsafe_mode, 0o777}}} =
               :uds_dist.listen(:unsafe_mode)
    end

    test "rejects a symlinked socket directory", %{tmp: tmp} do
      target = Path.join(tmp, "target")
      socket_dir = Path.join(tmp, "link")
      File.mkdir!(target)
      File.chmod!(target, 0o755)
      File.ln_s!(target, socket_dir)
      Application.put_env(:uds_dist, :socket_dir, socket_dir)

      path = :erlang.iolist_to_binary(socket_dir)

      assert {:error, {:unsafe_socket_dir, ^path, :symlink}} =
               :uds_dist.listen(:unsafe_link)
    end

    test "rejects a socket directory owned by another user" do
      uid = :uds_dist_posix.effective_uid()

      if uid == 0 do
        :ok
      else
        Application.put_env(:uds_dist, :socket_dir, "/")

        assert {:error, {:unsafe_socket_dir, "/", {:not_owned, 0, ^uid}}} =
                 :uds_dist.listen(:other_owner)
      end
    end

    test "pins the directory used by listen for later path resolution", %{tmp: tmp} do
      original_dir = Path.join(tmp, "original")
      changed_dir = Path.join(tmp, "changed")
      Application.put_env(:uds_dist, :socket_dir, original_dir)

      {:ok, {listen, _, _}} = :uds_dist.listen(:pinned)
      Application.put_env(:uds_dist, :socket_dir, changed_dir)

      assert :uds_dist.resolve_path(~c"peer") ==
               :erlang.iolist_to_binary(Path.join(original_dir, "peer.sock"))

      :ok = :uds_dist.close(listen)

      assert :persistent_term.get({:uds_dist, :socket_dir}, :missing) == :missing
      assert :persistent_term.get({:uds_dist, :allowed_uids}, :missing) == :missing

      assert :uds_dist.resolve_path(~c"peer") ==
               :erlang.iolist_to_binary(Path.join(changed_dir, "peer.sock"))
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

    test "a stale entry that cannot be deleted returns the delete error", %{tmp: tmp} do
      blocked = Path.join(tmp, "blocked.sock")
      File.mkdir!(blocked)

      assert {:error, reason} = :uds_dist.listen(:blocked)
      assert reason in [:eacces, :eisdir, :eperm]
    end

    @tag :linux_only
    test "abstract sockets bind and close without a filesystem entry" do
      Application.put_env(:uds_dist, :socket_dir, ~c"@uds_dist_test_abs")

      {:ok, {listen, addr, _}} = :uds_dist.listen(:abs1)
      assert {:net_address, {:local, <<0, "uds_dist_test_abs/abs1">>}, _, _, _} = addr

      :ok = :uds_dist.close(listen)
    end
  end

  describe "accept_handshake/2" do
    test "closes the controller and socket when the kernel rejects the protocol" do
      {:ok, socket} = :socket.open(:local, :stream, :default)
      helper = spawn(:uds_dist, :accept_handshake, [self(), socket])

      assert_receive {:accept, ^helper, controller, :local, :stream}
      helper_ref = Process.monitor(helper)
      controller_ref = Process.monitor(controller)

      send(helper, {self(), :unsupported_protocol})

      assert_receive {:DOWN, ^helper_ref, :process, ^helper, :unsupported_protocol}
      assert_receive {:DOWN, ^controller_ref, :process, ^controller, :unsupported_protocol}

      info = :socket.info(socket)
      assert :closed in info.rstates
      assert :closed in info.wstates
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
