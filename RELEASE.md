### Added

- Initial `uds_dist` module — custom Erlang distribution over Unix domain sockets using the `:socket` module, supporting both filesystem-backed and Linux abstract namespace sockets. Path selection is driven by the `socket_dir` application environment value, with a leading `@` selecting the abstract namespace.

### Changed

- Accept loop now spawns the kernel handshake into a per-connection helper, so it can immediately re-enter `socket:accept/1` and drain the listen queue under bursts of concurrent dialers. Listen backlog raised from 5 to 128.
