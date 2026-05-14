### Added

- Initial `uds_dist` module — custom Erlang distribution over Unix domain sockets using the `:socket` module, supporting both filesystem-backed and Linux abstract namespace sockets. Path selection is driven by the `socket_dir` application environment value, with a leading `@` selecting the abstract namespace.
