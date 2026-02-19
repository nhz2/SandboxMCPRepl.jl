module SandboxMCPRepl
using Sandbox: Sandbox, SandboxConfig
using Random: RandomDevice
using ModelContextProtocol: ModelContextProtocol
using Dates: Dates
const MCP = ModelContextProtocol

export JuliaSession
export reset_session!
export eval_session!
export clean_up_session!
export EvalResults

struct HelpRequested <: Exception end
struct VersionRequested <: Exception end

const MAX_CODE_SIZE = 2^23
const MAX_READ_PACKET_SIZE = 2^23
const DEFAULT_OUT_LIMIT = 20000
const THIS_PACKAGE_VERSION::String = string(pkgversion(@__MODULE__))

include("session.jl")

# Copy the rootfs artifact to a path outside the depot to prevent overlay
# leaks in nested sandboxes. Copying to /tmp breaks that cycle.
const SAFE_ROOTFS = OncePerProcess{String}() do
    cp(Sandbox.debian_rootfs(), joinpath(mktempdir(), "rootfs"))
end

const SERVER_LOCK = ReentrantLock()
const SESSIONS = Dict{String, JuliaSession}()
const SESSION_LOGS = Dict{String, String}()
const READ_ONLY_PATHS = String[]
const READ_WRITE_PATHS = String[]
const WORKER_ENV = Dict{String, String}()
const LOG_DIR = Ref("")
const JULIA_CMD = String[]
const WORKER_DEPOT_PATH = String[]
const OUT_LIMIT = Ref(0)

function julia_eval_handler(params)::Union{String, MCP.CallToolResult}
    lock(SERVER_LOCK) do
        deadline = time_ns() + round(UInt64, params["timeout"]*1E9)
        env_path = params["env_path"]
        abs_env_path = abspath(env_path)
        is_temp = isempty(env_path)
        session = if is_temp
            JuliaSession(; use_revise=false, read_only_paths=READ_ONLY_PATHS, read_write_paths=READ_WRITE_PATHS, worker_env=WORKER_ENV, julia_cmd=JULIA_CMD, depot_path=WORKER_DEPOT_PATH)
        else
            get!(SESSIONS, abs_env_path) do
                JuliaSession(; use_revise=true, project_path=abs_env_path,
                    read_only_paths=READ_ONLY_PATHS, read_write_paths=READ_WRITE_PATHS, worker_env=WORKER_ENV, julia_cmd=JULIA_CMD, depot_path=WORKER_DEPOT_PATH)
            end
        end
        try
            if !session.working
                reset_session!(session)
                if !isempty(LOG_DIR[]) && !is_temp
                    mkpath(LOG_DIR[])
                    new_log_path = gen_log_path(LOG_DIR[], abs_env_path)
                    write(new_log_path, "# Session started env=$(repr(abs_env_path))\n")
                    SESSION_LOGS[abs_env_path] = new_log_path
                end
            end
            code::String = params["code"]
            eval_results = eval_session!(session, code, deadline, OUT_LIMIT[])
            r = nice_string(eval_results)
            if !isempty(LOG_DIR[]) && !is_temp
                out_log = log_string(eval_results)
                open(SESSION_LOGS[abs_env_path]; append=true) do io
                    println(io, "[CODE]")
                    println(io, code)
                    println(io, out_log)
                end
            end
            r
        catch e
            clean_up_session!(session)
            MCP.CallToolResult(
                content = [MCP.TextContent(text = repr(e))],
                is_error = true
            )
        finally
            if is_temp
                clean_up_session!(session)
            end
        end
    end
end

