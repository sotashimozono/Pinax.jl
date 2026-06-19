# cache.jl — incremental render: skip unchanged figures across renders, clean orphans (notes 10).
#
# A figure is re-materialized only when its cache key changed or its asset files are gone.
# The cache key = hash(@figure source `code` + params identity + requested formats); it is
# computed WITHOUT calling `gen`, so a hit skips materialization entirely. The previous render's
# outputs are tracked in a manifest under `out/`; assets it produced but this render did not are
# deleted (orphan cleanup).
#
# Limitation: for a pre-made file figure the source path lives inside `code`, so if the file's
# CONTENTS change but the manuscript does not, the change is not detected — pass `force=true`
# (or edit the manuscript). Data-content fingerprinting via DataVault comes with the
# stack-integration slice.

const MANIFEST_FILE = ".pinax-manifest.toml"

"Per-render cache state: the previous manifest (read from disk) and the one being built."
mutable struct RenderCache
    outdir::String
    force::Bool
    old::Dict{String,Any}   # fig-path-key => Dict("key"=>cachekey, "assets"=>[rel paths])
    new::Dict{String,Any}
end
function RenderCache(outdir::AbstractString, force::Bool)
    return RenderCache(String(outdir), force, _read_manifest(outdir), Dict{String,Any}())
end

# Stable identity for the figure's params: ParamIO's order-/version-independent `canonical`
# for a DataKey (so equal params in any insertion order yield the same key), else `repr`.
function _params_id(p)
    p isa ParamIO.DataKey || return repr(p)
    try
        return ParamIO.canonical(p)
    catch
        return repr(p)
    end
end

function _cache_key(fig::Figure, fmts)
    return string(hash((fig.code, _params_id(fig.params), Tuple(fmts))))
end

# Manifest key: the figure's output base path (unique per page/section/figure), TOML-safe.
_manifest_key(base, outdir) = replace(relpath(base, outdir), r"[^A-Za-z0-9_-]" => "_")

function _read_manifest(outdir)
    f = joinpath(outdir, MANIFEST_FILE)
    isfile(f) || return Dict{String,Any}()
    try
        return TOML.parsefile(f)
    catch
        return Dict{String,Any}()   # corrupt manifest -> treat as empty (everything re-materializes)
    end
end

function _write_manifest(outdir, manifest)
    open(joinpath(outdir, MANIFEST_FILE), "w") do io
        return TOML.print(io, manifest)
    end
    return nothing
end

"""
    materialize!(fig, base, fmts, cache) -> :hit | :miss

Populate `fig.assets`. On a cache hit (unchanged key + assets still present) the deferred `gen`
is NOT called. On a miss, materialize for real and record the result in the new manifest. May
rethrow whatever `_materialize` throws (the caller turns it into a diagnostic).
"""
function materialize!(fig::Figure, base, fmts, cache::RenderCache)
    key = _cache_key(fig, fmts)
    od = cache.outdir
    mkey = _manifest_key(base, od)
    if !cache.force
        old = get(cache.old, mkey, nothing)
        if old isa AbstractDict && get(old, "key", nothing) == key
            rels = String.(get(old, "assets", String[]))
            abss = String[joinpath(od, r) for r in rels]
            if !isempty(abss) && all(isfile, abss)
                fig.assets = abss
                cache.new[mkey] = old
                return :hit
            end
        end
    end
    fig.assets = _materialize(fig, base, fmts)
    cache.new[mkey] = Dict{String,Any}(
        "key" => key, "assets" => String[relpath(a, od) for a in fig.assets]
    )
    return :miss
end

"Write the new manifest and delete asset files the previous render produced but this one did not."
function _finalize_cache!(cache::RenderCache)
    kept = Set{String}()
    for (_, v) in cache.new, r in get(v, "assets", String[])
        push!(kept, joinpath(cache.outdir, r))
    end
    for (_, v) in cache.old, r in get(v, "assets", String[])
        a = joinpath(cache.outdir, r)
        (a in kept) || (isfile(a) && rm(a; force=true))
    end
    _write_manifest(cache.outdir, cache.new)
    return cache
end
