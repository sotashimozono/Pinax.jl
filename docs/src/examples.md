# Examples

This section is a small catalogue of galleries built with Pinax. Every example follows the **same
Pinax workflow** — compute something, describe a manuscript with `@page` / `@section` / `@figure`,
then `render` it into a self-contained gallery you can open and share.

## Map of contents

A table of contents across **every compiled gallery** — like a LaTeX `\tableofcontents`, but
spanning all the rendered galleries. Click a section to jump straight into it; click a gallery title
to open the whole thing.

```@raw html
<style>
  .pinax-toc, .pinax-toc ol { list-style: none; }
  .pinax-toc { counter-reset: g; padding-left: 0; line-height: 1.7; }
  .pinax-toc > li { counter-increment: g; margin-top: .5rem; font-weight: 600; }
  .pinax-toc > li::before { content: counter(g) ".  "; color: #57606a; }
  .pinax-toc > li > ol { counter-reset: s; padding-left: 1.6rem; }
  .pinax-toc > li > ol > li { counter-increment: s; font-weight: 400; }
  .pinax-toc > li > ol > li::before { content: counter(g) "." counter(s) "   "; color: #8b949e; }
  .pinax-toc a { text-decoration: none; }
</style>
<ol class="pinax-toc">
  <li><a href="galleries/attractors/">Chaotic attractors</a>
    <ol>
      <li><a href="galleries/attractors/#lorenz">Lorenz</a></li>
      <li><a href="galleries/attractors/#rossler">Rössler</a></li>
    </ol>
  </li>
  <li><a href="galleries/lsystems/">L-system fractals</a>
    <ol>
      <li><a href="galleries/lsystems/#koch">Koch &amp; Sierpiński</a></li>
      <li><a href="galleries/lsystems/#curves">Dragons, space-filling &amp; plants</a></li>
    </ol>
  </li>
  <li><a href="galleries/ising/">Ising model (Monte Carlo)</a>
    <ol>
      <li><a href="galleries/ising/#snapshots">Spin configurations</a></li>
      <li><a href="galleries/ising/#magnetization">Magnetization curve</a></li>
    </ol>
  </li>
</ol>
```

## Walkthroughs

Each example page shows the source and a step-by-step walkthrough, and links to its compiled
gallery:

- [1 · Chaotic attractors](examples/attractors.md) — [DynamicalModels.jl](https://github.com/sotashimozono/DynamicalModels.jl)
- [2 · L-system fractals](examples/lsystems.md) — [LSystems.jl](https://github.com/sotashimozono/LSystems.jl)
- [3 · Ising model (Monte Carlo)](examples/ising.md) — self-contained
