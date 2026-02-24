# Release Notes

All notable changes to this package will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## Unreleased

## [v0.2.1](https://github.com/nhz2/SandboxMCPRepl.jl/tree/v0.2.1) - 2026-02-24

- Improved experience when Revise is not available.

## [v0.2.0](https://github.com/nhz2/SandboxMCPRepl.jl/tree/v0.2.0) - 2026-02-22

- Fixed bug where custom display function were not called with `invokelatest`
- Added option to disable the sandbox with `--sandbox=no`
- Added a readme example of using `bwrap`
- Removed support for installing as a Julia "app". Instead use `julia --module=SandboxMCPRepl`.

## [v0.1.0](https://github.com/nhz2/SandboxMCPRepl.jl/tree/v0.1.0) - 2026-02-19

- Initial release
