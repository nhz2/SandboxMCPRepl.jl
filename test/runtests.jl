using Test: @test, @testset, @test_throws
using SandboxMCPRepl:
    SandboxMCPRepl,
    LimitedOutput,
    append_out!,
    out_endswith,
    drop_end!,
    nbytes,
    nice_string,
    log_string,
    probe_julia,
    HelpRequested,
    julia_eval_handler,
    julia_restart_handler,
    julia_list_sessions_handler,
    SESSIONS,
    SESSION_LOGS,
    READ_ONLY_PATHS,
    READ_WRITE_PATHS,
    WORKER_ENV,
    LOG_DIR,
    JULIA_CMD,
    WORKER_DEPOT_PATH,
    OUT_LIMIT,
    apply_config!,
    parse_args

using Random: RandomDevice
using SandboxMCPRepl

using Aqua: Aqua

@testset "SandboxMCPRepl" begin

Aqua.test_ambiguities(SandboxMCPRepl)
Aqua.test_unbound_args(SandboxMCPRepl)
Aqua.test_undefined_exports(SandboxMCPRepl)
Aqua.test_project_extras(SandboxMCPRepl)
Aqua.test_stale_deps(SandboxMCPRepl)
Aqua.test_piracies(SandboxMCPRepl)
Aqua.test_persistent_tasks(SandboxMCPRepl)

@testset "LimitedOutput" begin
    @test LimitedOutput() isa LimitedOutput
    a = LimitedOutput()
    @test iszero(nbytes(a))
    @test out_endswith(a, UInt8[])
    @test !out_endswith(a, UInt8[0x00])
    append_out!(a, UInt8[])
    @test iszero(nbytes(a))
    @test nice_string(a) == ""
    append_out!(a, UInt8[0x00])
    @test nice_string(a) == "\0"
    @test isone(nbytes(a))
    @test out_endswith(a, UInt8[])
    @test out_endswith(a, UInt8[0x00])
    @test !out_endswith(a, UInt8[0x01])
    @test !out_endswith(a, UInt8[0x00, 0x00])
    append_out!(a, UInt8[0x01])
    @test nice_string(a) == "\0\x01"
    @test nbytes(a) == 2
    @test out_endswith(a, UInt8[])
    @test !out_endswith(a, UInt8[0x00])
    @test out_endswith(a, UInt8[0x01])
    @test !out_endswith(a, UInt8[0x00, 0x00])
    @test out_endswith(a, UInt8[0x00, 0x01])
    drop_end!(a, 1)
    @test nbytes(a) == 1
    @test nice_string(a) == "\0"

    # Test truncated
    a = LimitedOutput(;out_limit = 3)
    append_out!(a, collect(0x00:0xff))
    @test a.start == 0x00:0x02
    @test a.last == 0xfd:0xff
    @test nbytes(a) == 256
    @test nice_string(a) == "\0\x01\x02\n... 250 BYTES TRUNCATED ...\n\ufffd\ufffd\ufffd\n 250 BYTES WERE TRUNCATED FROM THE CENTER\n"
    append_out!(a, [0x41])
    @test nice_string(a) == "\0\x01\x02\n... 251 BYTES TRUNCATED ...\n\ufffd\ufffdA\n 251 BYTES WERE TRUNCATED FROM THE CENTER\n"
    append_out!(a, [0x42, 0x43, 0x44])
    @test nice_string(a) == "\0\x01\x02\n... 254 BYTES TRUNCATED ...\nBCD\n 254 BYTES WERE TRUNCATED FROM THE CENTER\n"
    append_out!(a, [0x42, 0x43, 0x44, 0x45])
    @test nice_string(a) == "\0\x01\x02\n... 258 BYTES TRUNCATED ...\nCDE\n 258 BYTES WERE TRUNCATED FROM THE CENTER\n"
    @test out_endswith(a, [0x44, 0x45])
    @test !out_endswith(a, [0x44, 0x44])
    drop_end!(a, 1)
    @test nice_string(a) == "\0\x01\x02\n... 258 BYTES TRUNCATED ...\nCD\n 258 BYTES WERE TRUNCATED FROM THE CENTER\n"

    a = LimitedOutput(;out_limit = 3)
    append_out!(a, [0x41, 0x42, 0x43])
    @test nice_string(a) == "ABC"
    append_out!(a, [0x44])
    @test nice_string(a) == "ABCD"
    @test out_endswith(a, [0x44])
    @test out_endswith(a, [0x43, 0x44])
    @test !out_endswith(a, [0x44, 0x44])
    drop_end!(a, 2)
    @test nice_string(a) == "AB"
