using Pinax
using Test
using DataVault: DataVault
using ParamIO: ParamIO

@testset "DataVault integration: data-content cache fingerprint + provenance" begin
    tmp = mktempdir()
    cfg = joinpath(tmp, "config.toml")
    write(
        cfg,
        """
        [study]
        project_name = "demo"
        total_samples = 1
        outdir = "$(joinpath(tmp, "vault"))"

        [datavault]
        path_keys = ["system.N"]

        [[paramsets]]
        [paramsets.system]
        N = [24]
        """,
    )
    spec = ParamIO.load(cfg)
    key = ParamIO.expand(spec)[1]
    vault = DataVault.Vault(cfg; run="phase1")
    DataVault.save!(vault, key, Dict("x" => 1))
    DataVault.mark_done!(vault, key)

    # a figure whose deferred gen() bumps a counter, so we can detect (re)materialization
    calls = Ref(0)
    svgsrc = joinpath(tmp, "src.svg")
    function build()
        Pinax.reset!()
        @page :p "P" begin
            @section :s "S" begin
                @figure params = key begin
                    calls[] += 1
                    write(svgsrc, "<svg xmlns='http://www.w3.org/2000/svg'><rect/></svg>")
                    svgsrc
                end
            end
        end
    end

    @testset "recomputing the data invalidates the cache (critique #8)" begin
        out = joinpath(tmp, "site")
        build()
        Pinax.render(; out=out, vault=vault)
        @test calls[] == 1                   # first render materializes
        build()
        Pinax.render(; out=out, vault=vault)
        @test calls[] == 1                   # unchanged data -> cache HIT (gen not called)
        sleep(1.1)
        DataVault.mark_done!(vault, key)      # data "recomputed" -> .done rewritten
        build()
        Pinax.render(; out=out, vault=vault)
        @test calls[] == 2                   # data changed -> cache MISS -> re-materialized
    end

    @testset "without a vault, data changes are not detected (prior behavior)" begin
        calls[] = 0
        out2 = joinpath(tmp, "site2")
        build()
        Pinax.render(; out=out2)             # no vault
        @test calls[] == 1
        sleep(1.1)
        DataVault.mark_done!(vault, key)
        build()
        Pinax.render(; out=out2)             # no vault -> still a hit despite data change
        @test calls[] == 1
    end

    @testset "record_figure writes study provenance meta.toml" begin
        build()
        Pinax.render(; out=joinpath(tmp, "site3"), vault=vault)
        meta = joinpath(vault.outdir, "figure", "phase1", "meta.toml")
        @test isfile(meta)
        @test occursin("git_hash", read(meta, String))
    end
end
