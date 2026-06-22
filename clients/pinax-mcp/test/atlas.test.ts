import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { loadAtlas } from "../src/atlas.js";

// compiled to dist/test/, so the source fixture is two levels up at <pkg>/test/fixtures
const here = dirname(fileURLToPath(import.meta.url));
const fixture = resolve(here, "../../test/fixtures/sample");

test("loads any agent.json and indexes every unit by id and kind", () => {
  const atlas = loadAtlas(fixture);
  assert.equal(atlas.doc.title, "Demo Atlas");
  assert.equal(atlas.unit("grp")?.kind, "part");
  assert.equal(atlas.unit("p1")?.kind, "page");
  assert.equal(atlas.unit("s1")?.kind, "section");
  assert.equal(atlas.unit("p1_fig1")?.kind, "figure");
  // a figure's label is its caption; its parent is the containing section/page
  assert.match(atlas.unit("p1_fig1")!.label, /NamedTuple/);
  assert.equal(atlas.unit("s1_fig1")?.parent, "s1");
  assert.equal(atlas.unit("p2_fig1")?.parent, "p2");
  assert.equal(atlas.all("figure").length, 3);
});

test("outline is a generic tree over parts/pages/sections/figures", () => {
  const o = loadAtlas(fixture).outline();
  assert.match(o, /^# Demo Atlas/);
  assert.match(o, /\[part grp\]/);
  assert.match(o, /\[page p1\] Page One — overview page/);
  assert.match(o, /\[section s1\]/);
  assert.match(o, /\[figure p2_fig1\]/);
});

test("the three params shapes survive intact (object / string / null)", () => {
  const atlas = loadAtlas(fixture);
  assert.deepEqual(atlas.unit("p1_fig1")!.node.params, { N: 24, g: 0.5 }); // structured axes
  assert.equal(atlas.unit("s1_fig1")!.node.params, "custom-binding-string"); // opaque fallback
  assert.equal(atlas.unit("p2_fig1")!.node.params, null); // no params
});

test("search matches caption, generating code, and comment text", () => {
  const atlas = loadAtlas(fixture);
  assert.ok(atlas.search("NamedTuple").some((h) => h.id === "p1_fig1" && h.field === "label"));
  assert.ok(atlas.search("svg").some((h) => h.field === "code"));
  assert.ok(atlas.search("converged").some((h) => h.id === "p1_fig1" && h.field === "comment"));
  assert.equal(atlas.search("no-such-token-xyz").length, 0);
  assert.equal(atlas.search("").length, 0);
});

test("figure assets resolve to absolute paths under the agent.json directory", () => {
  const atlas = loadAtlas(fixture);
  const assets = atlas.figureAssets("p1_fig1");
  assert.equal(assets.length, 1);
  assert.match(assets[0].rel, /p1_fig1\.svg$/);
  assert.ok(assets[0].abs.startsWith(atlas.baseDir));
  assert.ok(assets[0].abs.endsWith("p1_fig1.svg"));
  assert.equal(atlas.figureAssets("p1").length, 0); // not a figure -> no assets
});