end
@testset "EvalResults" begin
    # Successful eval with stdout only
    r = EvalResults(LimitedOutput(collect(codeunits("hello"))), LimitedOutput(), false, false, 0)
    @test nice_string(r) == "hello"
    @test log_string(r) == "[OUTPUT]\nhello\n"

    # Successful eval with stdout and stderr
    r = EvalResults(LimitedOutput(collect(codeunits("out"))), LimitedOutput(collect(codeunits("err"))), false, false, 0)
    @test nice_string(r) == "out\n--- STDERR ---\nerr"
    @test log_string(r) == "[OUTPUT]\nout\n[STDERR]\nerr\n"

    # Empty output
    r = EvalResults(LimitedOutput(), LimitedOutput(), false, false, 0)
    @test nice_string(r) == ""
    @test log_string(r) == ""

    # Timed out
    r = EvalResults(LimitedOutput(collect(codeunits("partial"))), LimitedOutput(), true, true, -1)
    @test contains(nice_string(r), "partial")
    @test contains(nice_string(r), "TIMED OUT:")
    @test contains(log_string(r), "partial")
    @test contains(log_string(r), "[STATUS] Timed out")

    # Worker died (not timeout)
    r = EvalResults(LimitedOutput(collect(codeunits("x"))), LimitedOutput(), false, true, 42)
    @test contains(nice_string(r), "WORKER DIED")
    @test contains(nice_string(r), "42")
    @test contains(nice_string(r), "x")
    @test contains(log_string(r), "[STATUS] Worker exited with code: 42")
    @test contains(log_string(r), "x")
