# Pinax test-capture preamble — loaded via `julia -L` into a `Pkg.test` subprocess by the delegating
# `Pinax.test()` (see `Pinax.test` in src/testset.jl and `_install_test_capture!` in PinaxTestExt).
#
# It runs at depth 0, BEFORE `Pkg.test`'s `include(runtests.jl)`, and installs a capturing root testset
# so the suite's plain `@testset` tree is captured and rendered at exit — and does nothing else, so
# `Pkg.test` is otherwise untouched (invariant V′). This file is NOT part of the Pinax module; it is a
# standalone script referenced by path.
#
# A `-L` file runs in EVERY `Pkg.test` subprocess, including the precompile ones (`--output-*`), where
# even `using` would create a global and break the cache image. Guard the whole body on
# `generating_output()` so those subprocesses run it as a no-op; only the real test run installs.
if !Base.generating_output()
    using Pinax, Test
    Pinax._install_test_capture!()
end
