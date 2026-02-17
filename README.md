# SandboxMCPRepl.jl
A Julia repl for LLM Agents using Sandbox.jl

Requires linux.

The sandbox is not for security, it is mainly to prevent accidental changes to files
outside the workspace when running julia code.

## Acknowledgements

The tool prompts and MCP interface design are based on [julia-mcp](https://github.com/aplavin/julia-mcp) by Alexander Plavin.
This project is a reimplementation in Julia using [Sandbox.jl](https://github.com/JuliaPackaging/Sandbox.jl) and [ModelContextProtocol.jl](https://github.com/JuliaComputing/ModelContextProtocol.jl).