end
@testset "JuliaSession" begin
    # Default session with a temp environment
    x = JuliaSession()
    try
        reset_session!(x)
        r = eval_session!(x, "1+1", time_ns()+600*10^9, 2000)
        @test nice_string(r.out) == "2"
        @test !r.worker_died

        # timeout with sleep
        reset_session!(x)
        r = eval_session!(x, "print(2); sleep(100)", time_ns()+1*10^9, 2000)
        @test nice_string(r.out) == "2"
        @test r.worker_died
        @test r.timed_out

        # timeout with math loop
        reset_session!(x)
        r = eval_session!(x, """
            function foo(x, n)
                print(2)
                for i in 1:n
                    x += sin(i)
                end
                x
            end
            foo(0.0, typemax(Int64))
        """, time_ns()+1*10^9, 2000)
        @test nice_string(r.out) == "2"
        @test r.worker_died
        @test r.timed_out

        # timeout with infinite printing loop
        reset_session!(x)
        r = eval_session!(x, """
            function foo(n)
                for i in 1:n
                    print(i)
                end
            end
            foo(typemax(Int64))
        """, time_ns()+1*10^9, 1000)
        @test startswith(nice_string(r.out), "1234")
        @test endswith(nice_string(r.out), "BYTES WERE TRUNCATED FROM THE CENTER\n")
        @test r.worker_died
        @test r.timed_out

        # exit
        reset_session!(x)
        r = eval_session!(x, """
            print(2)
            exit(123)
        """, time_ns()+500*10^9, 2000)
        @test nice_string(r.out) == "2"
        @test r.worker_died
        @test !r.timed_out
        @test r.exitcode == 123

        # close stdout
        reset_session!(x)
        r = eval_session!(x, """
            print(2)
            close(stdout)
        """, time_ns()+500*10^9, 2000)
        @test startswith(nice_string(r.out),"2")
        @test r.worker_died
        @test !r.timed_out
        @test r.exitcode == 1

        # close stderr
        reset_session!(x)
        r = eval_session!(x, """
            print(2)
            close(stderr)
            close(stdout)
        """, time_ns()+500*10^9, 2000)
        @test startswith(nice_string(r.out),"2")
        @test r.worker_died
        @test !r.timed_out
        @test r.exitcode == 1

        # error
        reset_session!(x)
        r = eval_session!(x, """
            error("what")
        """, time_ns()+500*10^9, 2000)
        @test startswith(nice_string(r.out),"\nERROR: LoadError: what\n")
        @test !r.worker_died

        # parse error
        reset_session!(x)
        r = eval_session!(x, """
            error("what"
        """, time_ns()+500*10^9, 2000)
        @test startswith(nice_string(r.out),"\nERROR: LoadError: ParseError:\n")
        @test !r.worker_died

        # variables should persist
        reset_session!(x)
        r = eval_session!(x, """
            foo = 42
            nothing
        """, time_ns()+500*10^9, 2000)
        @test nice_string(r.out) == "nothing"
        @test !r.worker_died
        r = eval_session!(x, """
            foo
        """, time_ns()+500*10^9, 2000)
        @test nice_string(r.out) == "42"
        @test !r.worker_died
        # But not after reset
        reset_session!(x)
        r = eval_session!(x, """
            @isdefined foo
        """, time_ns()+500*10^9, 2000)
        @test nice_string(r.out) == "false"

        # Depot changes are not persisted
        reset_session!(x)
        r = eval_session!(x, """
            mkpath(DEPOT_PATH[1])
            write(joinpath(DEPOT_PATH[1], "test-file.txt"), "stuff in file")
            println(read(joinpath(DEPOT_PATH[1], "test-file.txt"), String))
        """, time_ns()+500*10^9, 2000)
        @test nice_string(r.out) == "stuff in file\nnothing"
        @test !r.worker_died
        reset_session!(x)
        r = eval_session!(x, """
            isfile(joinpath(DEPOT_PATH[1], "test-file.txt"))
        """, time_ns()+500*10^9, 2000)
        @test nice_string(r.out) == "false"
        @test !r.worker_died

        # Process dies in the background in between evals
        reset_session!(x)
        r = eval_session!(x, """
            Threads.@spawn begin
                sleep(1.0)
                print("I'm exiting")
                exit(123)
            end
            nothing
        """, time_ns()+500*10^9, 2000)
        @test !r.worker_died
        sleep(2.0)
        r = eval_session!(x, """
            print(2)
        """, time_ns()+500*10^9, 2000)
        @test r.worker_died
        @test !r.timed_out
        @test nice_string(r.out) == "I'm exiting"
        @test r.exitcode == 123
    finally
        clean_up_session!(x)
    end

    # project_path, also requires the path to be available
    x = JuliaSession(; project_path=joinpath(@__DIR__, "testenv"))
    reset_session!(x)
    r = eval_session!(x, "using Pkg; Pkg.instantiate(); using Example", time_ns()+600*10^9, 2000)
    @test startswith(nice_string(r.out), "\nERROR: LoadError:")
    clean_up_session!(x)

    x = JuliaSession(; project_path=joinpath(@__DIR__, "testenv"), read_only_paths=[joinpath(@__DIR__, "testenv")])
    reset_session!(x)
    r = eval_session!(x, "using Pkg; Pkg.instantiate(); using Example; pwd()", time_ns()+600*10^9, 2000)
    @test nice_string(r.out) == repr(joinpath(@__DIR__, "testenv"))
    clean_up_session!(x)

    x = JuliaSession(; project_path=joinpath(@__DIR__, "testenv"), read_write_paths=[joinpath(@__DIR__, "testenv")])
    reset_session!(x)
    r = eval_session!(x, "using Pkg; Pkg.instantiate(); using Example; pwd()", time_ns()+600*10^9, 2000)
    @test nice_string(r.out) == repr(joinpath(@__DIR__, "testenv"))
    clean_up_session!(x)

    # worker_env
    x = JuliaSession(;worker_env=Dict("SANDBOXMCPREPL_TEST"=>"yes"))
    reset_session!(x)
    r = eval_session!(x, "ENV[\"SANDBOXMCPREPL_TEST\"]", time_ns()+600*10^9, 2000)
    @test nice_string(r.out) == repr("yes")
    clean_up_session!(x)

    # read_only_paths
    test_dir = mktempdir()
    write(joinpath(test_dir, "test-file.txt"), "stuff")
    x = JuliaSession(; read_only_paths=[test_dir])
    reset_session!(x)
    r = eval_session!(x, "read($(repr(joinpath(test_dir, "test-file.txt"))),String)", time_ns()+600*10^9, 2000)
    @test nice_string(r.out) == repr("stuff")
    r = eval_session!(x, """
        write($(repr(joinpath(test_dir, "test-file.txt"))), "edit")
    """, time_ns()+600*10^9, 2000)
    @test contains(nice_string(r.out), "Read-only file system")
    @test contains(nice_string(r.out), "ERROR:")
    clean_up_session!(x)

    # read_write_paths
    test_dir = mktempdir()
    write(joinpath(test_dir, "test-file.txt"), "stuff")
    x = JuliaSession(; read_write_paths=[test_dir])
    reset_session!(x)
    r = eval_session!(x, "read($(repr(joinpath(test_dir, "test-file.txt"))),String)", time_ns()+600*10^9, 2000)
    @test nice_string(r.out) == repr("stuff")
    r = eval_session!(x, """
        write($(repr(joinpath(test_dir, "test-file.txt"))), "edit")
    """, time_ns()+600*10^9, 2000)
    @test nice_string(r.out) == "4"
    @test read(joinpath(test_dir, "test-file.txt"), String) == "edit"
    clean_up_session!(x)

    # display_lines
    x = JuliaSession(; display_lines=240)
    reset_session!(x)
    r = eval_session!(x, "displaysize()", time_ns()+600*10^9, 2000)
    @test startswith(nice_string(r.out), "(240,")
    clean_up_session!(x)

    # julia_cmd and depot_path kwargs
    probe_result = probe_julia([joinpath(Sys.BINDIR, Base.julia_exename())])
    x = JuliaSession(;
        julia_cmd=probe_result.julia_cmd,
        depot_path=probe_result.depot_path,
    )
    reset_session!(x)
    r = eval_session!(x, "1+1", time_ns()+600*10^9, 2000)
    @test nice_string(r.out) == "2"
    @test !r.worker_died
    clean_up_session!(x)
