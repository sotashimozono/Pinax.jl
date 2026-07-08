module PinaxDocumenterExt

# Documenter bridge for Pinax (roadmap 07). Loaded automatically when both Pinax and Documenter are
# imported. Wraps a rendered, self-contained Pinax gallery in an `@raw html`, auto-resizing <iframe>
# so a Pinax page embeds AS-IS into a Documenter site — a LOOSE bridge, NOT a Documenter plugin
# (notes 07: the two models differ; keep them decoupled). There are no Documenter pipeline / Selector /
# Expander hooks: the only contract is "emit an `@raw html` string that a Documenter page passes
# through verbatim", which keeps this robust across Documenter versions.

using Pinax
using Documenter: Documenter

# Escape a value for an HTML attribute (the url / title go into `src="…"` / `title="…"`).
function _attr(s)
    return replace(
        string(s),
        '&' => "&amp;",
        '"' => "&quot;",
        '<' => "&lt;",
        '>' => "&gt;",
        '\'' => "&#39;",
    )
end

# A DOM-id-safe slug of the url, so two embeds on one page get distinct iframe ids by default.
function _slug(s)
    t = strip(replace(lowercase(string(s)), r"[^a-z0-9]+" => "-"), '-')
    return isempty(t) ? "x" : t
end

# The iframe's inline height style: a fixed `height=` (Int → px, or a CSS string like "80vh") pins it;
# otherwise the auto-resize script drives the height and `min_height` is just the pre-load floor.
_height_style(height::Integer, _) = string("height:", Int(height), "px")
_height_style(height::AbstractString, _) = string("height:", height)
_height_style(::Nothing, min_height) = string("min-height:", Int(min_height), "px")

# The "open in a new tab" fallback link shown above the iframe (empty when `new_tab=false`).
function _open_link(url, new_tab::Bool)
    new_tab || return ""
    return string(
        "<p style=\"margin:.3rem 0 .6rem;font-size:.95rem\"><a href=\"",
        _attr(url),
        "\" target=\"_blank\" rel=\"noopener\"><b>▶ Open the gallery in a new tab</b></a></p>\n",
    )
end

function Pinax.documenter_embed(
    url::AbstractString;
    height=nothing,
    min_height::Integer=420,
    title::AbstractString="Pinax gallery",
    id=nothing,
    new_tab::Bool=true,
    style::AbstractString="",
)
    fid = id === nothing ? string("pinax-embed-", _slug(url)) : string(id)
    hstyle = _height_style(height, min_height)
    extra = isempty(style) ? "" : string(";", style)
    open_link = _open_link(url, new_tab)
    # Auto-resize a SAME-ORIGIN iframe to its content: fit on load and on every content-size change
    # (KaTeX render, image load, in-gallery navigation). Cross-origin access throws → we keep
    # `min-height`. The script is inline so the block is self-contained (no external asset needed).
    return string(
        "```@raw html\n",
        open_link,
        "<iframe id=\"",
        fid,
        "\" src=\"",
        _attr(url),
        "\" title=\"",
        _attr(title),
        "\" loading=\"lazy\" scrolling=\"no\" ",
        "style=\"width:100%;border:0;",
        hstyle,
        ";display:block",
        extra,
        "\"></iframe>\n",
        "<script>\n",
        "(function(){var f=document.getElementById(\"",
        fid,
        "\");if(!f)return;",
        "function fit(){try{var d=f.contentWindow.document;",
        "var h=Math.max(d.documentElement.scrollHeight,d.body?d.body.scrollHeight:0);",
        "if(h)f.style.height=h+\"px\";}catch(e){}}",
        "f.addEventListener(\"load\",function(){fit();",
        "try{new ResizeObserver(fit).observe(f.contentWindow.document.documentElement);}catch(e){}",
        "setTimeout(fit,150);setTimeout(fit,600);});",
        "window.addEventListener(\"resize\",fit);})();\n",
        "</script>\n",
        "```\n",
    )
end

# Documenter-aware entry: `url` is given relative to the SITE ROOT (e.g. "gallery/"); resolve it
# against the built `page` (its src-relative `.md` path) using `format.prettyurls`, then embed. Write
# the root path once and it stays correct under either prettyurls setting. Uses `Documenter.HTML`.
function Pinax.documenter_embed(
    url::AbstractString, format::Documenter.HTML; page::AbstractString, kwargs...
)
    return Pinax.documenter_embed(_relativize(url, page, format.prettyurls); kwargs...)
end

# Shared wiring returned by documenter_gallery / documenter_stage: the gallery's site-root url, an
# (optional, prettyurls-correct) embed block, and the identified output assets (rendered_assets).
function _gallery_wiring(dir, out, format, page; kwargs...)
    siteroot = endswith(out, "/") ? String(out) : string(out, "/")
    embed = if format === nothing
        ""
    else
        Pinax.documenter_embed(siteroot, format; page=page, kwargs...)
    end
    return (; dir=dir, siteroot=siteroot, embed=embed, assets=Pinax.rendered_assets(dir))
