using Pinax
using Test

@testset "KaTeX assets: CDN default vs vendored offline" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    @testset "default :cdn references the CDN, copies nothing" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        out = site("cdn")
        html = read(Pinax.render(; out=out), String)
        @test occursin("cdn.jsdelivr.net/npm/katex", html)
        @test !isdir(joinpath(out, "assets", "katex"))
    end

    @testset ":local vendors KaTeX into out/ and references it (offline)" begin
        Pinax.reset!(; katex=:local)
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        out = site("local")
        html = read(Pinax.render(; out=out), String)
        @test occursin("href=\"assets/katex/katex.min.css\"", html)
        @test occursin("src=\"assets/katex/katex.min.js\"", html)
        @test !occursin("cdn.jsdelivr.net", html)                       # fully offline
        @test isfile(joinpath(out, "assets", "katex", "katex.min.css"))
        @test isfile(joinpath(out, "assets", "katex", "katex.min.js"))
        @test isfile(joinpath(out, "assets", "katex", "contrib", "auto-render.min.js"))
        @test length(readdir(joinpath(out, "assets", "katex", "fonts"))) >= 1   # woff2 fonts copied
    end
end