end

@testset "probe_julia" begin
    result = probe_julia([joinpath(Sys.BINDIR, Base.julia_exename())])
    @test length(result.julia_cmd) == 1
    @test result.julia_cmd[1] == joinpath(Sys.BINDIR, Base.julia_exename())
    @test !isempty(result.depot_path)
end

@testset "parse_args" begin
    # Empty args
    c = parse_args(String[])
    @test isempty(c.read_only)
    @test isempty(c.read_write)
    @test isempty(c.env)
    @test c.log_dir == ""
    @test c.out_limit == SandboxMCPRepl.DEFAULT_OUT_LIMIT
    @test c.workspace == ""
    @test isempty(c.julia_launch_cmd)

    # --read-only with multiple colon-separated paths
    c = parse_args(["--read-only=/a:/b:/c"])
    @test c.read_only == ["/a", "/b", "/c"]

    # --read-only with single path
    c = parse_args(["--read-only=/x"])
    @test c.read_only == ["/x"]

    # --read-write with multiple paths
    c = parse_args(["--read-write=/d:/e"])
    @test c.read_write == ["/d", "/e"]

    # --env basic
    c = parse_args(["--env=FOO=bar"])
    @test c.env == Dict("FOO" => "bar")

    # --env with value containing '='
    c = parse_args(["--env=KEY=a=b=c"])
    @test c.env == Dict("KEY" => "a=b=c")

    # --env with empty value
    c = parse_args(["--env=KEY="])
    @test c.env == Dict("KEY" => "")

    # --env repeated
    c = parse_args(["--env=A=1", "--env=B=2"])
    @test c.env == Dict("A" => "1", "B" => "2")

    # --env invalid (no key)
    @test_throws ArgumentError parse_args(["--env=="])
    @test_throws ArgumentError parse_args(["--env="])

    # --log-dir
    c = parse_args(["--log-dir=/tmp/logs"])
    @test c.log_dir == "/tmp/logs"

    # --out-limit valid
    c = parse_args(["--out-limit=1024"])
    @test c.out_limit == 1024

    # --out-limit=256 (minimum allowed)
    c = parse_args(["--out-limit=256"])
    @test c.out_limit == 256

    # --out-limit too small
    @test_throws ArgumentError parse_args(["--out-limit=255"])
    @test_throws ArgumentError parse_args(["--out-limit=0"])

    # --workspace
    c = parse_args(["--workspace=/some/dir"])
    @test c.workspace == "/some/dir"

    # --help throws HelpRequested
    @test_throws HelpRequested parse_args(["--help"])
    @test_throws HelpRequested parse_args(["-h"])

    # Unknown argument
    @test_throws ArgumentError parse_args(["--bogus"])
    @test_throws ArgumentError parse_args(["positional"])

    # -- separator: everything after goes to julia_launch_cmd
    c = parse_args(["--read-only=/a", "--", "julia", "+1.9", "--threads=4"])
    @test c.read_only == ["/a"]
    @test c.julia_launch_cmd == ["julia", "+1.9", "--threads=4"]

    # -- with nothing before it
    c = parse_args(["--", "/opt/julia/bin/julia"])
    @test isempty(c.read_only)
    @test c.julia_launch_cmd == ["/opt/julia/bin/julia"]

    # -- with nothing after it
    c = parse_args(["--"])
    @test isempty(c.julia_launch_cmd)

    # Combined options
    c = parse_args([
        "--read-only=/ro1:/ro2",
        "--read-write=/rw1",
        "--env=HOME=/sandbox",
        "--env=LANG=C",
        "--log-dir=/logs",
        "--out-limit=5000",
        "--workspace=/work",
        "--", "julia", "+1.10"
    ])
    @test c.read_only == ["/ro1", "/ro2"]
    @test c.read_write == ["/rw1"]
    @test c.env == Dict("HOME" => "/sandbox", "LANG" => "C")
    @test c.log_dir == "/logs"
    @test c.out_limit == 5000
    @test c.workspace == "/work"
    @test c.julia_launch_cmd == ["julia", "+1.10"]

    # Empty colon-separated segments are filtered out
    c = parse_args(["--read-only=:/a::/b:"])
    @test c.read_only == ["/a", "/b"]
