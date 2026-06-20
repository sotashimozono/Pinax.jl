using Pinax
using Test

# D2 is a browser layer; CI can't run the JS, so these assert the server-emitted scaffolding the JS
# depends on (inlined assets, the committed-comments JSON baseline, and the feature gating).
@testset "interactive comment layer (D2 scaffolding)" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    @testset "default features inline the JS/CSS + committed JSON baseline" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("d1")), String)
        @test occursin("id=\"pinax-committed\"", html)   # embedded baseline for export merge
        @test occursin("\"features\":[", html)
        @test occursin("function openEditor", html)       # pinax.js inlined (single self-contained file)
        @test occursin(".pinax-editor", html)             # pinax.css inlined
        # the local-only note ships, so a reviewer of a deployed gallery is told comments are local
        @test occursin("Comments are saved only in this browser", html)
    end

    @testset "features=() disables the interactive layer" begin
        Pinax.reset!(; features=())
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("d2")), String)
        @test !occursin("id=\"pinax-committed\"", html)
        @test !occursin("function openEditor", html)
    end

    @testset "committed comments + bookmark are embedded in the JSON baseline" begin
        f = joinpath(tmp, "c.toml")
        Pinax.add_comment(f, :s, "prior note"; author="llm")
        Pinax.set_bookmark!(f, :s, true)
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("d3"), comments_file=f), String)
        @test occursin("prior note", html)
        @test occursin("\"bookmarks\":{\"s\":true", html)
    end

    @testset "committed JSON is <script>-safe (escapes < > &)" begin
        f = joinpath(tmp, "c2.toml")
        Pinax.add_comment(f, :s, "danger </script> & <b>"; author="x")
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("d4"), comments_file=f), String)
        @test occursin("\\u003c", html)             # `<` escaped inside the JSON
        @test !occursin("danger </script>", html)   # the raw breakout sequence must not appear
    end

    @testset ":comments off hides committed comment display" begin
        f = joinpath(tmp, "c3.toml")
        Pinax.add_comment(f, :s, "hidden text"; author="x")
        Pinax.reset!(; features=(:bookmarks,))
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("d5"), comments_file=f), String)
        @test !occursin("<div class=\"pinax-comments\">", html)
    end

    @testset ":bookmarks off hides the bookmark marker" begin
        f = joinpath(tmp, "c4.toml")
        Pinax.set_bookmark!(f, :s, true)
        Pinax.reset!(; features=(:comments,))
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("d6"), comments_file=f), String)
        @test !occursin("class=\"section bookmarked\"", html)
    end
end
