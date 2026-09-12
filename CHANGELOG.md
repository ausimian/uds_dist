# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- %% CHANGELOG_ENTRIES %% -->

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