end

@testset "apply_config!" begin
    # Save original state to restore after tests
    orig_dir = pwd()
    try
        # Basic config with no workspace change
        config = parse_args(["--read-only=/tmp", "--read-write=/var", "--env=X=1", "--out-limit=999"])
        apply_config!(config)
        @test READ_ONLY_PATHS == [abspath("/tmp")]
        @test READ_WRITE_PATHS == [abspath("/var")]
        @test WORKER_ENV == Dict("X" => "1")
        @test OUT_LIMIT[] == 999
        @test LOG_DIR[] == ""
        @test !isempty(JULIA_CMD)
        @test !isempty(WORKER_DEPOT_PATH)

        # Empty config resets everything
        config = parse_args(String[])
        apply_config!(config)
        @test isempty(READ_ONLY_PATHS)
        @test isempty(READ_WRITE_PATHS)
        @test isempty(WORKER_ENV)
        @test OUT_LIMIT[] == SandboxMCPRepl.DEFAULT_OUT_LIMIT
        @test LOG_DIR[] == ""

        # Workspace changes directory
        tdir = mktempdir()
        config = parse_args(["--workspace=$tdir"])
        apply_config!(config)
        @test pwd() == tdir

        # log_dir becomes absolute
        cd(tdir)
        config = parse_args(["--log-dir=relative_logs"])
        apply_config!(config)
        @test LOG_DIR[] == joinpath(tdir, "relative_logs")
    finally
        cd(orig_dir)
    end
end

# Helper to clean up all handler sessions
function cleanup_handler_sessions!()
    for (k, v) in collect(SESSIONS)
        clean_up_session!(v)
        delete!(SESSIONS, k)
    end
    empty!(SESSION_LOGS)
end

@testset "julia_list_sessions_handler" begin
    # Ensure clean state
    cleanup_handler_sessions!()

    # No sessions
    result = julia_list_sessions_handler(Dict{String,Any}())
    @test result == "No active Julia sessions."

    # With a session
    SESSIONS["/test/path"] = JuliaSession()
    result = julia_list_sessions_handler(Dict{String,Any}())
    @test contains(result, "Active Julia sessions:")
    @test contains(result, "/test/path")

    cleanup_handler_sessions!()