end

# Source-seam bridge: run a Pinax manuscript `.jl` (pre-render), render its gallery under the
# Documenter source, and hand back the embed wiring — "`.jl` → deployed page" in one call.
function Pinax.documenter_gallery(
    jl::AbstractString;
    out::AbstractString,
    src::AbstractString,
    workdir::AbstractString=dirname(abspath(jl)),
    prepare=nothing,
    theme=:gallery,
    format=nothing,
    page::AbstractString="",
    reset::Bool=true,
    kwargs...,
)
    isfile(jl) || error("Pinax.documenter_gallery: manuscript not found: $(jl)")
    # (1) stage local-only figures/data the deploy env lacks — the figure workaround seam.
    prepare === nothing || prepare()
    # The gallery goes under the Documenter source so makedocs copies it to the site; keep it ABSOLUTE
    # since we render from inside `workdir` (below).
    galdir = abspath(isabspath(out) ? String(out) : joinpath(src, out))
    mkpath(galdir)
    jlabs = abspath(jl)
    reset && Pinax.reset!()
    # (2+3) run the manuscript AND render with `workdir` as CWD. `@figure`'s generator is DEFERRED to
    #       render time, so the manuscript's relative figure paths / data reads must resolve against
    #       `workdir` at BOTH include and render — hence render inside the same `cd`. The macros push
    #       to Pinax's implicit global document, so `current_document()` holds the manuscript.
    cd(workdir) do
        Base.include(Module(gensym(:PinaxManuscript)), jlabs)
        return Pinax.render(Pinax.current_document(); out=galdir, theme=theme)
    end
    # (4) wiring: site-root url + a prettyurls-correct embed (when format+page given) + the identified
    #     output assets (rendered_assets — PDFs included).
    return _gallery_wiring(galdir, out, format, page; kwargs...)
end

# B: carry an ALREADY-rendered gallery (typically a gitignore'd local `out=` dir) into the Documenter
# source tree, so makedocs copies it — assets/PDFs included — into the deployed site. Symmetric with
# documenter_gallery: same `(; dir, siteroot, embed, assets)` wiring, but a copy instead of a render.
function Pinax.documenter_stage(
    gallery::AbstractString;
    src::AbstractString,
    out::AbstractString,
    format=nothing,
    page::AbstractString="",
    clean::Bool=true,
    kwargs...,
)
    isdir(gallery) || error("Pinax.documenter_stage: not a directory: $(gallery)")
    isfile(joinpath(gallery, "index.html")) || error(
        "Pinax.documenter_stage: $(gallery) has no index.html — is it a rendered Pinax gallery?",
    )
    dest = abspath(isabspath(out) ? String(out) : joinpath(src, out))
    clean && ispath(dest) && rm(dest; recursive=true, force=true)
    mkpath(dirname(dest))
    cp(gallery, dest; force=true)   # whole tree: index.html + assets (svg/pdf/…) + style.css/app.js
    return _gallery_wiring(dest, out, format, page; kwargs...)
end

# C: an `@raw html` list of download links to a staged gallery's assets (PDFs by default), with
# prettyurls-correct URLs. `res` is the wiring from documenter_gallery / documenter_stage.
function Pinax.documenter_downloads(
    res::NamedTuple,
    format::Documenter.HTML;
    page::AbstractString,
    ext="pdf",
    label=basename,
    heading::AbstractString="",
)
    files = Pinax.rendered_assets(res.dir; ext=ext)
    isempty(files) && return ""
    io = IOBuffer()
    print(io, "```@raw html\n")
    isempty(heading) ||
        print(io, "<p style=\"margin:.4rem 0 .2rem\"><b>", _attr(heading), "</b></p>\n")
    print(io, "<ul class=\"pinax-downloads\">\n")
    for a in files
        url = _relativize(string(res.siteroot, a), page, format.prettyurls)
        print(
            io, "<li><a href=\"", _attr(url), "\" download>", _attr(label(a)), "</a></li>\n"
        )
    end
    print(io, "</ul>\n```\n")
    return String(take!(io))
end

# Prefix a site-root path with the right number of `../` to reach it from the built `page`. prettyurls
# maps `a/b.md` → `a/b/index.html` (page dir sits `#segments` levels below root); otherwise `a/b.md` →
# `a/b.html` (page dir sits `#segments - 1` levels below root). An `index.md` keeps its directory's
# level (it is already the dir's index under prettyurls). An already-root-absolute `/…` url is left be.
function _relativize(url::AbstractString, page::AbstractString, prettyurls::Bool)
    startswith(url, '/') && return url
    p = replace(page, '\\' => '/')
    p = endswith(lowercase(p), ".md") ? p[1:(end - 3)] : p
    segs = filter(!isempty, split(p, '/'))
    isempty(segs) && return url
    base_is_dir = prettyurls && lowercase(String(last(segs))) != "index"
    depth = length(segs) - 1 + (base_is_dir ? 1 : 0)
    return string(repeat("../", max(depth, 0)), url)
end

end # module PinaxDocumenterExt
