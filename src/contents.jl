# contents.jl — a standalone "map of contents": a meta-index that spans several independently
# rendered galleries. Where the gallery index links to the pages *within* one gallery, this links
# *across* galleries — each entry points at another gallery's `index.html`, one level up. It reuses
# the gallery card/toc CSS (`_GALLERY_CSS`) so the meta-index looks like a per-gallery index, but is
# otherwise a light, self-contained page (no KaTeX, no doc tree): the targets are pre-rendered.

# Read an optional entry field; entries are NamedTuples (or anything supporting `haskey`/`get`).
_entry_get(e::NamedTuple, k::Symbol, default) = haskey(e, k) ? e[k] : default
_entry_get(e, k::Symbol, default) = get(e, k, default)

function _entry_str(e, k::Symbol)
    v = _entry_get(e, k, nothing)
    v === nothing && error("Pinax.contents: each entry needs a `$(k)` field; got $(e).")
    return string(v)
end

"""
    contents(entries; out, title="Contents", level=:cards) -> path

Render a standalone meta-index linking to several separately rendered galleries, and return the
written `index.html` path. Use it to put a customizable "map of contents" one level above galleries
that were each produced by their own [`render`](@ref) call.

Each entry is a `NamedTuple` describing one target gallery:

| field       | required | meaning                                                       |
| ----------- | :------: | ------------------------------------------------------------- |
| `title`     |   yes    | gallery name (card title)                                     |
| `href`      |   yes    | link to that gallery's `index.html` (relative path or URL)    |
| `summary`   |    no    | one-line description                                          |
| `thumbnail` |    no    | image path/URL for the card thumbnail (referenced as-is)      |
| `meta`      |    no    | small caption line, e.g. `"12 pages · 540 figures"`           |
| `items`     |    no    | `Vector{<:AbstractString}` listed under the summary at `:rich` |

`level` mirrors the gallery index verbosity: `:toc` (link list), `:cards` (thumbnail cards,
default), `:rich` (cards + each entry's `items`). Hrefs and thumbnails are referenced as given — the
targets are expected to already exist relative to `out`; this neither renders the galleries nor
copies their assets.

```julia
Pinax.contents(
    [
        (; title="Thermal", href="thermal/index.html",
           summary="Equilibrium TPQ", thumbnail="thermal/assets/figures/cv.svg"),
        (; title="Quench", href="quench/index.html", summary="Global-quench dynamics"),
    ];
    out="site", title="Project Atlas",
)
```
"""
function contents(
    entries; out::AbstractString, title::AbstractString="Contents", level::Symbol=:cards
)
    level in (:toc, :cards, :rich) ||
        error("Pinax.contents: level must be :toc, :cards, or :rich (got :$(level)).")
    es = collect(entries)
    mkpath(out)
    io = IOBuffer()
    print(io, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">")
    print(io, "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    print(io, "<title>", _esc(title), "</title>", _GALLERY_CSS, "</head><body>\n")
    println(io, "<h1>", _esc(title), "</h1>")
    n = length(es)
    println(
        io, "<div class=\"pinax-meta\">", n, n == 1 ? " gallery" : " galleries", "</div>"
    )
    if level === :toc
        _emit_contents_toc(io, es)
    else
        _emit_contents_cards(io, es, level === :rich)
    end
    println(io, "</body></html>")
    path = joinpath(out, "index.html")
    write(path, String(take!(io)))
    return path
end

function _emit_contents_cards(io, entries, rich::Bool)
    println(io, "<div class=\"pinax-cards\">")
    for e in entries
        thumb = _entry_get(e, :thumbnail, nothing)
        summary = _entry_get(e, :summary, nothing)
        metaline = _entry_get(e, :meta, nothing)
        items = _entry_get(e, :items, nothing)
        print(io, "<a class=\"pinax-card\" href=\"", _esc(_entry_str(e, :href)), "\">")
        if thumb === nothing
            print(io, "<div class=\"card-thumb card-thumb-empty\"></div>")
        else
            print(
                io,
                "<div class=\"card-thumb\"><img src=\"",
                _esc(string(thumb)),
                "\" alt=\"\"></div>",
            )
        end
        print(
            io,
            "<div class=\"card-body\"><div class=\"card-title\">",
            _esc(_entry_str(e, :title)),
            "</div>",
        )
        summary === nothing ||
            print(io, "<div class=\"card-summary\">", _esc(string(summary)), "</div>")
        if rich && items !== nothing && !isempty(items)
            print(io, "<div class=\"card-sections\">")
            for it in items
                print(io, "<div class=\"sec-item\">", _esc(string(it)), "</div>")
            end
            print(io, "</div>")
        end
        metaline === nothing ||
            print(io, "<div class=\"card-meta\">", _esc(string(metaline)), "</div>")
        print(io, "</div></a>")
    end
    return println(io, "</div>")
end

function _emit_contents_toc(io, entries)
    println(io, "<ul class=\"pinax-toc\">")
    for e in entries
        summary = _entry_get(e, :summary, nothing)
        metaline = _entry_get(e, :meta, nothing)
        print(
            io,
            "<li><a href=\"",
            _esc(_entry_str(e, :href)),
            "\">",
            _esc(_entry_str(e, :title)),
            "</a>",
        )
        summary === nothing ||
            print(io, " <span class=\"toc-summary\">— ", _esc(string(summary)), "</span>")
        metaline === nothing ||
            print(io, " <span class=\"toc-meta\">(", _esc(string(metaline)), ")</span>")
        print(io, "</li>")
    end
    return println(io, "</ul>")
end
