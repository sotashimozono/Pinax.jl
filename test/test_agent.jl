using Pinax
using Test

# The :agent backend renders the SAME document as structured data (agent.json + agent.md) instead of
# human HTML — selectable by theme. Each figure carries its verification substrate (code / params /
# asset / comments) so an agent can reconcile a claim against its evidence ("data 照合").
@testset "agent backend: structured output, switchable from the human theme" begin
    tmp = mktempdir()
    svg = joinpath(tmp, "f.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")

    Pinax.reset!(; title="demo")
    @part :thermal "Thermal" desc = md"prior-work reproduction" begin
        @page :energy "Energy" summary = "Control: N, g" begin
            @desc md"energy vs T"
            @figure svg params = (N=24, g=0.5)
            @caption "E/N"
        end
    end
    cf = joinpath(tmp, "comments.toml")
    Pinax.add_comment(cf, :energy_fig1, "converged"; author="me")

    # one document → two backends, by switching the theme only
    gp = Pinax.render(; out=joinpath(tmp, "human"), theme=:gallery, comments_file=cf)
    ap = Pinax.render(; out=joinpath(tmp, "agent"), theme=:agent, comments_file=cf)
    @test endswith(gp, "index.html")     # human backend → HTML
    @test endswith(ap, "agent.json")     # agent backend → structured data

    j = read(ap, String)
    @test occursin("\"id\":\"energy\"", j)
    @test occursin("\"part\":\"thermal\"", j)
    @test occursin("\"summary\":\"Control: N, g\"", j)
    @test occursin("\"code\":\"svg\"", j)                  # the generating expression (verification)
    @test occursin("\"params\":\"(N = 24, g = 0.5)\"", j)  # the data binding (provenance)
    @test occursin("energy_fig1.svg", j)                   # the rendered asset path
    @test occursin("\"text\":\"converged\"", j)            # the id-keyed comment thread

    md = read(joinpath(tmp, "agent", "agent.md"), String)
    @test occursin("[id: energy]", md)
    @test occursin("[fig: energy_fig1]", md)
    @test occursin("data: (N = 24, g = 0.5)", md)

    # the agent backend is registered like any other (self-hosting: no privileged core)
    @test Pinax._resolve_theme(:agent) isa Pinax.AgentTheme
end
