function spawn_reader(name::Symbol, event_channel::Channel{Pair{Symbol, Vector{UInt8}}}, stream)
    Threads.@spawn begin
        try
            while !eof(stream)
                n_avail = max(min(MAX_READ_PACKET_SIZE, bytesavailable(stream)), 1)
                out = zeros(UInt8, n_avail)
                n = readbytes!(stream, out)
                if iszero(n)
                    out[1] = read(stream, UInt8)
                    n = 1
                end
                resize!(out, n)
                put!(event_channel, name=>out)
            end
        finally
            put!(event_channel, name=>UInt8[]) # Signal done with a empty vector
        end
    end
end

struct WriterThread
    channel::Channel{Vector{UInt8}}
    writing_flag::Threads.Atomic{Bool}
    function WriterThread(stream)
        writing_flag = Threads.Atomic{Bool}(false)
        ch = Channel{Vector{UInt8}}()
        Threads.@spawn while true
            code = take!(ch)
            io = IOBuffer(;sizehint= 8 + length(code))
            write(io, htol(Int64(length(code))))
            write(io, code)
            message = take!(io)
            writing_flag[] = true
            write(stream, message)
            flush(stream)
            writing_flag[] = false
        end
        new(ch, writing_flag)
    end
end

const REVISE_STARTUP = """
    try
        using Revise
    catch e
        println(stderr, "Revise unavailable")
    end
    """

