#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 reference/最新版源码/src/vanilla/script.js 接上 Flashcard 壳。

一次性改造：
  · 硬编码 DECK        -> 壳队列（card.new / card.due + card.get）
  · speechSynthesis    -> FC.tts
  · 内部 S.ratings     -> review.commit
  · 收尾 render()      -> boot()：拉队列再渲染

用法：python3 tools/patch_ref_template.py [path/to/script.js]
"""
import io
import sys

P = sys.argv[1] if len(sys.argv) > 1 else "templates/bubei_ref/script.js"
s = io.open(P, encoding="utf-8").read()

# ---------- 1) DECK 硬编码 -> 壳桥接 + 归一化 + 空队列 ----------
NEW_DECK = r"""
/* ================= 壳桥接 ================= */
var FC = window.Flashcard || null;
function fcCall(m, p) {
  if (!FC || !FC.call) return Promise.reject(new Error("no bridge"));
  return FC.call(m, p || {});
}
function fcTts(text, opts) {
  if (FC && FC.tts) { FC.tts(text, opts || {}); return; }
  try {
    window.speechSynthesis.cancel();
    var u = new SpeechSynthesisUtterance(String(text || ""));
    u.lang = "en-US";
    u.rate = 0.95;
    window.speechSynthesis.speak(u);
  } catch (e) {}
}

/* ================= 卡数据归一化 =================
   壳给的是书里的原始 fields（v3 形状：senses[].cn 是字符串、sentence_en 带 <u>、
   synonyms 是 [{word,senses}]……）。这里折成新版渲染要的 WordCard 形状。 */
function cnList(v) {
  if (v == null) return [];
  if (Array.isArray(v)) {
    var o = [];
    v.forEach(function (x) { o = o.concat(cnList(x)); });
    return o;
  }
  return String(v).split(/[；;，,、]\s*/).map(function (x) { return x.trim(); }).filter(Boolean);
}
function stripU(x) { return String(x || "").replace(/<\/?u\s*>/g, ""); }
function flatRel(items) {
  var out = [];
  (items || []).forEach(function (it) {
    if (typeof it === "string") { out.push({ word: it, pos: "", cn: [] }); return; }
    var w = String(it.word || "");
    var senses = it.senses || it.meanings;
    if (senses && senses.length) {
      senses.forEach(function (x) {
        out.push({ word: w, pos: String((x && x.pos) || ""), cn: cnList(x && x.cn) });
      });
    } else {
      out.push({ word: w, pos: String(it.pos || ""), cn: cnList(it.cn) });
    }
  });
  return out;
}
function wordsOf(items) {
  return flatRel(items).map(function (x) { return x.word; }).filter(Boolean);
}
function normCard(raw, fallbackId) {
  var f = (raw && raw.fields) ? raw.fields : (raw || {});
  var senses = [];
  (f.senses || []).forEach(function (x) {
    if (typeof x === "string") senses.push({ pos: "", cn: cnList(x) });
    else senses.push({ pos: String(x.pos || ""), cn: cnList(x.cn) });
  });
  var sen = (f.sentence && typeof f.sentence === "object")
    ? { en: stripU(f.sentence.en), cn: f.sentence.cn || "" }
    : { en: stripU(f.sentence_en), cn: f.sentence_cn || "" };

  var collocations = [], rootItems = [], rootSummary = "", exams = [], keep = [];
  (f.blocks || []).forEach(function (b) {
    var t = String((b && b.title) || "");
    var ty = String((b && b.type) || "").toLowerCase();
    if (ty === "pairs" && (t.indexOf("搭配") >= 0 || t.indexOf("短语") >= 0)) {
      (b.items || []).forEach(function (it) {
        if (it && typeof it === "object") {
          collocations.push({ en: String(it.en || it.k || it.left || ""), cn: String(it.cn || it.v || it.right || "") });
        }
      });
    } else if (t.indexOf("词根") >= 0 || t.indexOf("词源") >= 0) {
      var txt = String(b.text || b.html || "");
      rootSummary = txt;
      rootItems.push({ tag: "词根", text: txt });
    } else {
      keep.push(b);
    }
  });
  if (Array.isArray(f.collocations)) collocations = f.collocations;
  if (f.root && typeof f.root === "object" && !Array.isArray(f.root)) {
    rootItems = f.root.items || rootItems;
    rootSummary = f.root.summary || rootSummary;
  } else if (Array.isArray(f.root) && f.root.length) {
    rootItems = f.root;
  }
  if (Array.isArray(f.exams)) exams = f.exams;

  return {
    id: (raw && raw.id) || f.id || fallbackId || f.word || "",
    word: String(f.word || ""),
    syllable: f.syllable || "",
    phonetic: String(f.phonetic || f.phonetic_us || f.phonetic_uk || "").trim(),
    verified: !!(f.verified || f.phonetic_us),
    senses: senses,
    sentence: sen,
    collocations: collocations,
    derivatives: Array.isArray(f.derivatives) ? flatRel(f.derivatives) : [],
    synonyms: Array.isArray(f.synonyms) ? (typeof f.synonyms[0] === "string" ? f.synonyms.slice() : wordsOf(f.synonyms)) : [],
    antonyms: Array.isArray(f.antonyms) ? (typeof f.antonyms[0] === "string" ? f.antonyms.slice() : wordsOf(f.antonyms)) : [],
    root: rootItems,
    rootSummary: rootSummary,
    exams: exams,
    blocks: keep,
    tags: f.tags || [],
    _kv: (raw && raw.kv) || {}
  };
}

