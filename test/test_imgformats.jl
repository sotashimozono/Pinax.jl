using Pinax
using Test

# A file-path @figure with a raster / animated-raster extension (gif / webp / apng / …) is embedded
# inline as <img> so the browser plays the animation (e.g. an Ising-dynamics gif) — not offered as a
# bare download link. A non-image file still falls back to a download link.
@testset "raster + animated image figures render inline as <img>" begin
    tmp = mktempdir()
    site(n) = joinpath(tmp, n)
    gif = joinpath(tmp, "anim.gif")
    write(gif, "GIF89a")                       # content is irrelevant; the emitter keys off the ext
    webp = joinpath(tmp, "p.webp")
    write(webp, "RIFF____WEBP")
    txt = joinpath(tmp, "data.txt")
    write(txt, "not an image")

    Pinax.reset!()
    @page :p "P" begin
        @section :s "S" begin
            @figure gif
            @figure webp
            @figure txt
        end
    end
    html = read(Pinax.render(; out=site("img")), String)
    @test occursin(r"<img src=\"[^\"]+\.gif\"", html)    # gif inline (animation plays)
    @test occursin(r"<img src=\"[^\"]+\.webp\"", html)   # webp inline
    @test !occursin(r"<img src=\"[^\"]+\.txt\"", html)   # a non-image is never an <img>
    @test occursin(r"<a href=\"[^\"]+\.txt\">", html)    # …it stays a download link
end
