using Pinax
using Test

# `@section :id "T" layout=…` hints how that section's figures are laid out. The gallery maps it to a
# modifier on the figure-grid container: :grid (default) auto-fit multi-column, :single one
# width-capped centered column, :wide one full-width column.
@testset "section layout= hint" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    site(n) = joinpath(tmp, n)

    @testset "layout maps to a figgrid modifier class" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :g "Grid" begin            # no layout → default grid
                @figure svg
            end
            @section :s "Single" layout = :single begin
                @figure svg
            end
            @section :w "Wide" layout = :wide begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("lay")), String)
        @test occursin("<div class=\"figgrid\">", html)              # default, no modifier
        @test occursin("<div class=\"figgrid figgrid-single\">", html)
        @test occursin("<div class=\"figgrid figgrid-wide\">", html)
        # the modifier CSS is present so the classes actually do something
        @test occursin(".figgrid-single{", html)
        @test occursin(".figgrid-wide{", html)
    end

    @testset "explicit layout=:grid is the same as the default" begin
        Pinax.reset!()
        @page :p "P" begin
            @section :g "G" layout = :grid begin
                @figure svg
            end
        end
        html = read(Pinax.render(; out=site("grid")), String)
        @test occursin("<div class=\"figgrid\">", html)                   # same as the default
        @test !occursin("<div class=\"figgrid figgrid-single\">", html)   # no modifier emitted
        @test !occursin("<div class=\"figgrid figgrid-wide\">", html)
    end

    @testset "an invalid layout= is rejected, not silently ignored" begin
        Pinax.reset!()
        @test_throws ErrorException @page :p "P" begin
            @section :s "S" layout = :bogus begin
                @figure svg
            end
        end
    end
end
