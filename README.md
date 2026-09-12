# uds_dist

Erlang distribution over Unix domain sockets via the `:socket` module. Lets Elixir and Erlang nodes connect to each other without opening TCP listeners — useful for releases that need a local `remote` shell but should not expose distribution over the network.

Filesystem-backed sockets work on any Unix-like platform. Linux additionally supports abstract namespace sockets that live in kernel state rather than on disk.

## Requirements

OTP 27 or newer. Erlang distribution protocol version 6 only.

## Installation

```elixir
def deps do
  [{:uds_dist, "~> 1.0"}]
end
```

## Configuration

Every node — the listening release and any client connecting in — needs the same `-proto_dist` and EPMD-bypass flags:

```
-proto_dist uds
-no_epmd
```

Path resolution is driven by `:socket_dir` in the `:uds_dist` application environment. The part of the node name before `@` becomes the socket file's name within that directory.

```elixir
# config/runtime.exs
config :uds_dist, socket_dir: "/run/myapp"
```

A node named `myapp@host` then listens at `/run/myapp/myapp.sock`. Anything after `@` is ignored — all traffic is local, so the host part is conventional only.

If `socket_dir` is omitted the default is `"."`, meaning sockets are created relative to the BEAM's working directory. Convenient for ad-hoc testing; not recommended for releases.

On Linux and macOS, `uds_dist` validates the encoded Unix socket address before opening it and raises a `socket_path_too_long` error containing the actual and maximum sizes when it will not fit the platform's `sockaddr_un` representation.

When a filesystem socket is left behind by an abrupt shutdown, `uds_dist` probes it and removes it if it is stale. The probe-and-remove sequence cannot be atomic: concurrent attempts to start the same node name can race. Serialize starts for a given node name through the service manager.

### Abstract namespace sockets (Linux only)

A `socket_dir` value beginning with `@` selects the Linux abstract namespace. Abstract sockets have no filesystem entry, no permission bits, and are cleaned up by the kernel when their owner exits.

```elixir
config :uds_dist, socket_dir: "@myapp"
```

A node named `myapp@host` then listens at the abstract path `\0myapp/myapp`.

Configuring an abstract `socket_dir` on a non-Linux platform raises at `listen/1` or `setup/5` time. There is no automatic fallback.

### Security

For filesystem sockets, create a directory owned by the release user with mode `0700` and point `socket_dir` at it. Directory permissions provide a stronger portability boundary than relying on the socket file's own mode.

Abstract sockets have no permission bits. Any local process can reach them, so the Erlang distribution cookie is the only authentication boundary. Use a strong, deployment-specific cookie and protect it like a credential.

### Listen backlog

The kernel listen backlog defaults to 5 and can be overridden:

```elixir
config :uds_dist, backlog: 128
```

The value is read at `listen/1` time, so setting it in `config/runtime.exs` of a release is sufficient.

## Release integration

`rel/vm.args.eex`:

```
-proto_dist uds
-no_epmd
```

`rel/remote.vm.args.eex` — used by `bin/<rel> remote`:

```
-proto_dist uds
-no_epmd
-dist_listen false
```

`-dist_listen false` tells `net_kernel` to call `address/0` instead of `listen/1`, so the remote shell does not create its own socket file.

Set `socket_dir` in `config/runtime.exs`:

```elixir
import Config
config :uds_dist, socket_dir: "/run/#{System.get_env("RELEASE_NAME", "myapp")}"
```

Make sure the directory exists with the right ownership before the release boots. `rel/env.sh.eex` is a good place:

```sh
mkdir -p "/run/${RELEASE_NAME}"
```

After deployment `bin/<rel> remote` opens a shell via the UDS instead of TCP, with no other changes needed.

## Local development (`iex -S mix`)

The BEAM processes `-proto_dist` before Mix has set up the dependency code path, so `net_kernel` cannot find `uds_dist` if you start distribution at boot from a Mix project. Pass `-pa` explicitly to fix it:

```sh
iex \
  --erl "-pa _build/dev/lib/uds_dist/ebin -proto_dist uds -no_epmd" \
  --sname server -S mix
```

Set the socket directory for the dev environment so both nodes can find each other:

```elixir
# config/config.exs
import Config

if Mix.env() == :dev do
  config :uds_dist, socket_dir: Path.join(System.tmp_dir!(), "uds_dist_dev")
end
```

Start a second node the same way with a different `--sname` and run `Node.connect/1` from either side. Releases do not need this workaround — the boot script populates the code path before `-proto_dist` is consulted.

## Publishing to Hex.pm

CI publishes the package and its documentation to Hex.pm when a bare version tag such as `1.1.0` is pushed. The publish job waits for the complete test matrix and rejects the release unless:

- the tagged commit is on `main`
- the tag exactly matches the `@version` value in `mix.exs`
- the `HEX_API_KEY` repository secret is configured

Create a dedicated API key from the [Hex.pm keys dashboard](https://hex.pm/dashboard/keys):

1. Sign in with a Hex.pm account that owns or maintains the `uds_dist` package.
2. Select **Generate New Key**.
3. Name it `uds-dist-github-actions`, choose an appropriate expiry, and grant only **API → Write** permission.
4. Copy the key when shown; Hex.pm displays it only once.
5. In the GitHub repository, open **Settings → Secrets and variables → Actions**, create a repository secret named `HEX_API_KEY`, and paste the key as its value.

Never commit or print the key. Revoke it from the Hex.pm dashboard and replace the GitHub secret if it is exposed or no longer needed.

To release, update `RELEASE.md`, then use `mix publisho <level>` to update the version, changelog, commit, and bare version tag. Review the result before pushing both the branch and tag:

```sh
git push
git push --tags
```

## How it works

`uds_dist` implements the seven callbacks an Erlang distribution module must export (`listen/1`, `accept/1`, `accept_connection/5`, `setup/5`, `close/1`, `select/1`, `address/0`) against the `:socket` NIF rather than `gen_tcp`. EPMD is bypassed entirely: `setup/5` derives the target's socket path from the node name plus the configured `socket_dir`, so no registry is needed.

Post-handshake each connection has three processes:

- **Output handler** — sole writer, also handles distribution ticks
- **Input handler** — greedy reader; pulls available bytes from the kernel buffer and parses length-prefixed frames out of the accumulator
- **Connection supervisor** — supplied by `dist_util`

Length prefixes are hand-rolled in Erlang since `:socket` has no `{packet, N}` mode: 2 bytes during handshake, 4 bytes after.

The implementation is modelled on OTP's `lib/kernel/examples/erl_uds_dist` example. Notable differences from that reference: `:socket` instead of `gen_tcp`, distribution protocol version 6 only, abstract namespace support, and socket-path resolution driven by application config rather than by the bare node name.

## License

MIT. See [`LICENSE`](LICENSE).
