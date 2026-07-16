# Test report

### Test report  [id: overview]
_3/3 passed · 1.1s_

_Per-file result profile. `worst margin` is the largest `delta/tol` seen in that file: 1.0 means a check landed exactly on its tolerance._  [table: per_file]
| file | tests | passed | failed | errored | seconds | worst_margin |
| --- | --- | --- | --- | --- | --- | --- |
| test_energy.jl | 2 | 2 | 0 | 0 | 1.03 | 0.975 |
| test_magnetisation.jl | 1 | 1 | 0 | 0 | 0.0 | 0.225 |

### test_energy.jl  [id: test_energy_jl]  [status: benchmark]
**test_energy.jl   2/2 PASS**
_2/2 passed · 1.03s_
Ground-state observables of the demo model against the exact reference.
- [PASS] t1 — isapprox(-1.2731, -1.2735; rtol = 0.01): got -1.2731, want -1.2735 (Δ 0.0003140950137417966 vs tol 0.01 rel)
- [PASS] t2 — isapprox(0.4122, 0.4102; rtol = 0.005): got 0.4122, want 0.4102 (Δ 0.004875670404680648 vs tol 0.005 rel)
- [fig: test_energy_jl_margins] Tolerance budget spent by each check. The dashed line is the pass/fail boundary — a bar close to it passed, but barely.
  - asset: ../test2pinax_html/assets/figures/test_energy_jl/test_energy_jl_margins.svg

| series | x | y |
| --- | --- | --- |
| margin | 1 | 0.03140950137417966 |
| margin | 2 | 0.9751340809361295 |
| pass/fail boundary | 1 | 1.0 |
| pass/fail boundary | 2 | 1.0 |

### test_magnetisation.jl  [id: test_magnetisation_jl]  [status: benchmark]
**test_magnetisation.jl   1/1 PASS**
_1/1 passed · 0.0s_
- [PASS] t3 — isapprox(0.6664, 0.6667; rtol = 0.002): got 0.6664, want 0.6667 (Δ 0.00044997750112489424 vs tol 0.002 rel)
- [fig: test_magnetisation_jl_margins] Tolerance budget spent by each check. The dashed line is the pass/fail boundary — a bar close to it passed, but barely.
  - asset: ../test2pinax_html/assets/figures/test_magnetisation_jl/test_magnetisation_jl_margins.svg

| series | x | y |
| --- | --- | --- |
| margin | 1 | 0.2249887505624471 |
| pass/fail boundary | 1 | 1.0 |
