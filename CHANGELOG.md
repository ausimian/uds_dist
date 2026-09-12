# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- %% CHANGELOG_ENTRIES %% -->

## 2.0.0 - 2026-09-12

This release changes the default socket location and replaces filesystem-only
connection isolation with explicit kernel peer-credential authorization. Review
socket paths and `allowed_uids` before upgrading.

### Added

- Support `UDS_DIST_DIR` as a boot-time socket directory source.
- Add `allowed_uids` application configuration and boot arguments. The policy defaults to the process's effective UID and accepts `any` or a list of trusted numeric UIDs.

### Changed

- **Breaking:** Replace the working-directory socket default with `/tmp/uds-dist-<node-name>.sock`. Path selection now follows application configuration, `UDS_DIST_DIR`, then the host-global fallback.
- **Breaking:** Explicit filesystem socket directories now use mode `0755`, and socket files use mode `0666`. A missing directory leaf is created automatically; an existing leaf must be a real directory owned by the process's effective UID with mode `0755`.
- **Breaking:** Change the overlong-path exception from `{socket_path_too_long, #{bytes => Bytes, max_bytes => Limit}}` to `{socket_path_too_long, Path, Limit}`, and extend path-length validation to the supported BSD platforms.
- **Breaking:** Require Linux, macOS, FreeBSD, NetBSD, OpenBSD, or DragonFly BSD so peer credentials can be enforced. Unsupported platforms fail at listener startup.
- Retain the listener's resolved socket directory and UID policy until it closes, ensuring inbound and outbound connections use the same settings even if the environment changes.
- Log the resolved socket path and accepted-peer UID policy when the listener starts.
- Building from source now requires `make` and a C compiler for the small POSIX helper NIF, built through `elixir_make`.

### Security

- Authorize both inbound and outbound connections from kernel-supplied peer credentials before exchanging distribution-handshake data.
- Fail closed when peer credentials or the POSIX helper are unavailable, reject Linux's `overflowuid` sentinel in explicit UID policies, and rate-limit rejected-connection logs.

Before a rolling upgrade from 1.0.x, configure every node with the new socket location; otherwise old and upgraded nodes will resolve different defaults and cannot connect. Change an existing mode-`0700` configured socket directory to `0755`. Cross-user release commands need an allowed UID policy and access to the daemon's distribution cookie.

## 1.0.1 - 2026-09-12

### Changed

- Publish tagged package versions to Hex.pm after the complete CI matrix passes.
- Require Erlang/OTP 27 or newer, matching the Erlang syntax used by the library.
- Report distribution socket statistics as packet counts, consistent with OTP's `recv_cnt` and `send_cnt` semantics.

### Fixed

- Recognise binary `socket_dir` values beginning with `@` as Linux abstract namespace paths.
- Return stale socket deletion errors instead of retrying indefinitely.
- Close the accepted socket and distribution controller when the kernel rejects a protocol handshake.
- Raise a descriptive error when a Unix socket path exceeds Linux or macOS address limits.

### Security

- Document filesystem directory permissions and the local-access implications of abstract namespace sockets.

## 1.0.0 - 2026-05-14

### Added

- Initial `uds_dist` module — custom Erlang distribution over Unix domain sockets using the `:socket` module, supporting both filesystem-backed and Linux abstract namespace sockets. Path selection is driven by the `socket_dir` application environment value, with a leading `@` selecting the abstract namespace.