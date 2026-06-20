# cache.jl — incremental render: skip unchanged figures across renders, clean orphans (notes 10).
#
# A figure is re-materialized only when its cache key changed or its asset files are gone.
# The cache key = hash(@figure source `code` + params identity + requested formats); it is
# computed WITHOUT calling `gen`, so a hit skips materialization entirely. The previous render's
# outputs are tracked in a manifest under `out/`; assets it produced but this render did not are
# deleted (orphan cleanup).
#
# Data-content tracking: pass a DataVault `vault` to `render` and the key also folds in a fingerprint
# of each `params::DataKey` figure's `.done` marker, so recomputing the data re-materializes it (see
# `_data_fingerprint`). Without a vault, a pre-made file figure whose CONTENTS change but whose
# manuscript does not is still not detected — pass `force=true` (or edit the manuscript).

const MANIFEST_FILE = ".pinax-manifest.toml"

"Per-render cache state: the previous manifest (read from disk) and the one being built. `vault` (if
set) lets the cache key track the figure's DataVault data, not just its code+params."
mutable struct RenderCache
    outdir::String
    force::Bool
    vault::Any              # DataVault.Vault | Nothing — for data-content fingerprinting
    old::Dict{String,Any}   # fig-path-key => Dict("key"=>cachekey, "assets"=>[rel paths])
    new::Dict{String,Any}
end
function RenderCache(outdir::AbstractString, force::Bool, vault=nothing)
    return RenderCache(
        String(outdir), force, vault, _read_manifest(outdir), Dict{String,Any}()
    )
end

# Stable identity for the figure's params. The PinaxParamIOExt extension specializes this on a
# ParamIO.DataKey (ParamIO's order-/version-independent `canonical`, so equal params in any insertion
# order yield the same key); the core falls back to `repr`.
_params_id(p) = repr(p)

# Per-key data fingerprint: the content of DataVault's `.done` marker, which is rewritten whenever
# the data is (re)computed, so changing the underlying data changes the key and the figure
# re-materializes (notes 10; fixes the false-hit gap). The PinaxDataVaultExt extension specializes
# this on a (DataVault.Vault, ParamIO.DataKey); the core contributes "" (code+params only) — without
# the extension, without a vault, or for a non-DataKey, the prior behavior.
_data_fingerprint(vault, params) = ""

function _cache_key(fig::Figure, fmts, vault)
    return string(
        hash((
            fig.code,
            _params_id(fig.params),
            Tuple(fmts),
            _data_fingerprint(vault, fig.params),
        )),
    )
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
    key = _cache_key(fig, fmts, cache.vault)
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
