using Pinax
using Test

# The weak-dependency refactor's core contract: Pinax renders WITHOUT ParamIO/DataVault loaded. The
# main test environment carries both as test deps (so the extensions are exercised by
# test_facet / test_datavault / test_stack), which means the only way to check the light path is a
# fresh subprocess that loads ONLY Pinax — if the core ever re-references ParamIO/DataVault, the
# in-process tests stay green but this one fails.
@testset "light path: core renders with no ParamIO/DataVault loaded" begin
    script = raw"""
    using Pinax
    leaked = filter(m -> occursin(r"ParamIO|DataVault", string(m)), collect(keys(Base.loaded_modules)))
    isempty(leaked) || error("HPC deps leaked into the core session: $(leaked)")
    tmp = mktempdir()
    svg = joinpath(tmp, "a.svg")
    write(svg, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
    Pinax.reset!()
    @page :p "P" begin
        @section :s "S" by = "axis" begin
            @figure svg params = (; axis = 8)
            @figure svg params = (; axis = 16)
        end
    end
    figs = Pinax.current_document().pages[1].sections[1].figures
    figs[1].id === :s_fig1 || error("expected a positional id :s_fig1, got $(figs[1].id)")
    html = read(Pinax.render(; out = joinpath(tmp, "out")), String)
    occursin("Fig. 1", html) || error("render produced no figure")
    # without the ParamIO extension, _facet_value is missing for every figure -> one (unset) group
    occursin("(unset)", html) || error("non-DataKey params should collapse to a single (unset) facet")
    print("LIGHTPATH_OK")
    """
    buf = IOBuffer()
    cmd = pipeline(
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $(script)`;
        stdout=buf,
        stderr=buf,
    )
    ok = success(cmd)
    out = String(take!(buf))
    (ok && occursin("LIGHTPATH_OK", out)) ||
        @error "light-path subprocess failed" output = out
    @test ok
    @test occursin("LIGHTPATH_OK", out)
end