const help_string = """
SandboxMCPRepl.jl - A MCP server for Julia developers who want their AI coding assistant to have a live Julia environment to work in.

VERSION: $(THIS_PACKAGE_VERSION)

Usage: sandbox-mcp-repl [julia_launcher_args...] -- [options] [-- worker_julia_cmd...]

Options:
    --read-only=PATH1:PATH2:...   Colon-separated paths mounted read-only in the sandbox.
    --read-write=PATH1:PATH2:...  Colon-separated paths mounted read-write in the sandbox.
    --env=KEY=VALUE               Environment variable passed to worker sessions. Can be repeated.
    --log-dir=PATH                Directory where logs of named-session inputs and outputs are saved.
                                  If empty or unset, no logs are saved. Temp sessions are never logged.
    --out-limit=BYTES             About half the max bytes of output before truncation (default: $DEFAULT_OUT_LIMIT).
    --workspace=PATH              Input relative paths are relative to this directory.
    --version, -v                 Show version and exit.
    --help, -h                    Show this message and exit.

Worker Julia command:
    Everything after `--` is a Julia launch command used for sandboxed sessions.
    Examples:
        -- julia +1.9               Use juliaup channel 1.9
        -- julia +1.9 --threads=4   Use juliaup channel 1.9 with 4 threads
        -- /opt/julia/bin/julia     Use a specific Julia binary
"""

"""
    parse_args(args::Vector{String})

Parse CLI arguments and return a named tuple of the parsed configuration.
Throws `ArgumentError` for invalid arguments.
Throws `HelpRequested()` for `--help` and `-h`.
Throws `VersionRequested()` for `--version` and `-v`.
"""
function parse_args(args::Vector{String})
    ro = String[]
    rw = String[]
    env = Dict{String, String}()
    logdir::String = ""
    outlimit::Int = DEFAULT_OUT_LIMIT
    workspace::String = ""
    # Split args at "--" separator
    dashdash_idx = findfirst(==("--"), args)
    if isnothing(dashdash_idx)
        main_args = args
        julia_launch_cmd = String[]
    else
        main_args = args[1:dashdash_idx-1]
        julia_launch_cmd = args[dashdash_idx+1:end]
    end
    for arg in main_args
        local val
        if startswith(arg, "--read-only=")
            val = split(arg, '='; limit=2)[2]
            append!(ro, filter(!isempty, split(val, ':')))
        elseif startswith(arg, "--read-write=")
            val = split(arg, '='; limit=2)[2]
            append!(rw, filter(!isempty, split(val, ':')))
        elseif startswith(arg, "--env=")
            parts = split(arg, '='; limit=3)
            if length(parts) != 3 || isempty(parts[2])
                throw(ArgumentError("Invalid --env format (expected KEY=VALUE): $(repr(arg))"))
            end
            env[String(parts[2])] = String(parts[3])
        elseif startswith(arg, "--log-dir=")
            logdir = split(arg, '='; limit=2)[2]
        elseif startswith(arg, "--out-limit=")
            outlimit = parse(Int, split(arg, '='; limit=2)[2])
            if outlimit < 256
                throw(ArgumentError("Invalid --out-limit value (must be ≥ 256): $(repr(arg))"))
            end
        elseif startswith(arg, "--workspace=")
            workspace = split(arg, '='; limit=2)[2]
        elseif arg == "--version" || arg == "-v"
            throw(VersionRequested())
        elseif arg == "--help" || arg == "-h"
            throw(HelpRequested())
        else
            throw(ArgumentError("Unknown argument: $(repr(arg))"))
        end
    end
    return (; read_only=ro, read_write=rw, env, log_dir=logdir, out_limit=outlimit, workspace, julia_launch_cmd)
end

"""
    apply_config!(config)

Apply parsed CLI configuration to module-level global state.
`config` is the named tuple returned by [`parse_args`](@ref).
"""
function apply_config!(config)
    if !isempty(config.workspace)
        cd(config.workspace)
    end
    empty!(READ_ONLY_PATHS)
    append!(READ_ONLY_PATHS, abspath.(config.read_only))
    empty!(READ_WRITE_PATHS)
    append!(READ_WRITE_PATHS, abspath.(config.read_write))
    empty!(WORKER_ENV)
    merge!(WORKER_ENV, config.env)
    LOG_DIR[] = isempty(config.log_dir) ? "" : abspath(config.log_dir)
    OUT_LIMIT[] = config.out_limit
    # Resolve Julia command for sandboxed sessions
    empty!(JULIA_CMD)
    empty!(WORKER_DEPOT_PATH)
    if !isempty(config.julia_launch_cmd)
        probe_result = probe_julia(config.julia_launch_cmd)
        append!(JULIA_CMD, probe_result.julia_cmd)
        append!(WORKER_DEPOT_PATH, probe_result.depot_path)
    else
        push!(JULIA_CMD, joinpath(Sys.BINDIR, Base.julia_exename()))
        append!(WORKER_DEPOT_PATH, DEPOT_PATH)
    end
    return nothing
