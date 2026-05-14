# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- %% CHANGELOG_ENTRIES %% -->

## 1.0.0 - 2026-05-14

### Added

- Initial `uds_dist` module — custom Erlang distribution over Unix domain sockets using the `:socket` module, supporting both filesystem-backed and Linux abstract namespace sockets. Path selection is driven by the `socket_dir` application environment value, with a leading `@` selecting the abstract namespace.