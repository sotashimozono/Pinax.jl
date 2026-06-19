using Pinax
using Test

# A minimal user-defined theme (top level so the method tables see it), exercising dispatch.
struct PlainTheme <: Pinax.Theme end
function Pinax.emit_document(::PlainTheme, doc, outdir, cache; comments_file="")
    p = joinpath(outdir, "index.html")
    write(p, "<html><body>PLAIN " * string(length(doc.pages)) * " pages</body></html>")
    return p
end

struct NoEmitTheme <: Pinax.Theme end   # deliberately does not implement emit_document

@testset "theme framework (dispatch / registry / resolution)" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    function mkdoc()
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
    end

    @testset "default spec (:gallery) resolves to the gallery renderer" begin
        mkdoc()
        html = read(Pinax.render(; out=site("g")), String)
        @test occursin("class=\"section\"", html)        # gallery markup
        @test occursin("id=\"pinax-committed\"", html)   # gallery interactive layer
    end

    @testset "a custom Theme instance is dispatched" begin
        mkdoc()
        html = read(Pinax.render(; out=site("p1"), theme=PlainTheme()), String)
        @test occursin("PLAIN 1 pages", html)
        @test !occursin("pinax-committed", html)         # the custom theme owns the whole output
    end

    @testset "register_theme! + document theme=:symbol" begin
        Pinax.register_theme!(:plain, PlainTheme())
        Pinax.reset!(; theme=:plain)
        @page :p "P" begin
            @section :s "S" begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("p2")), String)   # theme taken from the document
        @test occursin("PLAIN", html)
    end

    @testset "unknown theme symbol errors" begin
        mkdoc()
        @test_throws ErrorException Pinax.render(; out=site("u"), theme=:does_not_exist)
    end

    @testset "a theme missing emit_document errors" begin
        mkdoc()
        @test_throws ErrorException Pinax.render(; out=site("ne"), theme=NoEmitTheme())
    end

    @testset "theme loaded from a path that evaluates to a Theme" begin
        tf = joinpath(tmp, "mytheme.jl")
        write(
            tf,
            """
            struct FromFileTheme <: Pinax.Theme end
            function Pinax.emit_document(::FromFileTheme, doc, outdir, cache; comments_file="")
                p = joinpath(outdir, "index.html")
                write(p, "FROMFILE")
                return p
            end
            FromFileTheme()
            """,
        )
        mkdoc()
        html = read(Pinax.render(; out=site("pf"), theme=tf), String)
        @test occursin("FROMFILE", html)
    end
end
