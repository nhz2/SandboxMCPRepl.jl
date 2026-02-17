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

const MAX_CODE_SIZE = 2^23
const MAX_READ_PACKET_SIZE = 2^23
const DEFAULT_OUT_LIMIT = 200000

include("session.jl")

const server_lock = ReentrantLock()
const sessions = Dict{String, JuliaSession}()
const session_logs = Dict{String, String}()
const read_only_paths = String[]
const read_write_paths = String[]
const worker_env = Dict{String, String}()
const log_dir = Ref("")

function julia_eval_handler(params)::Union{String, MCP.CallToolResult}
    lock(server_lock) do
        deadline = time_ns() + round(UInt64, params["timeout"]*1E9)
        env_path = params["env_path"]
        abs_env_path = abspath(env_path)
        is_temp = isempty(env_path)
        session = if is_temp
            JuliaSession(; use_revise=false, read_only_paths, read_write_paths, worker_env)
        else
            get!(sessions, abs_env_path) do
                JuliaSession(; use_revise=true, project_path=abs_env_path,
                    read_only_paths, read_write_paths, worker_env)
            end
        end
        try
            if !session.working
                reset_session!(session)
                if !isempty(log_dir[]) && !is_temp
                    mkpath(log_dir[])
                    new_log_path = gen_log_path(log_dir[], abs_env_path)
                    write(new_log_path, "# Session started env=$(repr(abs_env_path))\n")
                    session_logs[abs_env_path] = new_log_path
                end
            end
            code::String = params["code"]
            eval_results = eval_session!(session, code, deadline, DEFAULT_OUT_LIMIT)
            r = nice_string(eval_results)
            if !isempty(log_dir[]) && !is_temp
                out_log = log_string(eval_results)
                open(session_logs[abs_env_path]; append=true) do io
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
Usage: julia --project=<SandboxMCPRepl dir> -m SandboxMCPRepl [options]

Options:
    --read-only=PATH1:PATH2:...   Colon-separated paths mounted read-only in the sandbox.
    --read-write=PATH1:PATH2:...  Colon-separated paths mounted read-write in the sandbox.
    --env=KEY=VALUE               Environment variable passed to worker sessions. Can be repeated.
    --log-dir=PATH                Directory where logs of session inputs and outputs are saved.
    --workspace=PATH              Input relative paths are relative to this directory.
    --help, -h                    Show this message and exit.
"""

function @main(args::Vector{String})
    ro = String[]
    rw = String[]
    env = Dict{String, String}()
    logdir::String = ""
    for arg in args
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
                println(stderr, "Invalid --env format (expected KEY=VALUE): $(repr(arg))")
                println(stderr, "Run with --help for usage.")
                exit(1)
            end
            env[String(parts[2])] = String(parts[3])
        elseif startswith(arg, "--log-dir=")
            logdir = split(arg, '='; limit=2)[2]
        elseif startswith(arg, "--workspace=")
            cd(split(arg, '='; limit=2)[2])
        elseif arg == "--help" || arg == "-h"
            println(stderr, help_string)
            exit(1)
        else
            println(stderr, "Unknown argument: $(repr(arg))")
            println(stderr, "Run with --help for usage.")
            exit(1)
        end
    end
    empty!(read_only_paths)
    append!(read_only_paths, abspath.(ro))
    empty!(read_write_paths)
    append!(read_write_paths, abspath.(rw))
    empty!(worker_env)
    merge!(worker_env, env)
    log_dir[] = isempty(logdir) ? "" : abspath(logdir)
    server = MCP.mcp_server(
        name = "SandboxMCPRepl",
        version = "1.0.0",
        tools = [
            MCP.MCPTool(
                name = "julia_eval",
                description = """
                ALWAYS use this tool to run Julia code. NEVER run julia via command line.

                Persistent REPL session with state preserved between calls.
                Each env_path gets its own session, started lazily.
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
                        description = "Julia project directory path. Omit for a temporary environment.",
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
                Restart a Julia session, clearing all state and resetting the julia depot.

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
                handler = (params) -> lock(server_lock) do
                    clean_up_session!(get!(sessions, abspath(params["env_path"])) do
                        JuliaSession(; use_revise=true, project_path=abspath(params["env_path"]),
                            read_only_paths, read_write_paths, worker_env)
                    end)
                    "Session restarted. A fresh session will start on next julia_eval call."
                end
            ),
            MCP.MCPTool(
                name = "julia_list_sessions",
                description = """
                List all active Julia sessions and their environments.
                """,
                return_type = MCP.TextContent,
                handler = (params) -> lock(server_lock) do
                    if isempty(sessions)
                        "No active Julia sessions."
                    else
                        local lines = [
                            "  $(repr(k)): $(ifelse(v.working, "alive", "dead"))"
                            for (k, v) in sessions
                        ]
                        "Active Julia sessions:\n" * join(lines, "\n")
                    end
                end
            ),
        ]
    )
    MCP.start!(server)
    return
end

precompile(main, (Vector{String},))

end # module SandboxMCPRepl
