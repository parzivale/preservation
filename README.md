# Preservation

Declarative management of non-volatile system state for [finix](https://github.com/finix-community/finix).

Inspired and heavily influenced by [impermanence](https://github.com/nix-community/impermanence), but not meant to be a drop-in replacement. Unlike impermanence, preservation does not rely on interpreters, making it suitable for finix systems that use [finit](https://github.com/troglobit/finit) as PID 1.

## Documentation

Docs are available at <https://nix-community.github.io/preservation>

## Prerequisites

Requires at least nixos-24.11

## Why?

finix explores the NixOS design space using finit as PID 1, which means init-time tooling must work without scripting interpreters. Preservation provides impermanence-style declarative state management as a pure Nix solution — no shell, no Python, no runtime dependencies beyond what finix already provides.

Related:
- <https://github.com/NixOS/nixpkgs/issues/265640>
- <https://github.com/nix-community/projects/blob/main/proposals/nixpkgs-security-phase2.md#boot-chain-security>

## License

This project is released under the terms of the MIT License. See [LICENSE](./LICENSE).
