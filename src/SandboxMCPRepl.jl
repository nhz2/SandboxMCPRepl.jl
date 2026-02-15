module SandboxMCPRepl
using Sandbox: Sandbox, SandboxConfig
using Random: RandomDevice

export start_server
export julia_eval

const MAX_CODE_SIZE = 2^23
const MAX_READ_PACKET_SIZE = 2^23

struct ReaderThread
    channel::Channel{Vector{UInt8}}
    function ReaderThread(stream)
        channel = Channel{Vector{UInt8}}(; spawn=true) do ch
            while !eof(stream)
                n_avail = min(MAX_READ_PACKET_SIZE, bytesavailable(stream))
                out = zeros(UInt8, n_avail)
                n = readbytes!(stream, out)
                resize!(out, n)
                put!(ch, out)
            end
        end
        new(channel)
    end
end

struct WriterThread
    channel::Channel{Vector{UInt8}}
    writing_flag::Threads.Atomic{Bool}
    function WriterThread(stream)
        writing_flag = Threads.Atomic{Bool}(false)
        channel = Channel{Vector{UInt8}}(; spawn=true) do ch
            while true
                code = take!(ch)
                message = zeros(UInt8, 8 + length(code))
                message[1:8] .= reinterpret(UInt8, [htol(Int64(length(code)))])
                message[9:end] .= code
                writing_flag[] = true
                write(stream, message)
                flush(stream)
                writing_flag[] = false
            end
        end
        new(channel, writing_flag)
    end
end

function repl_worker_script(; sentinel::Vector{UInt8})::String
    """
    using InteractiveUtils
    while true
        ## READ ##
        local n_to_read = ltoh(read(stdin, Int64))
        if n_to_read > $(MAX_CODE_SIZE)
            error("repl was sent over $(MAX_CODE_SIZE) bytes to read")
        end
        local code = read(stdin, n_to_read)
        if length(code) != n_to_read
            error("repl had a short read. Expected \$(n_to_read) got \$(length(code))")
        end
        ## EVAL and PRINT##
        try
            @isdefined(Revise) && Revise.revise(;throw=true)
            show(stdout,  MIME"text/plain"(), eval(Meta.parse(String(code); raise=false)))
        catch e
            try
                print(stdout, "\\nERROR: ")
                showerror(stdout, e)
                println(stdout, "\\nStacktrace:")
                for frame in stacktrace(catch_backtrace())
                    show(stdout, MIME"text/plain"(), frame)
                    println(stdout)
                end
            catch
                println(stdout, "\\nERROR PRINTING ERROR")
            end
        end
        write(stdout, $(sentinel))
        flush(stdout)
        flush(stderr)
        ## LOOP ##
    end
    """
end

mutable struct JuliaSession
    project_path::String
    worker_env::Dict{String, String}
    read_only_paths::Vector{String}
    read_write_paths::Vector{String}
    sentinel::Vector{UInt8}
    working::Bool
    fresh::Bool
    worker_in::Pipe
    in_writer::Union{WriterThread, Nothing}
    worker_out::Pipe
    out_reader::Union{ReaderThread, Nothing}
    worker_err::Pipe
    err_reader::Union{ReaderThread, Nothing}
    worker # output of `run` or `nothing`
    exe # output of `Sandbox.preferred_executor()()` or `nothing`
end

function JuliaSession(;
        project_path::Union{String, Nothing}=nothing,
        worker_env::Dict{String, String}=Dict{String, String}(),
        read_only_paths::Vector{String}=String[],
        read_write_paths::Vector{String}=String[],
        display_lines = 150
    )
    sentinel = [codeunits("\n__JULIA-MCP-SENTINEL__"); rand(RandomDevice(), UInt8('A'):UInt8('Z'), 32); UInt8('\n');]
    temp_depot = String(view(rand(RandomDevice(), UInt8('A'):UInt8('Z'), 16), :))
    worker_env = merge(worker_env,
        Dict(
            "PATH" => "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin",
            "HOME" => ENV["HOME"],
            "LANG" => ENV["C.UTF-8"],
            "LINES" => "$(display_lines)",
            "COLUMNS" => "300",
            "JULIA_DEPOT_PATH" => join(["/tmp/"*temp_depot; DEPOT_PATH;], ":"),
            "JULIA_NUM_THREADS" => "1",
        )
    )
    read_only_paths = [read_only_paths; dirname(Sys.BINDIR); DEPOT_PATH;]
    JuliaSession(
        project_path,
        worker_env,
        read_only_paths,
        copy(read_write_paths),
        sentinel,
        false,
        true,
        Pipe(),
        nothing,
        Pipe(),
        nothing,
        Pipe(),
        nothing,
        nothing,
        nothing,
    )
end

# This will leak on errors, instead of crashing the server.
function clean_up_session!(x::JuliaSession)
    try
        close(x.worker_in)
    catch
    end
    x.worker_in = Pipe()
    try
        !isnothing(x.in_writer) && close(x.in_writer.channel)
    catch
    end
    x.in_writer = nothing
    try
        close(x.worker_out)
    catch
    end
    x.worker_out = Pipe()
    try
        !isnothing(x.out_reader) && close(x.out_reader.channel)
    catch
    end
    x.out_reader = nothing
    try
        close(x.worker_err)
    catch
    end
    x.worker_err = Pipe()
    try
        !isnothing(x.err_reader) && close(x.err_reader.channel)
    catch
    end
    x.err_reader = nothing
    try
        !isnothing(x.worker) && kill(x.worker)
    catch
    end
    x.worker = nothing
    try
        !isnothing(x.exe) && Sandbox.cleanup(x.exe)
    catch
    end
    x.exe = nothing
    x.working = false
    x.fresh = false
