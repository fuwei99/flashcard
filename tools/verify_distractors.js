/*
 * 验证：bubei_react_v1 的干扰项能否在「壳一个选项都不给」时自给自足。
 *
 * 做法：从真实的 templates/bubei_react_v1/script.js 里按大括号配平抽出
 *   bookIdOf / loadPool / warmPool / confOpts / distractorCands
 * 原样 eval（不重写、不简化），只给它们灌 mock 的 FC.fs / arr / shuffle / S。
 * 这样测的就是真代码，不是我的复述。
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

// 仓库根 = 本文件上一级；从根运行：node tools/verify_distractors.js
const SRC = path.resolve(__dirname, "..", "templates/bubei_react_v1/script.js");
const code = fs.readFileSync(SRC, "utf8");

function extractFn(name) {
  const re = new RegExp("(^|\\n)\\s*function\\s+" + name + "\\s*\\(", "m");
  const m = re.exec(code);
  if (!m) throw new Error("找不到函数: " + name);
  const start = m.index + (m[1] ? 1 : 0);
  const braceStart = code.indexOf("{", m.index);
  let depth = 0;
  for (let i = braceStart; i < code.length; i++) {
    if (code[i] === "{") depth++;
    else if (code[i] === "}") {
      depth--;
      if (depth === 0) return code.slice(start, i + 1);
    }
  }
  throw new Error("大括号不配平: " + name);
}

const NAMES = ["bookIdOf", "loadPool", "warmPool", "confOpts", "distractorCands"];
const extracted = NAMES.map(extractFn);

// ---- 假书：3 章 × 若干词，形状照 docs/book-data-contract.md ----
const BOOK = "kaoyan_core";
const chapters = {};
for (let ch = 1; ch <= 3; ch++) {
  const cards = [];
  for (let i = 0; i < 8; i++) {
    const n = (ch - 1) * 8 + i;
    cards.push({
      id: BOOK + ":ch" + ch + ":" + i,
      word: "word" + n,
      senses: [{ pos: "n.", cn: ["释义" + n] }],
    });
  }
  chapters["ch_000" + ch + ".json"] = JSON.stringify({
    chapter_id: "ch_000" + ch,
    title: "第 " + ch + " 章",
    cards,
  });
}

let readCalls = 0;
const FC = {
  log: () => {},
  fs: {
    list(base) {
      if (base !== "books/" + BOOK) return Promise.resolve({ entries: [] });
      return Promise.resolve({
        entries: Object.keys(chapters).map((n) => ({ name: n, dir: false })),
      });
    },
    read(p) {
      readCalls++;
      const n = p.split("/").pop();
      if (!chapters[n]) return Promise.reject(new Error("no file"));
      return Promise.resolve({ content: chapters[n] });
    },
  },
};

const sandbox = {
  FC,
  _poolByBook: {},
  _poolWait: {},
  S: { seenCards: {} },
  arr: (a) => (Array.isArray(a) ? a : []),
  // 确定性「洗牌」：不真随机，保证可复现
  shuffle: (a) => a.slice().sort((x, y) => String(x.id || "").localeCompare(String(y.id || ""))),
  Promise,
  JSON,
  String,
  Object,
  RegExp,
  console,
};
vm.createContext(sandbox);
vm.runInContext(extracted.join("\n\n"), sandbox);

// ---- 测试 ----
function card(id, word, opts) {
  opts = opts || {};
  return Object.assign(
    {
      id,
      fields: { word, senses: [{ pos: "n.", cn: ["释义-" + word] }] },
      session: { book: BOOK },
    },
    opts
  );
}

let fail = 0;
function check(label, ok, extra) {
  console.log((ok ? "  PASS  " : "  FAIL  ") + label + (extra ? "   " + extra : ""));
  if (!ok) fail++;
}

(async () => {
  console.log("源文件: " + path.relative(process.cwd(), SRC));
  console.log("抽出函数: " + NAMES.join(", ") + "\n");

  const cur = card(BOOK + ":ch1:0", "word0");

  console.log("[1] 池子冷的时候（预热前的首帧）");
  let cold = sandbox.distractorCands(cur);
  console.log("     候选数 = " + cold.length + "（只有易混项/见过的卡）");
  check("冷池不会崩", Array.isArray(cold));
  check("冷池拿不到壳的 choices（本测试里 cur 没有 choices 字段）",
    cold.every((o) => o.id !== undefined));

  console.log("\n[2] 预热整本书池");
  // warmPool 是 fire-and-forget（只吃一个参数），照真实用法调
  sandbox.warmPool(cur);
  await new Promise((r) => setTimeout(r, 50));
  const poolSize = (sandbox._poolByBook[BOOK] || []).length;
  console.log("     池子卡片数 = " + poolSize + "，读盘次数 = " + readCalls);
  check("池子建起来了", poolSize === 24, "期望 24 章卡（3 章 × 8）");

  console.log("\n[3] 预热后再取干扰项（模拟挂第二张卡起）");
  const warm = sandbox.distractorCands(cur);
  console.log("     候选数 = " + warm.length);
  check("够凑 4 个选项（3 干扰 + 1 正确）", warm.length >= 3, "候选 " + warm.length);

  console.log("\n[4] 正确项不在干扰项里（否则等于送答案）");
  check("当前卡被排除", warm.every((o) => o.id !== cur.id));

  console.log("\n[5] 干扰项 id 不重复（去重生效）");
  const ids = warm.map((o) => o.id);
  check("无重复", new Set(ids).size === ids.length);

  console.log("\n[6] 每个干扰项都带 senses（选义模式要按中文释义去重/渲染）");
  check("形状完整", warm.every((o) => o.fields && o.fields.word && Array.isArray(o.fields.senses)));

  console.log("\n[7] 重复预热不重复读盘（loadPool 幂等）");
  const before = readCalls;
  sandbox.warmPool(cur, null);
  await new Promise((r) => setTimeout(r, 30));
  check("没有新增读盘", readCalls === before, "读盘 " + before + " -> " + readCalls);

  console.log("\n[8] 换一本书：池子按书隔离");
  const other = card("x:ch1:0", "x0", { session: { book: "" } });
  sandbox.warmPool(other, null);
  await new Promise((r) => setTimeout(r, 20));
  check("bookId 为空时不读盘、不报错", Object.keys(sandbox._poolByBook).length === 1);

  console.log("\n" + (fail === 0 ? "全部通过" : fail + " 项失败"));
  process.exit(fail === 0 ? 0 : 1);
})();
