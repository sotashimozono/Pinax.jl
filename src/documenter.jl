# documenter.jl — the Pinax → Documenter bridge (roadmap 07). A LOOSE, decoupled bridge, deliberately
# NOT a Documenter plugin (the two models differ — notes 07 §将来/非目標: "bridge に留める"): a
# rendered, self-contained Pinax gallery is embedded into a Documenter page verbatim through an
# `@raw html` <iframe>, so a Pinax page appears AS-IS inside a Documenter site. iframe isolation is the
# whole point — the gallery's global `body`/`h1`/`nav`/`figure` CSS and its KaTeX + comment/bookmark JS
# cannot collide with Documenter's own, and Documenter's MathJax never fights the gallery's KaTeX.
#
# The real methods live in `ext/PinaxDocumenterExt.jl` (loaded when Documenter is imported), mirroring
# how `report` is a core stub the DataVault extension specializes. Keeping it in an extension also keeps
# the core presentation-neutral (notes 08 invariant: core bakes in no downstream consumer).

"""
    documenter_embed(url; height=nothing, min_height=420, title="Pinax gallery",
                     id=nothing, new_tab=true, style="") -> String
    documenter_embed(url, format::Documenter.HTML; page, kwargs...) -> String

Return a Documenter ````@raw html```` block that embeds a rendered, self-contained Pinax gallery — its
entry HTML at `url` — as an **auto-resizing, same-origin `<iframe>`**: the loose Pinax → Documenter
bridge (roadmap 07; *not* a Documenter plugin). Drop the returned string into a Documenter markdown
page (or a Literate `@raw html` postprocess) and the Pinax page renders **as-is** inside the Documenter
site — iframe isolation keeps the gallery's `body`/`h1`/`nav`/`figure` CSS and its KaTeX + interactive
JS from colliding with Documenter's, and the iframe grows to its content (no inner scrollbar),
re-fitting on in-gallery navigation and after KaTeX/image layout.

- `url` is the gallery's `index.html` (or a single `<page>.html`) **relative to the built Documenter
  page** — e.g. `"../gallery/"` for a top-level page under `prettyurls`.
- The 2-arg `format::Documenter.HTML` form takes `url` **relative to the site root** plus the page's
  src-relative `.md` path `page=`, and derives the correct `../` prefix from `format.prettyurls`, so
  you write the path once and it stays correct under either `prettyurls` setting.

Requires `using Documenter` (the bridge is a package extension). Render the gallery with
`render`/`report` as usual — this only wraps its URL; it neither computes nor moves the gallery.
"""
function documenter_embed(args...; kwargs...)
    return error(
        "Pinax.documenter_embed needs Documenter loaded — add `using Documenter`. It returns an " *
        "`@raw html` <iframe> block that embeds a rendered Pinax gallery in a Documenter page " *
        "(the loose bridge — not a Documenter plugin; see roadmap 07).",
    )
end

"""
    documenter_gallery(jl; out, src, workdir=dirname(jl), prepare=nothing, theme=:gallery,
                       format=nothing, page="", reset=true, kwargs...) -> (; dir, siteroot, embed)

The **source-seam** bridge: hand it a Pinax manuscript `.jl` (the *pre-render* script —
`@page`/`@section`/`@figure`/`@desc`/…) and it RUNS the script at docs-build time (in a throwaway
module, with `workdir` as the working directory so the manuscript's relative figure paths and data
resolve), renders the resulting gallery into `out` **under the Documenter source `src`** — so
`makedocs` copies it verbatim into the deployed site — and returns the wiring for one call from
`.jl` to a deployed Documenter page.

Returns `(; dir, siteroot, embed)`: `dir` is the rendered gallery directory (`joinpath(src, out)`),
`siteroot` its site-root URL (`"out/"`), and `embed` an `@raw html` iframe block for it (empty unless
BOTH `format::Documenter.HTML` and the embedding page's src-relative `page` are given, which make the
url prettyurls-correct). Pass `embed` into a Documenter page (or `documenter_embed` yourself off
`siteroot`). Extra `kwargs` forward to `documenter_embed` (`title`, `height`, `min_height`, …).

`prepare` is a zero-arg callback run BEFORE the manuscript — the seam for the **figure workaround**: a
deploy env (CI) has no access to figures/data that live only on your machine, so stage them here
(fetch a release/branch/artifact, copy committed assets into `workdir`, …). Computed figures
(`@figure plot(...)`) simply recompute; only local-only files/data need `prepare`. `reset=true` gives
the manuscript a fresh implicit document; the manuscript need not call `render` — this does.

Requires `using Documenter`.
"""
function documenter_gallery(args...; kwargs...)
    return error(
        "Pinax.documenter_gallery needs Documenter loaded — add `using Documenter`. It runs a Pinax " *
        "manuscript `.jl`, renders its gallery under the Documenter source, and returns the embed " *
        "wiring — the source-seam `.jl` → deployed page bridge (roadmap 07).",
    )
end

"""
    documenter_stage(gallery; src, out, format=nothing, page="", clean=true, kwargs...)
        -> (; dir, siteroot, embed, assets)

Carry an **already-rendered** Pinax gallery `gallery` (an `out=` directory from a prior `render` /
`report`) into the Documenter source tree at `joinpath(src, out)`, so `makedocs` copies it — and all
its assets, **PDFs included** — into the deployed site. This is the bundling path for the common
reality that Pinax + DataVault outputs live in **gitignore'd local directories**: render locally
where the data is, then `documenter_stage` the result into the docs at build time (no commit of the
raw outputs needed).

Returns the same wiring as `documenter_gallery` — `(; dir, siteroot, embed, assets)` — where `assets`
is `rendered_assets(dir)` (the identified output paths). `clean=true` replaces any existing `dir`.
Requires `using Documenter`.
"""
function documenter_stage(args...; kwargs...)
    return error(
        "Pinax.documenter_stage needs Documenter loaded — add `using Documenter`. It copies an " *
        "already-rendered gallery into the Documenter source so makedocs deploys its assets (PDFs " *
        "included) — the bundling path for gitignore'd local outputs.",
    )
end

"""
    documenter_downloads(res, format::Documenter.HTML; page, ext="pdf", label=basename, heading="")
        -> String

An `@raw html` block of **download links** to a staged gallery's asset files — by default its PDFs —
for a Documenter page. `res` is the NamedTuple from `documenter_gallery` / `documenter_stage`; each
matching asset (identified via `rendered_assets(res.dir)`) becomes an `<a download>` whose URL is
resolved against the embedding `page` using `format.prettyurls` (so it is correct under either
setting). `label` maps an asset path to its link text; `heading` is an optional bold lead line.
Empty string if the gallery has no matching asset. Requires `using Documenter`.
"""
function documenter_downloads(args...; kwargs...)
    return error(
        "Pinax.documenter_downloads needs Documenter loaded — add `using Documenter`. It emits an " *
        "`@raw html` list of download links to a staged gallery's assets (PDFs by default).",
    )
end
