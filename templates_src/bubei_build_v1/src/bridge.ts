/* ============================================================
   bridge.ts —— 壳（Flashcard WebView）桥接层
   ------------------------------------------------------------
   参考项目是纯前端 demo：DECK 硬编码、发音走 speechSynthesis、
   进度只在内存。装成模板后，这些必须换成壳的原子能力：

     队列   session.plan  → 本轮该给谁（当前这本书）
     内容   card.get      → 单卡完整 fields
     评级   review.commit → 唯一动 FSRS 的入口
     发音   FC.tts        → 壳的 TTS（豆包/系统，可缓存）
     进度   web.progress / web.finish → 上报给壳
     断点   session.save / session.load

   壳在 web_session 模式只 load 一次骨架页，之后全程事件驱动。
   ============================================================ */
import type { WordCard } from "./flashcard/data";

type FCBridge = {
  call?: (m: string, p?: unknown) => Promise<any>;
  on?: (evt: string, fn: (d: any) => void) => void;
  tts?: (t: string, o?: unknown) => void;
  log?: (tag: string, msg: string) => void;
  post?: (type: string, data?: unknown) => void;
  getCard?: () => any;
  onMount?: (fn: () => void) => void;
};

declare global {
  interface Window {
    Flashcard?: FCBridge;
  }
}

export const FC: FCBridge | undefined =
  typeof window !== "undefined" ? window.Flashcard : undefined;

export const hasBridge = !!(FC && FC.call);

export function log(msg: string) {
  try {
    FC?.log?.("bubei_build", msg);
  } catch {
    /* ignore */
  }
}

export function call(m: string, p?: unknown): Promise<any> {
  if (!FC?.call) return Promise.reject(new Error("no bridge"));
  return FC.call(m, p || {});
}

export function post(type: string, data?: Record<string, unknown>) {
  try {
    FC?.post?.(type, data || {});
  } catch {
    /* ignore */
  }
}

/* ---------------- 发音：优先壳，退系统 ---------------- */
export function speak(text: string, rate = 0.95) {
  const say = String(text || "").replace(/<[^>]*>/g, "").replace(/\s+/g, " ").trim();
  if (!say) return;
  if (FC?.tts) {
    FC.tts(say, { lang: "en-US", rate });
    return;
  }
  try {
    window.speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(say);
    u.lang = "en-US";
    u.rate = rate;
    window.speechSynthesis.speak(u);
  } catch {
    /* ignore */
  }
}

/* ============================================================
   卡数据归一化：壳吐的 fields → 新版 WordCard 形状
   ------------------------------------------------------------
   书里可能是 v3 老形状（senses[].cn 是字符串、sentence_en 带 <u>、
   synonyms 是 [{word,senses}]……），这里折成渲染要的 WordCard。
   ============================================================ */
/* 契约数据里 cn 是 string[]，每个元素是【原子词义】，不能再切；
   v3 老数据 cn 是字符串，才按强分隔符拆。 */
function cnList(v: any): string[] {
  if (v == null) return [];
  if (Array.isArray(v)) return v.map((x) => String(x).trim()).filter(Boolean);
  return String(v)
    .split(/[；;，,、]\s*/)
    .map((x) => x.trim())
    .filter(Boolean);
}

function stripU(x: any): string {
  return String(x || "").replace(/<\/?u\s*>/g, "");
}

function flatRel(items: any): { word: string; pos: string; cn: string }[] {
  const out: { word: string; pos: string; cn: string }[] = [];
  (items || []).forEach((it: any) => {
    if (typeof it === "string") {
      out.push({ word: it, pos: "", cn: "" });
      return;
    }
    const w = String(it.word || "");
    const senses = it.senses || it.meanings;
    if (senses && senses.length) {
      senses.forEach((x: any) => {
        out.push({
          word: w,
          pos: String(x?.pos || ""),
          cn: cnList(x?.cn).join("；"),
        });
      });
    } else {
      out.push({ word: w, pos: String(it.pos || ""), cn: cnList(it.cn).join("；") });
    }
  });
  return out;
}

function wordsOf(items: any): string[] {
  return flatRel(items)
    .map((x) => x.word)
    .filter(Boolean);
}

