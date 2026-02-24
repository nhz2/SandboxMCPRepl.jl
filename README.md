# SandboxMCPRepl.jl

This MCP server is for Julia developers who want their AI coding assistant to have a live Julia environment to work in — not just read and write code, but actually run it.

The simplest alternative is giving your AI assistant a shell tool to call `julia -e "..."`, but each call starts a fresh Julia process — you pay full startup and compilation cost every time, and nothing persists between calls. This server keeps a Julia session alive across calls, so variables, definitions, and loaded packages carry over naturally as a conversation progresses.

The tool prompts and MCP interface design are based on [julia-mcp](https://github.com/aplavin/julia-mcp) by Alexander Plavin.

Requires Julia ≥1.12. The built-in sandbox requires Linux with a working Sandbox.jl.

> **The built-in sandbox does not fully isolate the Julia process.** By default the Julia process runs in a [Sandbox.jl](https://github.com/JuliaContainerization/Sandbox.jl) sandbox. This makes it harder to accidentally break your `~/.julia` directory, but doesn't block network access.

## Tools

- **julia_eval(code, env_path?, timeout?)** — execute Julia code in a persistent session. `env_path` sets the Julia project directory (omit for a temporary session). `timeout` defaults to 600s. If no `env_path` is specified the session is not persisted. The sandbox depot is temporary, so package downloads/precompile cache do not persist.
- **julia_restart(env_path)** — stop the session for that `env_path`. A fresh session is created on the next `julia_eval` call.
- **julia_list_sessions** — list active sessions and their status

## Installation

Install a release of this package into `~/packages/SandboxMCPRepl.jl`:

```sh
mkdir -p ~/packages/SandboxMCPRepl.jl
curl --location --output ~/packages/SandboxMCPRepl.jl/SandboxMCPRepl.jl-0.2.0.tar.gz https://github.com/nhz2/SandboxMCPRepl.jl/archive/refs/tags/v0.2.0.tar.gz
tar xzf ~/packages/SandboxMCPRepl.jl/SandboxMCPRepl.jl-0.2.0.tar.gz -C ~/packages/SandboxMCPRepl.jl
julia --project=~/packages/SandboxMCPRepl.jl/SandboxMCPRepl.jl-0.2.0 -e "using Pkg; Pkg.instantiate()"
```

## Configuration

You will want to set up the MCP server for each workspace to take advantage of the sandboxing.

In VS Code this requires a `.vscode/mcp.json` file.
In Cursor it is a `.cursor/mcp.json` with the same format as VS Code.

Claude Code uses a different format, but it can convert from VS Code if you ask it nicely.

### VS Code

#### Using a [bubblewrap](https://github.com/containers/bubblewrap) sandbox to block network access

This assumes you have julia symlinks available in `~/.local/bin` and packages in `~/packages/julias` as is the default for https://github.com/abelsiqueira/jill

Julia installed with juliaup currently will not work with `bwrap` see: https://github.com/JuliaLang/juliaup/issues/1204

In this example an `agent-depot` directory is created in the workspace. This allows the Julia depot at `~/.julia` to be read only.

Add to your project's `.vscode/mcp.json`:

```json
{
    "servers": {
        "sandbox-julia": {
            "type": "stdio",
            "command": "bwrap",
            "args": [
                "--ro-bind", "/usr", "/usr",
                "--ro-bind", "/etc", "/etc",
                "--dir", "/tmp",
                "--dir", "/var",
                "--symlink", "../tmp", "var/tmp",
                "--proc", "/proc",
                "--dev", "/dev",
                "--symlink", "usr/lib", "/lib",
                "--symlink", "usr/lib64", "/lib64",
                "--symlink", "usr/bin", "/bin",
                "--symlink", "usr/sbin", "/sbin",
                "--ro-bind", "${userHome}/.julia", "${userHome}/.julia",
                "--ro-bind-try", "${userHome}/bin", "${userHome}/bin",
                "--ro-bind-try", "${userHome}/.local/bin", "${userHome}/.local/bin",
                "--ro-bind-try", "${userHome}/packages", "${userHome}/packages",
                "--bind", "${workspaceFolder}", "${workspaceFolder}",
                "--chdir", "${workspaceFolder}",
                "--unshare-all",
                "--die-with-parent",
                "--new-session",
                "--setenv", "JULIA_DEPOT_PATH", "${workspaceFolder}/agent-depot:${userHome}/.julia:",
                "--setenv", "JULIA_PKG_OFFLINE", "true",
                "julia",
                "--project=${userHome}/packages/SandboxMCPRepl.jl/SandboxMCPRepl.jl-0.2.0",
                "--startup-file=no",
                "--module=SandboxMCPRepl",
                "--workspace=${workspaceFolder}",
                "--log-dir=agent-logs",
                "--sandbox=no",
                "--",
                "julia",
                "--startup-file=no",
                "--threads=4"
            ],
        }
    }
}
```

#### Using the built-in sandbox

Add to your project's `.vscode/mcp.json`:

```json
{
    "servers": {
        "sandbox-julia": {
            "type": "stdio",
            "command": "julia",
            "args": [
                "--project=${userHome}/packages/SandboxMCPRepl.jl/SandboxMCPRepl.jl-0.2.0",
                "--startup-file=no",
                "--module=SandboxMCPRepl",
                "--workspace=${workspaceFolder}",
                "--log-dir=agent-logs",
                "--read-write=.",
                "--",
                "julia",
                "--threads=4"
            ],
        }
    }
}
```

### Server CLI arguments

```text
--sandbox={yes*|no}           Flag to enable the Sandbox.jl sandbox and temp Julia depot. Defaults to yes.
                              --sandbox=no is incompatible with --read-only and --read-write.
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
