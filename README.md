# uds_dist

Erlang distribution over Unix domain sockets via the `:socket` module. Lets Elixir and Erlang nodes connect to each other without opening TCP listeners — useful for releases that need a local `remote` shell but should not expose distribution over the network.

Filesystem-backed sockets are supported on Linux, macOS, FreeBSD, NetBSD, OpenBSD, and DragonFly BSD. Linux additionally supports abstract namespace sockets that live in kernel state rather than on disk.

## Requirements

OTP 27 or newer. Erlang distribution protocol version 6 only. Building the package from source requires `make` and a C compiler for its small POSIX helper NIF.

## Installation

```elixir
def deps do
  [{:uds_dist, "~> 2.0"}]
end
```

## Configuration

Every node — the listening release and any client connecting in — needs the same `-proto_dist` and EPMD-bypass flags:

```
-proto_dist uds
-no_epmd
```

The part of the node name before `@` becomes the socket file's name. `uds_dist` selects its path in this order:

1. `:socket_dir` in the `:uds_dist` application environment, including a `-uds_dist socket_dir` boot argument
2. The `UDS_DIST_DIR` environment variable
3. `/tmp/uds-dist-<node-name>.sock`

The application setting is useful when runtime configuration is already available:

```elixir
# config/runtime.exs
config :uds_dist, socket_dir: "/run/myapp"
```

A node named `myapp@host` then listens at `/run/myapp/myapp.sock`. Anything after `@` is ignored — all traffic is local, so the host part is conventional only.

`UDS_DIST_DIR` is usually the simplest boot-time override. It is available before Mix loads configuration and avoids Erlang-term quoting in VM arguments:

```sh
UDS_DIST_DIR=/tmp/myapp-uds iex --sname myapp -S mix
```

Boot-argument values are Erlang terms, so a filesystem path must include literal quotes, for example `-uds_dist socket_dir '"/run/myapp"'`. Invalid or empty application values raise `{invalid_socket_dir, Value}`. An empty `UDS_DIST_DIR` is treated as unset.

For an explicit `socket_dir` or `UDS_DIST_DIR`, `listen/1` creates the selected filesystem directory with mode `0755`. It creates only the final directory component: the parent must already exist. An existing directory must be a real directory rather than a symlink, must be owned by the process's effective user ID, and must have mode `0755`; otherwise the listener returns an `unsafe_socket_dir` error. The directory is traversable by local users but only its owner can replace socket entries. The default writes directly into the existing sticky `/tmp` directory. Every filesystem socket, including the default, is set to mode `0666`. Connection authorization is performed separately from filesystem permissions using kernel-provided peer credentials.

Once listening succeeds, the selected path strategy and peer policy are retained until that listener closes, so changing configuration or environment variables cannot make its listening and connection setup paths disagree. Closing the listener clears both values, allowing a later listener to use updated configuration. The resolved path and peer policy are logged at boot.

The default deliberately does not use the working directory, `$TMPDIR`, or `$XDG_RUNTIME_DIR`. Environment-derived defaults can differ between a service and an interactive login, while macOS `$TMPDIR` paths are often long enough to approach the 104-byte Unix socket path limit. A node therefore has the same short default path for every local user and launch environment.

When rolling forward from 1.0.x, configure every old-version node with the new socket location before upgrading any node. That prevents old nodes using the working-directory default from being separated from upgraded nodes using the new host-global default. An existing mode-`0700` configured socket directory must be changed to `0755` before starting this version.

On Linux and macOS, `uds_dist` validates the encoded Unix socket address before opening it and raises `{socket_path_too_long, Path, Limit}` when it will not fit the platform's `sockaddr_un` representation. The limit is 108 bytes on Linux and 104 bytes on macOS/BSD.

When a filesystem socket is left behind by an abrupt shutdown, `uds_dist` probes it and removes it if it is stale. The probe-and-remove sequence cannot be atomic: concurrent attempts to start the same node name can race. Serialize starts for a given node name through the service manager.

For explicit directories, the library validates the selected leaf, not every ancestor. Use a trusted parent directory. The default socket name is predictable, so another local user can claim it before the daemon and deny startup. `/tmp`'s sticky bit prevents replacement after the daemon has created its socket, but can also make an attacker-owned stale entry removable only by that user or root. Services should prefer a directory prepared by their service manager.

### Abstract namespace sockets (Linux only)

A `socket_dir` value beginning with `@` selects the Linux abstract namespace. Abstract sockets have no filesystem entry, no permission bits, and are cleaned up by the kernel when their owner exits.

```elixir
config :uds_dist, socket_dir: "@myapp"
```

A node named `myapp@host` then listens at the abstract path `\0myapp/myapp`.

Configuring an abstract `socket_dir` on a non-Linux platform raises at `listen/1` or `setup/5` time. There is no automatic fallback.

### Security

Every inbound and outbound connection is authorized from credentials supplied by the kernel: `SO_PEERCRED` on Linux and `getpeereid()` on macOS/BSD. The check happens on the connected socket before any distribution-handshake data is exchanged. By default, a process trusts only peers running with its own effective numeric UID. Configure `:allowed_uids` as `:any` or as a list of trusted numeric UIDs to change that policy:

```elixir
# Allow any local user who also has the distribution cookie
config :uds_dist, allowed_uids: :any

# Or allow only these effective UIDs
config :uds_dist, allowed_uids: [1000, 1001]
```

The equivalent boot arguments are `-uds_dist allowed_uids any` and `-uds_dist allowed_uids '[1000,1001]'`. UID lists are normalized at boot; malformed values raise `{invalid_allowed_uids, Value}`. The input is a list of integers and is interpreted exactly as such: an Erlang string or charlist such as `"1000"` is the integer list `[49,48,48,48]`, not UID `1000`. On Linux, an explicit list cannot contain the kernel's `/proc/sys/kernel/overflowuid` value because an unmapped user-namespace UID is indistinguishable from that numeric UID in `SO_PEERCRED`; use a different account UID. Credential lookup failures reject the connection rather than falling back to the cookie alone. The policy is symmetric: a cross-user deployment should list both the service UID and every permitted operator UID so the daemon trusts the operator and the operator's `remote` process trusts the daemon.

The POSIX helper and platform support are checked before the socket is bound. A missing or unloadable NIF returns `{error, {posix_helper_unavailable, Reason}}`; an unsupported platform returns `{error, {peer_credentials_unsupported, OsType}}`. Rejected-connection logging is rate-limited so a local connection flood cannot generate one log event per attempt.

The Erlang distribution cookie remains mandatory after the peer-UID check. Treat it as a credential even with the default same-user policy. Setting `allowed_uids` to `any` gives the same local reachability as a Linux abstract socket: any local user who can reach the path and obtain the cookie can attempt to connect. The same peer policy applies to abstract sockets.

For a cross-user `bin/<rel> remote`, configure `allowed_uids` to `any` or include both the daemon and remote users' numeric UIDs. Make the same policy available to the daemon and release command. The host-global default path already agrees across users. When using an explicit `socket_dir`, ensure its ancestors are traversable by the remote user and make the same path available to both processes. The remote user must still have the daemon's cookie.

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

For a service-managed production path, set `UDS_DIST_DIR` in `rel/env.sh.eex` so the same value is available during early boot and to release commands:

```sh
export UDS_DIST_DIR="/run/${RELEASE_NAME}"
```

The parent directory must exist and be writable by the release user. For `/run`, have the service manager create and own a mode-`0755` directory (for example, systemd's default `RuntimeDirectory=` mode), then either use that directory directly or configure a writable parent under which `uds_dist` can create its leaf.

Application configuration remains available when it better fits the deployment and takes precedence over `UDS_DIST_DIR`:

```elixir
import Config
config :uds_dist, socket_dir: "/run/#{System.get_env("RELEASE_NAME", "myapp")}"
```

After deployment `bin/<rel> remote` opens a shell via the UDS instead of TCP, with no other changes needed.

## Local development (`iex -S mix`)

The BEAM processes `-proto_dist` before Mix has set up the dependency code path, so `net_kernel` cannot find `uds_dist` if you start distribution at boot from a Mix project. Pass `-pa` explicitly to fix it:

```sh
iex \
  --erl "-pa _build/dev/lib/uds_dist/ebin -proto_dist uds -no_epmd" \
  --sname server -S mix
```

You can set the same environment variable for both nodes to choose a development-specific directory without waiting for Mix configuration:

```sh
UDS_DIST_DIR=/tmp/uds_dist_dev iex \
  --erl "-pa _build/dev/lib/uds_dist/ebin -proto_dist uds -no_epmd" \
  --sname server -S mix

UDS_DIST_DIR=/tmp/uds_dist_dev iex \
  --erl "-pa _build/dev/lib/uds_dist/ebin -proto_dist uds -no_epmd" \
  --sname client -S mix
```

Run `Node.connect/1` from either side. Releases do not need the explicit `-pa` workaround — the boot script populates the code path before `-proto_dist` is consulted.

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

`uds_dist` implements the seven callbacks an Erlang distribution module must export (`listen/1`, `accept/1`, `accept_connection/5`, `setup/5`, `close/1`, `select/1`, `address/0`) against the `:socket` NIF rather than `gen_tcp`. EPMD is bypassed entirely: `setup/5` derives the target's socket path from the node name and configured path strategy, so no registry is needed.

Post-handshake each connection has three processes:

- **Output handler** — sole writer, also handles distribution ticks
- **Input handler** — greedy reader; pulls available bytes from the kernel buffer and parses length-prefixed frames out of the accumulator
- **Connection supervisor** — supplied by `dist_util`

Length prefixes are hand-rolled in Erlang since `:socket` has no `{packet, N}` mode: 2 bytes during handshake, 4 bytes after.

The implementation is modelled on OTP's `lib/kernel/examples/erl_uds_dist` example. Notable differences from that reference: `:socket` instead of `gen_tcp`, distribution protocol version 6 only, abstract namespace support, peer-credential authorization, and deterministic host-global default paths.

## License

MIT. See [`LICENSE`](LICENSE).
