# Test report

### Test report  [id: overview]
_5/5 passed · 0.35s_

_Per-file result profile. `worst margin` is the largest `delta/tol` seen in that file: 1.0 means a check landed exactly on its tolerance._  [table: per_file]
| file | tests | passed | failed | errored | seconds | worst_margin |
| --- | --- | --- | --- | --- | --- | --- |
| margins.jl | 4 | 4 | 0 | 0 | 0.17 |  |
| recovery.jl | 1 | 1 | 0 | 0 | 0.02 | 0.379 |

### margins.jl  [id: margins_jl]  [status: benchmark]
**margins.jl   4/4 PASS**
_4/4 passed · 0.17s_
A `Check` keeps `got` / `want` / `tol`, so the report shows the *margin* each test
passed by. The two checks below both pass, but one is a refactor from red and the
other is rock-solid — indistinguishable on a green badge, obvious here.
- [PASS] t1 — solid.pass: got 1.0, want 1.0 (Δ 0.0 vs tol 0.5 abs)
- [PASS] t2 — solid.delta / solid.tol < 0.1: got 1.0, want 1.0 (Δ 0.0 vs tol 0.5 abs)
- [PASS] t3 — tight.pass: got 1.0, want 1.0 (Δ 0.0 vs tol 0.5 abs)
- [PASS] t4 — tight.delta / tight.tol > 0.9: got 1.0, want 1.0 (Δ 0.0 vs tol 0.5 abs)
- [fig: margins_jl_margins] Tolerance budget spent by each check. The dashed line is the pass/fail boundary — a bar close to it passed, but barely.
  - asset: ../test2pinax_html/assets/figures/margins_jl/margins_jl_margins.svg

| series | x | y |
| --- | --- | --- |
| margin | 1 | 0.0 |
| margin | 2 | 0.0 |
| margin | 3 | 0.0 |
| margin | 4 | 0.0 |
| pass/fail boundary | 1 | 1.0 |
| pass/fail boundary | 2 | 1.0 |
| pass/fail boundary | 3 | 1.0 |
| pass/fail boundary | 4 | 1.0 |

### recovery.jl  [id: recovery_jl]  [status: benchmark]
**recovery.jl   1/1 PASS**
_1/1 passed · 0.02s_
An `@test isapprox(got, want; rtol)` is enough — the bridge recovers the numbers the
             assertion actually compared, so the page is legible with no figure code at all.
- [PASS] t5 — isapprox(-0.10203402715213993, -0.10242223073749557; rtol = 0.01): got -0.10203402715213993, want -0.10242223073749557 (Δ 0.0037902277909821567 vs tol 0.01 rel)
- [fig: recovery_jl_margins] Tolerance budget spent by each check. The dashed line is the pass/fail boundary — a bar close to it passed, but barely.
  - asset: ../test2pinax_html/assets/figures/recovery_jl/recovery_jl_margins.svg

| series | x | y |
| --- | --- | --- |
| margin | 1 | 0.37902277909821563 |
| pass/fail boundary | 1 | 1.0 |
