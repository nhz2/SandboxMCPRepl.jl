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

# Aqua.test_all(SandboxMCPRepl)
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
    x = JuliaSession
    reset_session!(x)
end

end # testset SandboxMCPRepl
nothing
