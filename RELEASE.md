### Changed

- Require Erlang/OTP 27 or newer, matching the Erlang syntax used by the library.
- Report distribution socket statistics as packet counts, consistent with OTP's `recv_cnt` and `send_cnt` semantics.

### Fixed

- Recognise binary `socket_dir` values beginning with `@` as Linux abstract namespace paths.
- Return stale socket deletion errors instead of retrying indefinitely.
- Close the accepted socket and distribution controller when the kernel rejects a protocol handshake.
- Raise a descriptive error when a Unix socket path exceeds Linux or macOS address limits.

### Security

- Document filesystem directory permissions and the local-access implications of abstract namespace sockets.