/** 壳的 card.get / mountCard 返回体 → WordCard */
export function normCard(raw: any): WordCard | null {
  if (!raw) return null;
  const f = raw.fields ? raw.fields : raw;
  if (!f || !f.word) return null;

  const senses = (f.senses || []).map((x: any) =>
    typeof x === "string"
      ? { pos: "", cn: cnList(x) }
      : { pos: String(x.pos || ""), cn: cnList(x.cn) }
  );

  const sentence =
    f.sentence && typeof f.sentence === "object"
      ? { en: stripU(f.sentence.en), cn: f.sentence.cn || "" }
      : { en: stripU(f.sentence_en), cn: f.sentence_cn || "" };

  const collocations: { en: string; cn: string; m?: number; tag?: string }[] = [];
  const rootItems: { tag: string; text: string }[] = [];
  let rootSummary = "";
  const exams: { en: string; src: string }[] = [];

  (f.blocks || []).forEach((b: any) => {
    const t = String(b?.title || "");
    const ty = String(b?.type || "").toLowerCase();
    if (ty === "pairs" && (t.includes("搭配") || t.includes("短语"))) {
      (b.items || []).forEach((it: any) => {
        if (it && typeof it === "object") {
          collocations.push({
            en: String(it.en || it.k || it.left || ""),
            cn: String(it.cn || it.v || it.right || ""),
          });
        }
      });
    } else if (t.includes("词根") || t.includes("词源")) {
      const txt = String(b.text || b.html || "");
      if (txt) {
        rootSummary = txt;
        rootItems.push({ tag: "词根", text: txt });
      }
    }
  });

  if (Array.isArray(f.collocations)) {
    f.collocations.forEach((c: any) => {
      if (c && typeof c === "object") {
        collocations.push({
          en: String(c.en || ""),
          cn: String(c.cn || ""),
          m: typeof c.m === "number" ? c.m : undefined,
          tag: c.tag ? String(c.tag) : undefined,
        });
      }
    });
  }
  if (f.root && typeof f.root === "object" && !Array.isArray(f.root)) {
    if (Array.isArray(f.root.items)) {
      rootItems.length = 0;
      f.root.items.forEach((r: any) =>
        rootItems.push({ tag: String(r.tag || ""), text: String(r.text || "") })
      );
    }
    if (f.root.summary) rootSummary = String(f.root.summary);
  } else if (Array.isArray(f.root)) {
    rootItems.length = 0;
    f.root.forEach((r: any) =>
      rootItems.push({ tag: String(r.tag || ""), text: String(r.text || "") })
    );
  }
  if (Array.isArray(f.exams)) {
    f.exams.forEach((e: any) => {
      if (e && typeof e === "object" && e.en) {
        exams.push({ en: String(e.en), src: String(e.src || "") });
      }
    });
  }
  // 契约形状：rootSummary 是顶层字段（v3 老形状才埋在 root.summary）
  if (f.rootSummary) rootSummary = String(f.rootSummary);

  const word = String(f.word);
  return {
    id: String(raw.id || f.id || word),
    word,
    syllable: String(f.syllable || ""),
    phonetic: String(f.phonetic || f.phonetic_us || f.phonetic_uk || "").trim(),
    verified: !!(f.verified || f.phonetic_us),
    senses: senses.length ? senses : [{ pos: "", cn: [""] }],
    sentence,
    collocations,
    derivatives: Array.isArray(f.derivatives) ? flatRel(f.derivatives) : [],
    synonyms: Array.isArray(f.synonyms)
      ? typeof f.synonyms[0] === "string"
        ? f.synonyms.slice()
        : wordsOf(f.synonyms)
      : [],
    antonyms: Array.isArray(f.antonyms)
      ? typeof f.antonyms[0] === "string"
        ? f.antonyms.slice()
        : wordsOf(f.antonyms)
      : [],
    root: rootItems,
    rootSummary,
    exams,
    meaningDetails: Array.isArray(f.meaningDetails) ? f.meaningDetails : [],
  } as WordCard;
}

/* ============================================================
   队列：从壳拉本轮该给谁
   ------------------------------------------------------------
   走 session.plan（壳按当前这本书排好的计划）。
   千万别用 card.new —— 不传 bookId 会跨书抓卡。
   ============================================================ */
export async function loadDeck(): Promise<{
  deck: WordCard[];
  newIds: string[];
  reviewIds: string[];
}> {
  const plan = await call("session.plan", {}).catch(() => null);
  const allIds: string[] = [];
  const newIds: string[] = [];
  const reviewIds: string[] = [];

  const units = (plan && plan.units) || [];
  units.forEach((u: any) => {
    const bucket = u && u.isReview ? reviewIds : newIds;
    (u?.cards || []).forEach((c: any) => {
      if (c && c.id) {
        allIds.push(String(c.id));
        bucket.push(String(c.id));
      }
    });
  });

  if (!allIds.length) {
    // 兜底：真没计划，退回全库新卡
    const r = await call("card.new", { limit: 20 }).catch(() => null);
    (r?.ids || []).forEach((id: string) => {
      allIds.push(id);
      newIds.push(id);
    });
  }

  const cards = await Promise.all(
    allIds.map((id) =>
      call("card.get", { id })
        .then((r) => normCard(r?.card))
        .catch(() => null)
    )
  );
  const deck = cards.filter(Boolean) as WordCard[];
  log(`loadDeck: units=${units.length} deck=${deck.length} new=${newIds.length} review=${reviewIds.length}`);
  return { deck, newIds, reviewIds };
}

/* ---------------- 评级：唯一动 FSRS 的入口 ---------------- */
export function commit(id: string, rating: "again" | "hard" | "good") {
  return call("review.commit", { id, rating }).catch((e) => {
    log(`commit 失败 ${id} ${rating}: ${e}`);
    return null;
  });
}

/* ---------------- 会话生命周期 ---------------- */
export function on(event: string, fn: (d: any) => void) {
  try {
    FC?.on?.(event, fn);
  } catch {
    /* ignore */
  }
}

export function onMount(fn: () => void) {
  try {
    FC?.onMount?.(fn);
  } catch {
    /* ignore */
  }
}