end

# --- Callback handlers ---

function julia_restart_handler(params)
    lock(SERVER_LOCK) do
        clean_up_session!(get!(SESSIONS, abspath(params["env_path"])) do
            JuliaSession(; use_revise=true, project_path=abspath(params["env_path"]),
                read_only_paths=READ_ONLY_PATHS, read_write_paths=READ_WRITE_PATHS, worker_env=WORKER_ENV, julia_cmd=JULIA_CMD, depot_path=WORKER_DEPOT_PATH)
        end)
        "Session restarted. A fresh session will start on next julia_eval call."
    end
end

function julia_list_sessions_handler(params)
    lock(SERVER_LOCK) do
        if isempty(SESSIONS)
            "No active Julia sessions."
        else
            local lines = [
                "  $(repr(k)): $(ifelse(v.working, "alive", "dead"))"
                for (k, v) in SESSIONS
            ]
            "Active Julia sessions:\n" * join(lines, "\n")
        end
    end
end

# --- MCP server setup ---

"""
    create_mcp_server()

Create and return the MCP server with all tool definitions.

Based on prompts from https://github.com/aplavin/julia-mcp
"""
function create_mcp_server()
    MCP.mcp_server(
        name = "SandboxMCPRepl.jl",
        version = THIS_PACKAGE_VERSION,
        tools = [
            MCP.MCPTool(
                name = "julia_eval",
                description = """
                ALWAYS use this tool to run Julia code. NEVER run julia via command line.

                Persistent REPL session with state preserved between calls.
                Each env_path gets its own session, started lazily.
                State does NOT persist when env_path is omitted (each call gets a fresh temporary session)
                """,
                return_type = MCP.TextContent,
                parameters = [
                    MCP.ToolParameter(
                        name = "code",
                        type = "string",
                        description = "Julia code to evaluate.",
                        required = true
                    ),
                    MCP.ToolParameter(
                        name = "env_path",
                        type = "string",
                        description = "Julia project directory path. Omit for a temporary environment and session.",
                        default = "",
                    ),
                    MCP.ToolParameter(
                        name = "timeout",
                        type = "number",
                        description = "Seconds (default: 600).",
                        default = 600.0,
                    ),
                ],
                handler = julia_eval_handler
            ),
            MCP.MCPTool(
                name = "julia_restart",
                description = """
                Restart a Julia session, clearing session state.

                IMPORTANT: Restarting is slow and loses all session state. Very rarely needed.
                Revise.jl is loaded automatically in every session, so code changes to loaded packages are picked up without restarting.
                Only restart as a last resort when the session is truly broken, or code changes that Revise cannot fix.
                """,
                return_type = MCP.TextContent,
                parameters = [
                    MCP.ToolParameter(
                        name = "env_path",
                        type = "string",
                        description = "Environment to restart.",
                        required = true,
                    ),
                ],
                handler = julia_restart_handler
            ),
            MCP.MCPTool(
                name = "julia_list_sessions",
                description = """
                List all active Julia sessions and their environments.
                """,
                return_type = MCP.TextContent,
                handler = julia_list_sessions_handler
            ),
        ]
    )
end

function @main(args::Vector{String})
    try
        config = parse_args(args)
        apply_config!(config)
    catch e
        if e isa HelpRequested
            println(stderr, help_string)
        elseif e isa VersionRequested
            println(stderr, "SandboxMCPRepl version $(THIS_PACKAGE_VERSION)")
        elseif e isa ArgumentError
            println(stderr, e.msg)
            println(stderr, "Run with --help for usage.")
        else
            rethrow()
        end
        exit(1)
    end
    SAFE_ROOTFS() # reduce latency of tool calls
    server = create_mcp_server()
    MCP.start!(server)
    return
end

precompile(main, (Vector{String},))

end # module SandboxMCPRepl
