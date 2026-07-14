# examples/finitetemperature_demo.jl — a side-by-side "feel" demo: reproduce a couple of
# FiniteTemperature.jl `build_report` gallery sections as a Pinax manuscript.
#
# Run:  julia --project=. examples/finitetemperature_demo.jl
# Out:  out/ft_demo/index.html  (a Pinax gallery of the real Phase-1 figures, if present)
#
# ──────────────────────────────────────────────────────────────────────────────────────────
# build_report.jl (the "before") declares each section across TWO parallel const tables plus a
# ~68 KB hand-rolled HTML builder:
#
#   const SUBSECS = [ ("thermal","eq_energy","エネルギー … (N×g)","phase1_vs_qatlas","energy_",""), … ]
#   const SECDESC = Dict("eq_energy" => raw\"\"\"<div class="row"><span class="label">意図</span> …</div>
#                                              <div class="formula">$$ … $$</div> …\"\"\", … )
#   # then a builder globs dir/prefix, computes EQ/GQ pid badges, and prints nav + <iframe> grids +
#   # the comment toolbar + coverage tables, all as raw HTML strings.
#
# Pinax (the "after", below): the section id, label, description and figures live together; the
# description is markdown (not <div class="row"> soup); EQ/GQ numbering is a one-line numberer;
# the comment layer, figure counts, KaTeX and PDF embedding come for free.
# ──────────────────────────────────────────────────────────────────────────────────────────

using Pinax

# Locate the real FiniteTemperature Phase-1 figures (this repo layout); fall back to stubs so the
# demo runs anywhere.
const PKG = pkgdir(Pinax)
const FIGDIR =
    let real = normpath(
            joinpath(
                PKG,
                "..",
                "..",
                "apps",
                "FiniteTemperature.jl",
                "out",
                "figure",
                "phase1_vs_qatlas",
            ),
        )
        if isdir(real)
            real
        else
            d = mktempdir()
            for nm in (
                "energy_N24_g0.5",
                "energy_N64_g1.0",
                "energy_dev_N24_g0.5",
                "cv_N24_g0.5",
                "cv_dev_N24_g0.5",
            )
                write(
                    joinpath(d, nm * ".pdf"),
                    "%PDF-1.4\n% stub for $(nm) (real FiniteTemperature figures not found)\n",
                )
            end
            @info "FiniteTemperature figures not found; using stubs in $d"
            d
        end
    end

function figs(prefix)
    return sort(filter(f -> startswith(f, prefix) && endswith(f, ".pdf"), readdir(FIGDIR)))
end

# EQ1.. on the thermal page, GQ1.. on a quench page (part = page; #20). numbering=:page resets per page.
nb(kind, c) =
    if kind === :section
        (c.page_id === :eq ? "EQ$(c.section)" : "GQ$(c.section)")
    else
        kind === :figure ? "Fig. $(c.figure)" : "($(c.equation))"
    end

Pinax.reset!(;
    title="FiniteTemperature.jl — TPQ-MPS gallery (Pinax demo)",
    numbering=:page,
    numberer=nb,
    katex=:cdn,
)

@page :eq "熱平衡 — Thermal Equilibrium" begin
    @section :setup "Setup & データ俯瞰" begin
        @desc md"""
        **Hamiltonian** TFIML (横磁場 Γ + 縦磁場 h の Ising), OBC:

        $$ H = -J\sum_i \sigma^z_i\sigma^z_{i+1} - \Gamma\sum_i \sigma^x_i - h\sum_i \sigma^z_i,\qquad J=1,\ \Gamma=g. $$

        **protocol** 熱平衡: 虚時間発展で TPQ-MPS を構築 (Iwaki–Shimizu–Hotta, volume-law).
        """
        # project-specific UI (a broken-data banner / coverage table) that markdown can't express:
        @raw raw"""<div style="border-left:4px solid #d33;background:#fff5f5;padding:.5rem .8rem">
        ⚠ <b>除外データ</b>: χ=80 の虚時間 run は β=10 で中断・不整合。健全なのは N64 g0.5 χ=80 のみ。</div>"""
    end

    @section :eq_energy "エネルギー E/N vs T — 厳密解比較 (N×g)" begin
        @desc md"""
        **意図** エネルギー密度 E/N の逆温度 β 依存を、χ 収束を見ながら QAtlas 解析解 (Jordan–Wigner, OBC, 有限 N) と比較。先行研究の再現 = 道具の検証。

        **測定** E は TPQ 期待値。100 サンプルを nfpf $=\ln\langle\psi_\beta|\psi_\beta\rangle$ の log 重みで集約:

        $$ E=\langle H\rangle=\frac{\langle\psi_\beta|H|\psi_\beta\rangle}{\langle\psi_\beta|\psi_\beta\rangle}. $$

        **解析** 各 (N,g) で χ∈{10,20,30,40,60,80} を重畳。黒破線 = 厳密 (OBC, 有限 N)、灰点線 = 厳密 (N→∞)。残差図 (…_dev_…) で χ 収束を定量化。

        > ⚠ 低温・大 N は固定 χ の切断で残差が増える (体積則 EE が 2 ln χ を超える) — 既知の挙動。
        """
        for f in figs("energy_")
            @figure joinpath(FIGDIR, f)
            @caption f
        end
    end

    @section :eq_cv "比熱 Cv vs T — 厳密解比較 (N×g)" begin
        @desc md"""
        **意図** 比熱 Cv/N の β 依存と χ 収束を解析解 (OBC) と比較。Cv ピーク = 熱的クロスオーバー温度。

        **測定** 量子分散 $C_v/N=\frac{\beta^2}{N}\langle\Delta H^2\rangle$, $\langle\Delta H^2\rangle=\langle H^2\rangle-\langle H\rangle^2$.
        """
        for f in figs("cv_")
            @figure joinpath(FIGDIR, f)
            @caption f
        end
    end
end

const OUT = joinpath(PKG, "out", "ft_demo")
const COMMENTS = joinpath(OUT, "comments.toml")

# Seed one comment to show the LLM⇄me⇄teacher layer rendering co-located with the figure.
Pinax.add_comment(
    COMMENTS,
    :eq_energy,
    "残差が低温で増えるのは 2 ln χ 律速と整合。χ=80 の broken run に注意。";
    author="llm",
)

path = Pinax.render(; out=OUT, comments_file=COMMENTS)
println("rendered: ", path)
println("figures (energy): ", length(figs("energy_")), "  (cv): ", length(figs("cv_")))

# PDF export of the same manuscript (a .tex, compiled to PDF if latexmk/pdflatex is present):
texpath = Pinax.render(;
    out=joinpath(PKG, "out", "ft_demo_tex"), theme=:latex, comments_file=COMMENTS
)
println("latex:    ", texpath)
