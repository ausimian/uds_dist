ExUnit.start()

excludes = [:stress]

excludes =
  case :os.type() do
    {:unix, :linux} -> excludes
    _ -> [:linux_only | excludes]
  end

ExUnit.configure(exclude: excludes)

# Peer beams started by uds_dist_peer_test.exs are separate VMs that the local
# :cover server cannot instrument over distribution (peers communicate via
# stdio). Each peer instead runs its own :cover and exports its counters to a
# file on shutdown; we import the files after the suite to fold peer-driven
# execution back into the headline coverage number.
peer_cover_dir = Path.expand("../cover/peer_exports", __DIR__)
File.rm_rf!(peer_cover_dir)
File.mkdir_p!(peer_cover_dir)
Application.put_env(:uds_dist, :peer_cover_dir, peer_cover_dir)

ExUnit.after_suite(fn _ ->
  if Process.whereis(:cover_server) do
    for path <- Path.wildcard(Path.join(peer_cover_dir, "*.coverdata")) do
      :cover.import(to_charlist(path))
    end
  end
end)