end

# Helper to call julia_eval_handler with defaults
function handler_eval(code; env_path="", timeout=600.0)
    julia_eval_handler(Dict{String,Any}(
        "code" => code,
        "env_path" => env_path,
        "timeout" => timeout
    ))
end

@testset "julia_eval_handler" begin
    orig_dir = pwd()
    try
        # Baseline: minimal config
        apply_config!(parse_args(String[]))

        @testset "basic eval (temp session)" begin
            result = handler_eval("1+1")
            @test result isa String
            @test result == "2"
            @test isempty(SESSIONS)
        end

        @testset "named session persists state" begin
            env_dir = mktempdir()
            @test handler_eval("x_persist = 42; nothing"; env_path=env_dir) == "nothing"
            @test handler_eval("x_persist"; env_path=env_dir) == "42"
            cleanup_handler_sessions!()
        end

        @testset "--read-only makes paths readable but not writable" begin
            test_dir = mktempdir()
            write(joinpath(test_dir, "file.txt"), "readonly-content")
            apply_config!(parse_args(["--read-only=$test_dir"]))

            # Can read
            result = handler_eval("read($(repr(joinpath(test_dir, "file.txt"))), String)")
            @test result == repr("readonly-content")

            # Cannot write
            result = handler_eval("""
                write($(repr(joinpath(test_dir, "file.txt"))), "bad")
            """)
            @test contains(result, "Read-only file system")
            cleanup_handler_sessions!()
            apply_config!(parse_args(String[]))
        end

        @testset "--read-write makes paths readable and writable" begin
            test_dir = mktempdir()
            write(joinpath(test_dir, "file.txt"), "original")
            apply_config!(parse_args(["--read-write=$test_dir"]))

            # Can read
            result = handler_eval("read($(repr(joinpath(test_dir, "file.txt"))), String)")
            @test result == repr("original")

            # Can write
            result = handler_eval("write($(repr(joinpath(test_dir, "file.txt"))), \"edited\")")
            @test result == "6"
            @test read(joinpath(test_dir, "file.txt"), String) == "edited"

            apply_config!(parse_args(String[]))
        end

        @testset "--env sets environment variables in sandbox" begin
            test_var1 = String(rand(RandomDevice(), UInt8('A'):UInt8('Z'), 20))
            test_var2 = String(rand(RandomDevice(), UInt8('A'):UInt8('Z'), 20))
            apply_config!(parse_args(["--env=$(test_var1)=hello123", "--env=$(test_var2)=world"]))

            result = handler_eval("ENV[\"$(test_var1)\"]")
            @test result == repr("hello123")

            result = handler_eval("ENV[\"$(test_var2)\"]")
            @test result == repr("world")

            @test !haskey(ENV, test_var1)
            @test !haskey(ENV, test_var2)

            apply_config!(parse_args(String[]))
        end

        @testset "--env with empty value" begin
            test_var1 = String(rand(RandomDevice(), UInt8('A'):UInt8('Z'), 20))
            apply_config!(parse_args(["--env=$(test_var1)="]))

            result = handler_eval("ENV[\"$(test_var1)\"]")
            @test result == repr("")

            apply_config!(parse_args(String[]))
        end

        @testset "--out-limit truncates large output" begin
            apply_config!(parse_args(["--out-limit=500"]))

            # Generate output larger than limit
            result = handler_eval("print(repeat('A', 2000))")
            @test length(result) < 2000
            @test contains(result, "TRUNCATED")
            @test startswith(result, "A"^500)

            apply_config!(parse_args(String[]))
        end

        @testset "--log-dir writes log files for named sessions" begin
            logdir = mktempdir()
            env_dir = mktempdir()
            apply_config!(parse_args(["--log-dir=$logdir"]))

            handler_eval("1+1"; env_path=env_dir)
            handler_eval("2+2"; env_path=env_dir)

            # Log files should exist in logdir
            log_files = readdir(logdir)
            @test length(log_files) == 1

            # Log content should contain the code we ran
            log_content = read(joinpath(logdir, log_files[1]), String)
            @test contains(log_content, "1+1\n")
            @test contains(log_content, "2\n")
            @test contains(log_content, "2+2")
            @test contains(log_content, "4\n")
            @test contains(log_content, "[CODE]")

            cleanup_handler_sessions!()
            apply_config!(parse_args(String[]))
        end

        @testset "--log-dir does not log temp sessions" begin
            logdir = mktempdir()
            apply_config!(parse_args(["--log-dir=$logdir"]))

            handler_eval("1+1")  # temp session (env_path="")

            log_files = readdir(logdir)
            @test isempty(log_files)

            apply_config!(parse_args(String[]))
        end

        @testset "no --log-dir means no logging" begin
            apply_config!(parse_args(String[]))
            env_dir = mktempdir()

            handler_eval("1+1"; env_path=env_dir)
            @test isempty(SESSION_LOGS)

            cleanup_handler_sessions!()
        end

        @testset "--workspace affects relative env_path resolution" begin
            workspace_dir = mktempdir()
            env_subdir = joinpath(workspace_dir, "myenv")
            apply_config!(parse_args(["--workspace=$workspace_dir"]))

            # Using relative env_path should resolve relative to workspace
            handler_eval("42"; env_path="myenv")
            @test haskey(SESSIONS, env_subdir)

            cleanup_handler_sessions!()
            apply_config!(parse_args(String[]))
        end

        @testset "--read-only with multiple paths" begin
            dir1 = mktempdir()
            dir2 = mktempdir()
            write(joinpath(dir1, "a.txt"), "from-dir1")
            write(joinpath(dir2, "b.txt"), "from-dir2")
            apply_config!(parse_args(["--read-only=$dir1:$dir2"]))

            @test handler_eval("read($(repr(joinpath(dir1, "a.txt"))), String)") == repr("from-dir1")
            @test handler_eval("read($(repr(joinpath(dir2, "b.txt"))), String)") == repr("from-dir2")

            apply_config!(parse_args(String[]))
        end

        @testset "--read-only + --read-write combined" begin
            ro_dir = mktempdir()
            rw_dir = mktempdir()
            write(joinpath(ro_dir, "ro.txt"), "readonly")
            write(joinpath(rw_dir, "rw.txt"), "readwrite")
            apply_config!(parse_args(["--read-only=$ro_dir", "--read-write=$rw_dir"]))

            # Can read both
            @test handler_eval("read($(repr(joinpath(ro_dir, "ro.txt"))), String)") == repr("readonly")
            @test handler_eval("read($(repr(joinpath(rw_dir, "rw.txt"))), String)") == repr("readwrite")

            # Can only write to rw_dir
            result = handler_eval("""
                write($(repr(joinpath(ro_dir, "ro.txt"))), "bad")
            """)
            @test contains(result, "Read-only file system")

            result = handler_eval("write($(repr(joinpath(rw_dir, "rw.txt"))), \"updated\")")
            @test result == "7"
            @test read(joinpath(rw_dir, "rw.txt"), String) == "updated"

            apply_config!(parse_args(String[]))
        end

        @testset "timeout kills long-running eval" begin
            apply_config!(parse_args(String[]))

            result = handler_eval("print(\"before\"); sleep(1000)"; timeout=2.0)
            @test contains(result, "before")
            @test contains(result, "TIMED OUT")
        end

        @testset "eval error returns error result" begin
            apply_config!(parse_args(String[]))

            result = handler_eval("error(\"test-error-msg\")")
            @test contains(result, "ERROR")
            @test contains(result, "test-error-msg")
        end
    finally
        cleanup_handler_sessions!()
        cd(orig_dir)
    end
end

@testset "julia_restart_handler" begin
    orig_dir = pwd()
    try
        apply_config!(parse_args(String[]))

        env_dir = mktempdir()
        # Create a session with state
        handler_eval("restart_test_var = 99"; env_path=env_dir)

        # Restart it
        result = julia_restart_handler(Dict{String,Any}("env_path" => env_dir))
        @test contains(result, "Session restarted")

        # State should be gone after restart
        @test handler_eval("@isdefined restart_test_var"; env_path=env_dir) == "false"
    finally
        cleanup_handler_sessions!()
        cd(orig_dir)
    end
end

end # testset SandboxMCPRepl
nothing
