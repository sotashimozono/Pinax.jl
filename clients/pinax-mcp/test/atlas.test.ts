import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { loadAtlas } from "../src/atlas.js";

// compiled to dist/test/, so the source fixture is two levels up at <pkg>/test/fixtures
const here = dirname(fileURLToPath(import.meta.url));
const fixture = resolve(here, "../../test/fixtures/sample");

test("indexes every unit by id and kind, including @table nodes", () => {
  const atlas = loadAtlas(fixture);
  assert.equal(atlas.doc.title, "Demo Atlas");
  assert.equal(atlas.unit("grp")?.kind, "part");
  assert.equal(atlas.unit("p1")?.kind, "page");
  assert.equal(atlas.unit("s1")?.kind, "section");
  assert.equal(atlas.unit("p1_fig1")?.kind, "figure");
  assert.equal(atlas.unit("p1_tbl1")?.kind, "table"); // @table node, addressable like a figure
  assert.equal(atlas.unit("p2_tbl1")?.kind, "table");
  assert.equal(atlas.unit("p1_tbl1")?.parent, "p1");
  assert.equal(atlas.unit("s1_fig1")?.parent, "s1");
  assert.equal(atlas.all("figure").length, 2);
  assert.equal(atlas.all("table").length, 2);
  // a table's label is its caption; header + native-typed rows are on the node
  assert.equal(atlas.unit("p1_tbl1")!.label, "critical temperatures");
  assert.deepEqual(atlas.unit("p1_tbl1")!.node.header, ["N", "Tc"]);
  assert.deepEqual(atlas.unit("p1_tbl1")!.node.rows, [
    [8, 2.1],
    [16, 2.2],
    [32, 2.27],
  ]);
});

test("a figure carries its inline data table + a full-data csv (figure_as_table)", () => {
  const fig = loadAtlas(fixture).unit("p1_fig1")!.node;
  assert.deepEqual(fig.table.header, ["series", "x", "y"]);
  assert.equal(fig.table.rows[0][0], "N=8");
  assert.equal(fig.table.total, 3);
  assert.match(fig.data, /p1_fig1\.csv$/);
});

test("outline interleaves figures and tables in declaration order", () => {
  const o = loadAtlas(fixture).outline();
  assert.match(o, /^# Demo Atlas/);
  assert.match(o, /\[part grp\]/);
  assert.match(o, /\[page p1\] Page One — overview page/);
  // p1's content order is figure THEN table
  const fi = o.indexOf("[figure p1_fig1]");
  const ti = o.indexOf("[table p1_tbl1]");
  assert.ok(fi >= 0 && ti >= 0 && fi < ti);
  assert.match(o, /\[section s1\]/);
  assert.match(o, /\[table p2_tbl1\] a small table/);
});

test("search matches caption, code, comment, and table cells", () => {
  const atlas = loadAtlas(fixture);
  assert.ok(atlas.search("magnetization").some((h) => h.id === "p1_fig1" && h.field === "label"));
  assert.ok(atlas.search("converged").some((h) => h.id === "p1_fig1" && h.field === "comment"));
  assert.ok(atlas.search("critical").some((h) => h.id === "p1_tbl1" && h.field === "label"));
  assert.ok(atlas.search("2.27").some((h) => h.id === "p1_tbl1" && h.field === "cells")); // a cell value
  assert.equal(atlas.search("no-such-token-xyz").length, 0);
  assert.equal(atlas.search("").length, 0);
});

test("figure assets + full-data csv resolve to absolute paths", () => {
  const atlas = loadAtlas(fixture);
  const assets = atlas.figureAssets("p1_fig1");
  assert.equal(assets.length, 1); // the svg (the csv lives in `data`, not `assets`)
  assert.ok(assets[0].rel.endsWith("p1_fig1.svg"));
  const data = atlas.figureData("p1_fig1");
  assert.ok(data && data.abs.startsWith(atlas.baseDir) && data.abs.endsWith("p1_fig1.csv"));
  assert.equal(atlas.figureData("p1_tbl1"), null); // not a figure
});
