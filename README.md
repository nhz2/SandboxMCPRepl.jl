# SandboxMCPRepl.jl Work in progress

This MCP server is for Julia developers who want their AI coding assistant to have a live Julia environment to work in — not just read and write code, but actually run it.

The simplest alternative is giving your AI assistant a shell tool to call `julia -e "..."`, but each call starts a fresh Julia process — you pay full startup and compilation cost every time, and nothing persists between calls. This server keeps a Julia session alive across calls, so variables, definitions, and loaded packages carry over naturally as a conversation progresses.

The tool prompts and MCP interface design are based on [julia-mcp](https://github.com/aplavin/julia-mcp) MIT License Copyright (c) 2026 Alexander Plavin.

Requires Linux and Julia ≥1.12.

> **This is not a locked-down sandbox.** The Julia process runs in a Sandbox.jl sandbox primarily to make it harder to break your `~/.julia`, but it otherwise has full network access and runs as your user. It is intended for use on your own machine where you trust the code being executed, not for shared or multi-user environments.

## Tools

- **julia_eval(code, env_path?, timeout?)** — execute Julia code in a persistent session. `env_path` sets the Julia project directory (omit for a temporary session). `timeout` defaults to 600s. If no `env_path` is specified the session is not persisted.
- **julia_restart(env_path)** — stop the session for that `env_path`. A fresh session is created on the next `julia_eval` call.
- **julia_list_sessions** — list active sessions and their status

## Installation

Install the app using Julia's package manager to get the `sandbox-mcp-repl` executable.
It will be installed to `~/.julia/bin/sandbox-mcp-repl`.

From the command line:
```bash
julia -e 'using Pkg; Pkg.Apps.add(url="https://github.com/nhz2/SandboxMCPRepl.jl")'
```

Or from the Julia REPL:
```julia
pkg> app add https://github.com/nhz2/SandboxMCPRepl.jl
```

## Configuration

You will want to set up the MCP server for each workspace to take advantage of the sandboxing.

### Claude Code

Add the MCP server using the `claude` CLI.

There are two `--` separators in this example:
- the first one is consumed by the app launcher and starts app arguments
- the second one is consumed by `SandboxMCPRepl` and starts the worker Julia command

Without the first separator, `--workspace`, `--log-dir`, etc. are interpreted as Julia launcher arguments instead of server arguments.

```bash
claude mcp add --scope project sandbox-julia -- ~/.julia/bin/sandbox-mcp-repl -- --workspace=. --log-dir=test-logs --read-write=. -- julia +1.12 --threads=auto
```

### VS Code (GitHub Copilot)

Add to your project's `.vscode/mcp.json`:

```json
{
    "servers": {
        "julia": {
            "type": "stdio",
            "command": "${userHome}/.julia/bin/sandbox-mcp-repl",
            "args": [
                "--",
                "--workspace=${workspaceFolder}",
                "--log-dir=test-logs",
                "--read-write=.",
                "--",
                "julia",
                "+1.12",
                "--threads=auto"
            ]
        }
    }
}
```

### Server CLI arguments

```text
--read-only=PATH1:PATH2:...   Colon-separated paths mounted read-only in the sandbox.
--read-write=PATH1:PATH2:...  Colon-separated paths mounted read-write in the sandbox.
--env=KEY=VALUE               Environment variable passed to worker sessions. Can be repeated.
--log-dir=PATH                Directory where logs of named-session inputs and outputs are saved. If empty or unset, no logs are saved. Temp sessions are never logged.
--out-limit=BYTES             About half the max bytes of output before truncation (default: 20,000).
--workspace=PATH              Input relative paths are relative to this directory.
--version, -v                 Show version and exit.
--help, -h                    Show this message and exit.
```

#### Worker Julia command

```text
Everything after `--` is a worker Julia launch command used for sandboxed sessions.
Examples:
    -- julia +1.9               Use juliaup channel 1.9
    -- julia +1.9 --threads=4   Use juliaup channel 1.9 with 4 threads
    -- /opt/julia/bin/julia     Use a specific Julia binary
```

## Alternatives

Other projects that give AI agents access to Julia:

- [julia-mcp](https://github.com/aplavin/julia-mcp) — `SandboxMCPRepl.jl` is a fork of this with sandboxing and implemented in Julia.
- [MCPRepl.jl](https://github.com/hexaeder/MCPRepl.jl) and [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) — require you to manually start and manage Julia sessions.
- [DaemonConductor.jl](https://github.com/tecosaur/DaemonConductor.jl) (Linux only) — runs Julia scripts, but calls are independent and don't share variables.
- Jupyter MCP servers — offer the same persistence via an IJulia kernel, but the notebook cell model adds overhead for the agent — each interaction requires separate calls to query, edit, run, and read cells.
