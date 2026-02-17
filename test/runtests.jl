using Test: @test, @testset
using SandboxMCPRepl:
    SandboxMCPRepl,
    LimitedOutput,
    append_out!,
    out_endswith,
    drop_end!,
    nbytes,
    nice_string

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
end

end # testset SandboxMCPRepl
nothing
