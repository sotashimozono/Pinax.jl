# serve.jl — a tiny static-file HTTP server to preview a rendered gallery (Sockets stdlib only).
#
# `Pinax.serve("out/site")` serves the directory at http://localhost:8000 so you open a link and view
# the gallery in a browser. Over http:// the PDF `<iframe>`s and the comment layer behave better than
# over `file://`, and the URL can be port-forwarded to share with an advisor. Blocks until Ctrl-C;
# `blocking=false` returns a handle (`(; server, url, port, task)`) for tests / programmatic use.

const _MIME = Dict(
    ".html" => "text/html; charset=utf-8",
    ".css" => "text/css; charset=utf-8",
    ".js" => "text/javascript; charset=utf-8",
    ".json" => "application/json; charset=utf-8",
    ".toml" => "text/plain; charset=utf-8",
    ".md" => "text/plain; charset=utf-8",
    ".svg" => "image/svg+xml",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".pdf" => "application/pdf",
    ".woff2" => "font/woff2",
    ".woff" => "font/woff",
    ".ttf" => "font/ttf",
)
_mime(path) = get(_MIME, lowercase(splitext(path)[2]), "application/octet-stream")

# Minimal percent-decoding of a request target (`%20` etc.).
function _urldecode(s::AbstractString)
    out = IOBuffer()
    bytes = codeunits(s)
    i = 1
    n = length(bytes)
    while i <= n
        b = bytes[i]
        if b == UInt8('%') && i + 2 <= n
            hi = tryparse(UInt8, String(bytes[(i + 1):(i + 2)]); base=16)
            if hi !== nothing
                write(out, hi)
                i += 3
                continue
            end
        end
        write(out, b)
        i += 1
    end
    return String(take!(out))
end

function _respond(conn, status, ct, body; extra=String[])
    reason = if status == 200
        "OK"
    elseif status == 206
        "Partial Content"
    elseif status == 404
        "Not Found"
    elseif status == 403
        "Forbidden"
    else
        "OK"
    end
    head = [
        "HTTP/1.1 $status $reason", "Content-Type: $ct", "Content-Length: $(length(body))"
    ]
    append!(head, extra)
    push!(head, "Connection: close", "", "")
    write(conn, join(head, "\r\n"))
    write(conn, body)
    return nothing
end

# Serve one request: GET <target> -> file under `root`, with MIME, single-range (PDF byte-serving),
# path-traversal protection, and 404 for misses.
function _serve_handle(conn, root)
    try
        reqline = readline(conn)
        isempty(reqline) && return nothing
        parts = split(reqline)
        length(parts) >= 2 || return nothing
        target = parts[2]
        rangehdr = ""
        while true
            h = readline(conn)
            isempty(h) && break
            if startswith(lowercase(h), "range:")
                rangehdr = strip(h[(findfirst(':', h) + 1):end])
            end
        end
        rel = lstrip(_urldecode(split(target, '?')[1]), '/')
        isempty(rel) && (rel = "index.html")
        file = normpath(joinpath(root, rel))
        if !startswith(file, root)                       # no escaping the served root
            return _respond(conn, 403, "text/plain", Vector{UInt8}("403 Forbidden"))
        end
        isdir(file) && (file = joinpath(file, "index.html"))
        if !isfile(file)
            return _respond(conn, 404, "text/plain", Vector{UInt8}("404 Not Found: $(rel)"))
        end
        data = read(file)
        ct = _mime(file)
        m = isempty(rangehdr) ? nothing : match(r"^bytes=(\d*)-(\d*)$", rangehdr)
        if m !== nothing                                  # single-range request (e.g. PDF viewer)
            n = length(data)
            lo = isempty(m.captures[1]) ? 0 : parse(Int, m.captures[1])
            hi = isempty(m.captures[2]) ? n - 1 : parse(Int, m.captures[2])
            lo = clamp(lo, 0, max(n - 1, 0))
            hi = clamp(hi, lo, max(n - 1, 0))
            return _respond(
                conn,
                206,
                ct,
                data[(lo + 1):(hi + 1)];
                extra=["Content-Range: bytes $(lo)-$(hi)/$(n)", "Accept-Ranges: bytes"],
            )
        end
        return _respond(conn, 200, ct, data; extra=["Accept-Ranges: bytes"])
    catch e
        e isa InterruptException && rethrow()
        return nothing                                    # client closed / malformed: drop it
    finally
        close(conn)
    end
end

function _listen_any(addr, port)
    for p in port:(port + 20)
        try
            return Sockets.listen(addr, p), p
        catch e
            e isa Base.IOError || rethrow()              # port busy -> try the next
        end
    end
    return error("Pinax.serve: no free port in $(port)..$(port + 20)")
end

"""
    serve(dir="out"; host="localhost", port=8000, blocking=true) -> nothing | handle

Serve the rendered gallery in `dir` over HTTP so you can open the printed link in a browser. Picks
the next free port from `port` if it is busy. Blocks until interrupted (Ctrl-C); with
`blocking=false` it returns `(; server, url, port, task)` and you `close(handle.server)` to stop.
"""
function serve(
    dir::AbstractString="out";
    host::AbstractString="localhost",
    port::Integer=8000,
    blocking::Bool=true,
)
    root = normpath(abspath(dir))
    isfile(joinpath(root, "index.html")) ||
        @warn "Pinax.serve: no index.html in $(root) — render there first?"
    server, p = _listen_any(Sockets.getaddrinfo(host), port)
    url = "http://$(host):$(p)/"
    accept_loop = function ()
        while true
            conn = try
                Sockets.accept(server)
            catch
                break                                     # server closed
            end
            @async _serve_handle(conn, root)
        end
    end
    if blocking
        # Print the URL as a bare token on its own line so the terminal makes it clickable.
        println()
        printstyled("  Pinax gallery  →  "; bold=true)
        printstyled(url, "\n"; bold=true, color=:cyan)
        println("  open the link in a browser  ·  serving $(root)  ·  Ctrl-C to stop\n")
        flush(stdout)   # show the link immediately, even when stdout is piped/redirected
        try
            accept_loop()
        catch e
            e isa InterruptException || rethrow()
        finally
            close(server)
        end
        return nothing
    end
    return (; server=server, url=url, port=p, task=@async accept_loop())
end