end

function reset_session!(x::JuliaSession)::Nothing
    x.fresh = false
    if x.working
        clean_up_session!(x)
    end
    pwd = if isnothing(x.project_path)
        "/tmp/"*String(view(rand(RandomDevice(), UInt8('A'):UInt8('Z'), 16), :))
    else
        abspath(x.project_path)
    end
    try
        config = SandboxConfig(
            merge(
                Dict{String, String}(map(abspath(i)=>abspath(i), x.read_only_paths)),
                Dict{String, String}(
                    "/" => Sandbox.debian_rootfs(),
                ),
            ),
            Dict{String, String}(map(abspath(i)=>abspath(i), x.read_write_paths)),
            x.worker_env;
            stdin = x.worker_in,
            stdout = x.worker_out,
            stderr = x.worker_err,
            pwd,
        )
        x.exe = Sandbox.preferred_executor()()
        julia_path = joinpath(Sys.BINDIR, "julia")
        script = repl_worker_script(;sentinel)
        cmd = pipeline(
            Sandbox.build_executor_command(exe, config, Cmd([julia_path, "--project=$(pwd)", "-e", script]));
            stdin = x.worker_in,
            stdout = x.worker_out,
            stderr = x.worker_err,
        )
        x.worker = run(cmd; wait=false)
        x.out_reader = ReaderThread(x.worker_out)
        x.err_reader = ReaderThread(x.worker_err)
        x.in_writer = WriterThread(x.worker_in)
        x.working = true
    catch
        clean_up_session!(x)
        rethrow()
    end
    nothing
end

# Possible truncated output
mutable struct LimitedOutput
    start::Vector{UInt8}
    n_missing::Int64
    last::Vector{UInt8}
    out_limit::Int64
    LimitedOutput(start=UInt8[], n_missing=0, last=UInt8[]; out_limit=2^18) = new(start, n_missing, last, out_limit)
end

function append_out!(x::LimitedOutput, data::Vector{UInt8})::LimitedOutput
    out_limit = x.out_limit
    n_add_start = max(out_limit-length(x.start), length(data))
    append!(x.start, @view(data[1:n_add_start]))
    d = @view(data[n_add_start+1: end])
    n_extra = out_limit - length(x.last)
    n_discard =  max(length(d) - n_extra, 0)
    x.n_missing += n_discard
    append!(x.last, d)
    for i in 1:n_discard
        popfirst!(x.last)
    end
    x
end

function nice_string(x::LimitedOutput)::String
    io = IOBuffer()
    write(io, x.start)
    if x.n_missing > 0
        write(io, "\n... $(x.n_missing) BYTES TRUNCATED ...\n")
    end
    write(io, x.last)
    if x.n_missing > 0
        write(io, "\n $(x.n_missing) BYTES WERE TRUNCATED FROM THE CENTER\n")
    end
    str = String(take!(io))
    replace(str, !isvalid=>'\ufffd')
end

struct EvalResults
    out::LimitedOutput
    err::LimitedOutput
    timed_out::Bool
    worker_died::Bool
end

function eval_session!(x::JuliaSession, code::String, deadline::UInt64, out_limit::Int64)::EvalResults
    @assert x.working
    @assert out_limit ≥ 256
    @assert !x.in_writer.writing_flag[]
    time_left() = (deadline - time_ns())%Int64
    out = LimitedOutput(;out_limit)
    err = LimitedOutput(;out_limit)
    # main ways to check status
    # time_left()
    # process_exited(x.worker)
    # isopen/isready(x.out_reader.channel)
    # isopen/isready(x.err_reader.channel)
    # isopen x.in_writer.channel
    put!(x.in_writer.channel, collect(codeunits(code)))
    timed_out = false
    while true
        if time_left() ≤ 0
            timed_out = true
            kill(x.worker)
        end
    end



    if process_exited(x.worker)
        # early exit
        if isready()
    while true
        if isready(x.out_reader.channel)
            append!(take!(x.out_reader.channel)


end



function julia_eval(server::Server; code::String)::
    p = run(cmd; wait=false)
    proc_wait = @async wait(p)
    code_message = zeros(UInt8, 8+ncodeunits(code))
    code_message[1:8] .= reinterpret(UInt8, [htol(Int64(ncodeunits(code)))])
    code_message[9:end] .= codeunits(code)
    writer = @async begin
        write(worker_in, code_message)
        flush(worker_in)
    end
    reader = @async readuntil(worker_out, sentinel)
    done_tasks, remaining_tasks = waitany([proc_wait, reader]; throw=false)
    out_string = if reader ∈ done_tasks
        String(fetch(reader))
    else
        "Julia died :("
    end
    kill(p)
    close(worker_in)
    close(worker_out)
    cleanup(exe)
    out_string
end


# function @main()
#     while true
#         get_request | get_exit
#         if get_exit
#             die
#         else
#             do request
#         end
#     end
# end

end # module SandboxMCPRepl
