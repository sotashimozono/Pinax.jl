ENV["GKSwstype"] = "100"

using Pinax
using Test, Aqua
const dirs = ["."]

const FIG_BASE = joinpath(pkgdir(Pinax), "docs", "src", "assets")
const PATHS = Dict()
mkpath.(values(PATHS))

# Plain `@testset`: a bare `Pkg.test()` runs stock. Running `Pinax.test()` instead captures this same
# tree and renders/dumps it as a Pinax document (Pinax dogfooding its own bridge, no token in the file).
@testset "tests" begin
    # ----- Test the module itself. -----
    @testset "Aqua tests" begin
        @pinaxignore              # ran and counted, but it is not a result anyone wants to read
        Aqua.test_all(Pinax)
    end
    # ----- Test files in the "test" directory. -----
    test_args = copy(ARGS)
    println("Passed arguments ARGS = $(test_args) to tests.")
    @time for dir in dirs
        dirpath = joinpath(@__DIR__, dir)
        println("\nTest $(dirpath)")
        files = sort(
            filter(f -> startswith(f, "test_") && endswith(f, ".jl"), readdir(dirpath))
        )
        if isempty(files)
            println("  No test files found in $(dirpath).")
            @test false
        else
            for f in files
                @testset "$f" begin
                    filepath = joinpath(dirpath, f)
                    @time begin
                        println("  Including $(filepath)")
                        include(filepath)
                    end
                end
            end
        end
    end
end
