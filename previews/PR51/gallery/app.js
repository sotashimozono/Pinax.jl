// pinax.js — interactive comment layer for the gallery (notes 01 §4).
//
// A communication channel over the figures (me / advisor / LLM). Comments are written *at* their
// target (a figure card or a section), so the binding is visually unambiguous. Committed comments
// (already in comments.toml) are rendered server-side; this script adds the BROWSER WRITE path:
// type a comment on a node -> saved to localStorage immediately (every browser) -> "Export" merges
// committed + local into a downloadable comments.toml (the durable, CLI/LLM-readable source).
// localStorage is a working cache; the file is the source of truth.
(function () {
  "use strict";

  var data = {};
  try {
    data = JSON.parse(document.getElementById("pinax-committed").textContent);
  } catch (e) {}
  var COMMITTED = data.comments || {}; // id -> [{author, text}]
  var COMMITTED_BM = data.bookmarks || {}; // id -> true
  var FEATURES = data.features || [];
  var NS = "pinax:" + location.pathname + ":";

  function has(f) {
    return FEATURES.indexOf(f) >= 0;
  }
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function lget(k, d) {
    try {
      var v = localStorage.getItem(NS + k);
      return v == null ? d : JSON.parse(v);
    } catch (e) {
      return d;
    }
  }
  function lset(k, v) {
    try {
      localStorage.setItem(NS + k, JSON.stringify(v));
    } catch (e) {}
  }
  function localComments(id) {
    return lget("cmt:" + id, []);
  }
  function localBookmarks() {
    return lget("bm", {}); // id -> bool, overrides committed
  }
  function bookmarked(id) {
    var lb = localBookmarks();
    return id in lb ? !!lb[id] : !!COMMITTED_BM[id];
  }

  // ---- per-node enhancement ----------------------------------------------

  // The comment container for a node (its direct child), created if absent.
  function container(node) {
    var c = null,
      ch = node.children;
    for (var i = 0; i < ch.length; i++) {
      if (ch[i].classList && ch[i].classList.contains("pinax-comments")) c = ch[i];
    }
    if (!c) {
      c = document.createElement("div");
      c.className = "pinax-comments";
      node.appendChild(c);
    }
    return c;
  }

  // Render this node's LOCAL (unsaved) comments under the committed ones, with a delete control.
  function renderLocal(node, id) {
    var c = container(node);
    c.querySelectorAll(".pinax-cmt.local").forEach(function (n) {
      n.remove();
    });
    localComments(id).forEach(function (t, idx) {
      var div = document.createElement("div");
      div.className = "pinax-cmt local";
      var who = t.author ? '<span class="author">' + esc(t.author) + "</span> " : "";
      div.innerHTML =
        who +
        "<span>" +
        esc(t.text).replace(/\n/g, "<br>") +
        '</span><span class="unsaved">(unsaved)</span>' +
        '<span class="del" title="delete this local comment">×</span>';
      div.querySelector(".del").addEventListener("click", function () {
        var arr = localComments(id);
        arr.splice(idx, 1);
        lset("cmt:" + id, arr);
        renderLocal(node, id);
        updateStatus();
      });
      c.appendChild(div);
    });
  }

  // An inline editor appended to the node's comment container.
  function openEditor(node, id) {
    var c = container(node);
    if (c.querySelector(".pinax-editor")) {
      c.querySelector(".pinax-editor textarea").focus();
      return;
    }
    var ed = document.createElement("div");
    ed.className = "pinax-editor";
    ed.innerHTML =
      "<textarea placeholder=\"comment on " +
      esc(id) +
      ' (markdown)"></textarea>' +
      '<div class="row"><input class="author" placeholder="author" />' +
      '<button class="save">Save</button><button class="cancel">Cancel</button></div>';
    var ta = ed.querySelector("textarea");
    var au = ed.querySelector("input.author");
    au.value = lget("author", "me");
    ed.querySelector(".cancel").addEventListener("click", function () {
      ed.remove();
    });
    ed.querySelector(".save").addEventListener("click", function () {
      var text = ta.value.trim();
      if (!text) {
        ed.remove();
        return;
      }
      var author = au.value.trim();
      lset("author", author);
      var arr = localComments(id);
      arr.push({ author: author, text: text });
      lset("cmt:" + id, arr);
      ed.remove();
      renderLocal(node, id);
      updateStatus();
    });
    c.appendChild(ed);
    ta.focus();
  }

  function addCtl(host, label, title, fn) {
    var b = document.createElement("button");
    b.className = "pinax-ctl";
    b.textContent = label;
    b.title = title;
    b.addEventListener("click", fn);
    host.appendChild(b);
    return b;
  }

  function enhanceBookmark(section, id) {
    var h2 = section.querySelector("h2");
    if (!h2) return;
    h2.querySelectorAll(".pinax-bm-on").forEach(function (n) {
      n.remove(); // replace the static (committed) marker with an interactive toggle
    });
    var btn = addCtl(h2, "", "bookmark this section", function () {
      var lb = localBookmarks();
      lb[id] = !bookmarked(id);
      lset("bm", lb);
      paint();
    });
    btn.classList.add("pinax-bm");
    function paint() {
      var on = bookmarked(id);
      btn.textContent = on ? "★" : "☆";
      btn.style.color = on ? "#e3b341" : "";
      section.classList.toggle("bookmarked", on);
    }
    paint();
  }

  // ---- toolbar ------------------------------------------------------------

  function tomlKey(id) {
    return /^[A-Za-z0-9_-]+$/.test(id) ? id : JSON.stringify(id);
  }
  function exportToml() {
    var ids = {};
    Object.keys(COMMITTED).forEach(function (k) {
      ids[k] = 1;
    });
    var out = "";
    var bms = [];
    var seen = {};
    Object.keys(COMMITTED_BM).forEach(function (k) {
      seen[k] = 1;
    });
    Object.keys(localBookmarks()).forEach(function (k) {
      seen[k] = 1;
    });
    Object.keys(seen).forEach(function (k) {
      if (bookmarked(k)) bms.push(k);
    });
    if (bms.length) {
      out += "[bookmark]\n";
      bms.forEach(function (k) {
        out += tomlKey(k) + " = true\n";
      });
      out += "\n";
    }
    // every id that has committed or local comments, committed turns first
    Object.keys(COMMITTED).forEach(function (k) {
      ids[k] = 1;
    });
    document.querySelectorAll("[id]").forEach(function (el) {
      if (localComments(el.id).length) ids[el.id] = 1;
    });
    Object.keys(ids).forEach(function (id) {
      var turns = (COMMITTED[id] || []).concat(localComments(id));
      turns.forEach(function (t) {
        out += "[[comment." + tomlKey(id) + "]]\n";
        out += "author = " + JSON.stringify(String(t.author || "")) + "\n";
        out += "text = " + JSON.stringify(String(t.text || "")) + "\n\n";
      });
    });
    download("comments.toml", out);
  }
  function download(name, text) {
    var blob = new Blob([text], { type: "text/plain;charset=utf-8" });
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () {
      URL.revokeObjectURL(a.href);
    }, 1000);
  }
  function countLocal() {
    var n = 0;
    document.querySelectorAll("[id]").forEach(function (el) {
      n += localComments(el.id).length;
    });
    return n;
  }
  var statusEl = null;
  function updateStatus() {
    if (statusEl) {
      var n = countLocal();
      statusEl.textContent = n ? n + " unsaved — Export to save" : "";
    }
  }
  function buildToolbar() {
    var bar = document.createElement("div");
    bar.id = "pinax-bar";
    var h1 = document.querySelector("body > h1");
    if (h1 && h1.nextSibling) h1.parentNode.insertBefore(bar, h1.nextSibling);
    else document.body.insertBefore(bar, document.body.firstChild);

    if (has("bookmarks")) {
      var filter = document.createElement("button");
      filter.textContent = "★ only";
      filter.title = "show only bookmarked sections";
      filter.addEventListener("click", function () {
        var on = document.body.classList.toggle("pinax-filter");
        filter.classList.toggle("on", on);
      });
      bar.appendChild(filter);
    }
    if (has("export")) {
      var exp = document.createElement("button");
      exp.textContent = "Export comments.toml";
      exp.title = "download committed + local comments as comments.toml";
      exp.addEventListener("click", exportToml);
      bar.appendChild(exp);
    }
    var clear = document.createElement("button");
    clear.textContent = "Clear local";
    clear.title = "discard this browser's unsaved comments/bookmarks";
    clear.addEventListener("click", function () {
      if (!confirm("Discard all unsaved (local) comments and bookmarks in this browser?")) return;
      Object.keys(localStorage)
        .filter(function (k) {
          return k.indexOf(NS) === 0;
        })
        .forEach(function (k) {
          localStorage.removeItem(k);
        });
      location.reload();
    });
    bar.appendChild(clear);

    if (has("comments") || has("export")) {
      // Static gallery, no backend: a viewer's comments live only in their own browser until they
      // Export comments.toml (which the author re-renders to bake them into the committed layer).
      var note = document.createElement("span");
      note.className = "pinax-note";
      note.textContent =
        "Comments are saved only in this browser — Export to keep or share them.";
      bar.appendChild(note);
    }

    statusEl = document.createElement("span");
    statusEl.className = "pinax-status";
    bar.appendChild(statusEl);
  }

  // ---- init ---------------------------------------------------------------

  function init() {
    if (!has("comments") && !has("bookmarks") && !has("export")) return;
    buildToolbar();
    if (has("comments")) {
      document.querySelectorAll("section.section[id]").forEach(function (sec) {
        var h2 = sec.querySelector("h2");
        if (h2) addCtl(h2, "✎", "add a comment on this section", function () {
          openEditor(sec, sec.id);
        });
        renderLocal(sec, sec.id);
      });
      document.querySelectorAll("figure[id]").forEach(function (fig) {
        var host = fig.querySelector("figcaption") || fig;
        addCtl(host, "✎", "add a comment on this figure", function () {
          openEditor(fig, fig.id);
        });
        renderLocal(fig, fig.id);
      });
    }
    if (has("bookmarks")) {
      document.querySelectorAll("section.section[id]").forEach(function (sec) {
        enhanceBookmark(sec, sec.id);
      });
    }
    updateStatus();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