function repl_worker_script(; sentinel::Vector{UInt8}, startup::String)::String
    """
    $(startup)
    using InteractiveUtils
    using REPL
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
            invokelatest(show, stdout,  MIME"text/plain"(), include_string(Main, String(code)))
        catch e
            try
                print(stdout, "\\nERROR: ")
                invokelatest(showerror, stdout, e)
                local traces = stacktrace(catch_backtrace())
                local interesting = findlast(f->startswith(repr(f), "top-level scope at string"), traces)
                if !isnothing(interesting)
                    println(stdout, "\\nStacktrace:")
                    for frame in traces[1:interesting]
                        show(stdout, MIME"text/plain"(), frame)
                        println(stdout)
                    end
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
    julia_cmd::Vector{String}
    use_revise::Bool
    project_path::Union{String, Nothing}
    worker_env::Dict{String, String}
    sentinel::Vector{UInt8}
    working::Bool
    fresh::Bool
    worker_in::Pipe
    in_writer::Union{WriterThread, Nothing}
    worker_out::Pipe
    worker_err::Pipe
    event_channel::Channel{Pair{Symbol, Vector{UInt8}}}
    worker::Union{Base.Process, Nothing} # output of `run` or `nothing`
    temp_dir_to_cleanup::Union{String, Nothing}
end

function JuliaSession(;
        julia_cmd::Vector{String}=[joinpath(Sys.BINDIR, Base.julia_exename())],
        use_revise::Bool=false,
        project_path::Union{String, Nothing}=nothing,
        worker_env::Dict{String, String}=Dict{String, String}(),
        display_lines = 150
    )
    sentinel = [codeunits("\n__JULIA-MCP-SENTINEL__"); rand(RandomDevice(), UInt8('A'):UInt8('Z'), 32); UInt8('\n');]
    worker_env = let
        d = merge(
            copy(ENV),
            Dict(
                "LINES" => "$(display_lines)",
                "COLUMNS" => "300",
            ),
            worker_env,
        )
        # Remove JULIA_LOAD_PATH so the worker uses the default (@, @v#.#, @stdlib).
        # The MCP server launcher may set this to restrict loads to its own project,
        # but the worker needs access to stdlibs and its own project environment.
        delete!(d, "JULIA_LOAD_PATH")
        d
    end
    JuliaSession(
        copy(julia_cmd),
        use_revise,
        project_path,
        worker_env,
        sentinel,
        false,
        true,
        Pipe(),
        nothing,
        Pipe(),
        Pipe(),
        Channel{Pair{Symbol, Vector{UInt8}}}(6),
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
        in_writer = x.in_writer
        !isnothing(in_writer) && close(in_writer.channel)
    catch
    end
    x.in_writer = nothing
    try
        close(x.worker_out)
    catch
    end
    x.worker_out = Pipe()
    try
        close(x.worker_err)
    catch
    end
    x.worker_err = Pipe()
    try
        close(x.event_channel)
    catch
    end
    x.event_channel = Channel{Pair{Symbol, Vector{UInt8}}}(6)
    try
        worker = x.worker
        if !isnothing(worker) && !process_exited(worker)
            for i in 1:2
                kill(worker)
                sleep(0.1)
                process_exited(worker) && break
            end
            while !process_exited(worker)
                kill(worker)
                sleep(2.0)
            end
        end
    catch
    end
    x.worker = nothing
    try
        temp_dir_to_cleanup = x.temp_dir_to_cleanup
        !isnothing(temp_dir_to_cleanup) && rm(temp_dir_to_cleanup; force=true, recursive=true)
    catch
    end
    x.temp_dir_to_cleanup = nothing
    x.working = false
    x.fresh = false
    nothing
end

function reset_session!(x::JuliaSession)::JuliaSession
    x.fresh = false
    if x.working
        clean_up_session!(x)
    end
    proj_path = x.project_path
    pwd = if isnothing(proj_path)
        x.temp_dir_to_cleanup = mktempdir()
    else
        abspath(proj_path)
    end
    script = repl_worker_script(;x.sentinel, startup=ifelse(x.use_revise,REVISE_STARTUP,""))
    try
        cmd = pipeline(
            setenv(Cmd([x.julia_cmd..., "--project=$(pwd)", "-e", script]), x.worker_env; dir=pwd);
            stdin = x.worker_in,
            stdout = x.worker_out,
            stderr = x.worker_err,
        )
        x.worker = run(cmd; wait=false)
        sleep(0.1)
        spawn_reader(:err, x.event_channel, x.worker_err)
        spawn_reader(:out, x.event_channel, x.worker_out)
        x.in_writer = WriterThread(x.worker_in)
        x.working = true
    catch
        clean_up_session!(x)
        rethrow()
    end
    x
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
    n_add_start = max(min(out_limit-length(x.start), length(data)), 0)
    append!(x.start, @view(data[1:n_add_start]))
    d = @view(data[n_add_start+1: end])
    n_extra = out_limit - length(x.last)
    n_discard = max(length(d) - n_extra, 0)
    x.n_missing += n_discard
    append!(x.last, d)
    for i in 1:n_discard
        popfirst!(x.last)
    end
    x
end

function out_endswith(x::LimitedOutput, data::Vector{UInt8})::Bool
    n = length(data)
    if x.n_missing > 0
        length(x.last) ≥ n || return false
    else
        length(x.last) + length(x.start) ≥ n || return false
    end
    n_in_last = min(n, length(x.last))
    @view(x.last[end-n_in_last+1:end]) == @view(data[end-n_in_last+1:end]) || return false
    n_in_start = n - n_in_last
    @view(x.start[end-n_in_start+1:end]) == @view(data[1:n_in_start]) || return false
    true
end

# Used to remove the sentinel
function drop_end!(x::LimitedOutput, n::Int)::LimitedOutput
    @assert n ≤ length(x.start) + x.n_missing + length(x.last)
    n_in_last = min(n, length(x.last))
    n_in_missing = min(n-n_in_last, x.n_missing)
    n_in_start = n-n_in_last-n_in_missing
    for i in 1:n_in_last
        pop!(x.last)
    end
    x.n_missing -= n_in_missing
    for i in 1:n_in_start
        pop!(x.start)
    end
    x
end

function nbytes(x::LimitedOutput)::Int64
    length(x.start) + x.n_missing + length(x.last)
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
    exitcode::Int64 # only valid if worker_died is true
end

# This is how the results get presented to the AI
function nice_string(r::EvalResults)::String
    io = IOBuffer()
    if nbytes(r.out) > 0
        write(io, nice_string(r.out))
    end
    if nbytes(r.err) > 0
        println(io, "\n--- STDERR ---")
        write(io, nice_string(r.err))
    end
    if r.worker_died
        if r.timed_out
            println(io, "\nTIMED OUT: Worker was killed after exceeding the time limit.")
        else
            println(io, "\nWORKER EXITED: Process exited with code $(r.exitcode).")
        end
    end
    String(take!(io))
end

# Human-readable log format with clear section headers
function log_string(r::EvalResults)::String
    io = IOBuffer()
    if nbytes(r.out) > 0
        println(io, "[OUTPUT]")
        println(io, nice_string(r.out))
    end
    if nbytes(r.err) > 0
        println(io, "[STDERR]")
        println(io, nice_string(r.err))
    end
    if r.worker_died
        if r.timed_out
            println(io, "[STATUS] Timed out")
        else
            println(io, "[STATUS] Worker exited with code: $(r.exitcode).")
        end
    end
    String(take!(io))
end

function eval_session!(x::JuliaSession, code::String, deadline::UInt64, out_limit::Int64)::EvalResults
    @assert x.working
    @assert out_limit ≥ 256
    in_writer = x.in_writer
    @assert !isnothing(in_writer)
    worker = x.worker
    @assert !isnothing(worker)
    @assert !in_writer.writing_flag[]
    time_left() = (deadline - time_ns())%Int64
    event_channel = x.event_channel
    out = LimitedOutput(;out_limit)
    err = LimitedOutput(;out_limit)
    if time_left() > 0
        put!(in_writer.channel, collect(codeunits(code)))
    end
    timed_out = false
    out_eof = false
    err_eof = false
    function process_event(event)
        local name, data = event
        if name === :err
            if isempty(data)
                err_eof = true
            end
            append_out!(err, data)
        elseif name === :out
            if isempty(data)
                out_eof = true
            end
            append_out!(out, data)
        elseif name === :timer
            nothing
        else
            error("unreachable")
        end
        nothing
    end
    while true
        if time_left() ≤ 0 && !timed_out
            try
                close(x.worker_in)
            catch
            end
            try
                close(in_writer.channel)
            catch
            end
            # Hopefully capture a nice stack trace, so don't close event_channel
            timed_out = true
            kill(worker)
        elseif time_left() ≤ -Int64(10)^10 && !process_exited(worker)
            close(x.worker_out.in)
            close(x.worker_err.in)
            kill(worker)
            sleep(2.0)
        end
        if process_exited(worker)
            # Drain stdout and stderr
            close(x.worker_out.in)
            close(x.worker_err.in)
            while !out_eof || !err_eof
                process_event(take!(event_channel))
            end
            exitcode = worker.exitcode
            clean_up_session!(x)
            return EvalResults(out, err, timed_out, true, exitcode)
        end
        if isready(event_channel)
            process_event(take!(event_channel))
        else
            local timer = Timer(0.1) do t
                try
                    put!(event_channel, :timer=>UInt8[])
                catch
                end
                nothing
            end
            next_event = take!(event_channel)
            close(timer)
            process_event(next_event)
        end
        if !in_writer.writing_flag[] && out_endswith(out, x.sentinel) && !timed_out
            # success
            # drop sentinel
            drop_end!(out, length(x.sentinel))
            return EvalResults(out, err, false, false, 0)
        end
    end
end

function gen_log_path(log_dir::String, env_path::String)
    p = relpath(abspath(env_path), abspath(log_dir))
    p_safe = replace(p, "/"=>"-s", "\\"=>"-b", ":"=>"-c", "-"=>"--" )
    joinpath(log_dir, "env_$(p_safe)_$(Dates.format(Dates.now(), "yyyy-mm-dd_HH-MM-SS-sss")).log")
end