/* ================= 会话（自管一轮）================= */
var DECK = [];   /* boot() 里从壳拉 */
"""

start = s.index("var DECK = [")
end = s.index("\n];\n", start) + len("\n];\n")
s = s[:start] + NEW_DECK.strip("\n") + "\n" + s[end:]

# ---------- 2) speak() -> FC.tts ----------
OLD_SPEAK = """function speak(text) {
  try {
    window.speechSynthesis.cancel();
    var u = new SpeechSynthesisUtterance(text);
    u.lang = "en-US";
    u.rate = 0.95;
    window.speechSynthesis.speak(u);
  } catch (e) { /* 静默失败 */ }
}"""
NEW_SPEAK = """function speak(text, opts) {
  var say = String(text || "").replace(/<[^>]*>/g, "").replace(/\\s+/g, " ").trim();
  if (!say) return;
  fcTts(say, opts || { lang: "en-US", rate: 0.95 });
}"""
assert OLD_SPEAK in s, "speak() 没找到"
s = s.replace(OLD_SPEAK, NEW_SPEAK)

# ---------- 3) advance() 交评级 ----------
OLD_ADV = """function advance(mistake) {
  var w = cur();
  if (mistake) {
    S.ratings[w.id] = "again";
    if (S.pool.indexOf(w.id) < 0) S.pool.push(w.id);
  }"""
NEW_ADV = """function advance(mistake) {
  var w = cur();
  if (mistake) {
    S.ratings[w.id] = "again";
    if (S.pool.indexOf(w.id) < 0) S.pool.push(w.id);
  }
  commit(w, S.ratings[w.id] || "good");"""
assert OLD_ADV in s, "advance() 没找到"
s = s.replace(OLD_ADV, NEW_ADV)

# ---------- 4) known 也交一次 ----------
OLD_KN = """    S.knownCount++;
    S.queue = S.queue.filter(function (x) { return x.id !== w.id; });"""
NEW_KN = """    S.knownCount++;
    commit(w, "good");
    S.queue = S.queue.filter(function (x) { return x.id !== w.id; });"""
assert OLD_KN in s, "known 没找到"
s = s.replace(OLD_KN, NEW_KN)

# ---------- 5) 收尾 render() -> boot ----------
BOOT = """/* ================= 启动：从壳拉队列 ================= */
function mapRating(r) {
  return r === "good" ? "good" : r === "hard" ? "hard" : "again";
}
function commit(w, rating) {
  if (!w || !w.id) return;
  fcCall("review.commit", { id: w.id, rating: mapRating(rating) }).catch(function (e) {
    if (FC && FC.log) { try { FC.log("ref", "commit fail: " + e); } catch (_) {} }
  });
}
function loadQueue() {
  var bookId = null;
  try { bookId = (FC && FC.getState) ? FC.getState("bookId") : null; } catch (e) {}
  var p = { limit: 20 };
  if (bookId) p.bookId = bookId;
  return fcCall("card.new", p).then(function (r) {
    var ids = (r && r.ids) || [];
    return Promise.all(ids.map(function (id) {
      return fcCall("card.get", { id: id }).then(function (x) { return x && x.card; });
    }));
  }).then(function (list) {
    DECK = list.filter(Boolean).map(function (c, i) { return normCard(c, "c" + i); });
  }).catch(function (e) {
    if (FC && FC.log) { try { FC.log("ref", "loadQueue fail: " + e); } catch (_) {} }
    DECK = [];
  });
}
loadQueue().then(function () {
  S.phase = "learn";
  S.face = "front";
  S.queue = DECK.slice();
  S.idx = 0;
  render();
});
"""

tail = s.rstrip()
assert tail.endswith("render();"), "结尾不是 render();"
s = tail[:-len("render();")] + BOOT

io.open(P, "w", encoding="utf-8").write(s)
print("patched:", P, "->", len(s), "bytes")
