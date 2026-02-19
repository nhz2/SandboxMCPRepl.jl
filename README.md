# SandboxMCPRepl.jl

This MCP server is for Julia developers who want their AI coding assistant to have a live Julia environment to work in — not just read and write code, but actually run it.

The simplest alternative is giving your AI assistant a shell tool to call `julia -e "..."`, but each call starts a fresh Julia process — you pay full startup and compilation cost every time, and nothing persists between calls. This server keeps a Julia session alive across calls, so variables, definitions, and loaded packages carry over naturally as a conversation progresses.

The tool prompts and MCP interface design are based on [julia-mcp](https://github.com/aplavin/julia-mcp) by Alexander Plavin.

Requires Linux and Julia ≥1.12.

> **This is not a locked-down sandbox.** The Julia process runs in a Sandbox.jl sandbox primarily to make it harder to break your `~/.julia`, but it otherwise has full network access and runs as your user. It is intended for use on your own machine where you trust the code being executed, not for shared or multi-user environments.

## Tools

- **julia_eval(code, env_path?, timeout?)** — execute Julia code in a persistent session. `env_path` sets the Julia project directory (omit for a temporary session). `timeout` defaults to 600s. If no `env_path` is specified the session is not persisted. The sandbox depot is temporary, so package downloads/precompile cache do not persist.
- **julia_restart(env_path)** — stop the session for that `env_path`. A fresh session is created on the next `julia_eval` call.
- **julia_list_sessions** — list active sessions and their status

## Installation

Install the app using Julia's package manager to get the `sandbox-mcp-repl` executable.
It will be installed to `~/.julia/bin/sandbox-mcp-repl`.

From the command line:
```bash
julia -e 'using Pkg; Pkg.Apps.add(url="https://github.com/nhz2/SandboxMCPRepl.jl", rev="v0.1.0")'
```

Or from the Julia REPL:
```julia
pkg> app add https://github.com/nhz2/SandboxMCPRepl.jl#v0.1.0
```

## Configuration

You will want to set up the MCP server for each workspace to take advantage of the sandboxing.

### Claude Code

Add to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "sandbox-julia": {
      "type": "stdio",
      "command": "~/.julia/bin/sandbox-mcp-repl",
      "args": [
        "--",
        "--workspace=.",
        "--log-dir=test-logs",
        "--read-write=.",
        "--",
        "julia",
        "--threads=4"
      ],
      "env": {
        "SANDBOX_SKIP_OVERLAYFS_CHECK": "true"
      }
    }
  }
}
```

Breaking down the options:

| Option | Description |
|---|---|
| `sandbox-julia` | The name you give this MCP server. |
| `~/.julia/bin/sandbox-mcp-repl` | Path to the installed executable. |
| `--` | Consumed by the Julia app launcher — separates launcher flags from SandboxMCPRepl server arguments. |
| `--workspace=.` | Resolves relative paths (like `env_path` and `--read-write`) against the current directory. |
| `--log-dir=test-logs` | Directory where session input/output logs are saved. |
| `--read-write=.` | Mounts the current directory read-write inside the sandbox. |
| `--` | Consumed by SandboxMCPRepl — everything after this is the worker Julia command. |
| `julia --threads=4` | The Julia binary and flags used for sandboxed sessions. |
| `"env": {"SANDBOX_SKIP_OVERLAYFS_CHECK": "true"}` | Skips the overlay-filesystem kernel module check in Sandbox.jl. Required on systems where the `overlay` module is not loaded; safe to remove if it is. |

### VS Code (GitHub Copilot)

Add to your project's `.vscode/mcp.json`:

```json
{
    "servers": {
        "sandbox-julia": {
            "type": "stdio",
            "command": "${userHome}/.julia/bin/sandbox-mcp-repl",
            "args": [
                "--",
                "--workspace=${workspaceFolder}",
                "--log-dir=test-logs",
                "--read-write=.",
                "--",
                "julia",
                "--threads=4"
            ],
            "env": {
                "SANDBOX_SKIP_OVERLAYFS_CHECK": "true"
            }
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
