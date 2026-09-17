import { DECK } from "./data";

/* ============================================================
   点词查词：本地词库优先，未命中时调用 dictionaryapi.dev
   （有道 web 接口存在 CORS 限制，浏览器端无法直连）
   ============================================================ */

export interface DictExample {
  en: string;
  cn?: string;
  src?: string;
}

export interface DictEntry {
  word: string;
  phonetic?: string;
  level?: string; // 考研 / 四级 / 高考 …
  senses: { pos: string; cn: string }[];
  collocations?: { en: string; cn: string }[];
  examples?: DictExample[];
  fromApi?: boolean;
}

/* ---------- 本地小词库（例句里出现的词） ---------- */
const LEXICON: Record<string, DictEntry> = {
  event: {
    word: "event", phonetic: "/ɪˈvent/", level: "考研",
    senses: [{ pos: "n.", cn: "事件；公开活动；体育项目" }],
    collocations: [
      { en: "a major event", cn: "重大事件" },
      { en: "in the event of", cn: "万一，倘若" },
    ],
    examples: [
      { en: "The opening ceremony was a grand event.", cn: "开幕式是一场盛大的活动。", src: "柯林斯" },
      { en: "In the unlikely event of a fire, leave quickly.", cn: "万一发生火灾，请迅速离开。", src: "柯林斯" },
    ],
  },
  unfortunate: {
    word: "unfortunate", phonetic: "/ʌnˈfɔːrtʃənət/", level: "考研",
    senses: [
      { pos: "adj.", cn: "不幸的；令人遗憾的；不适当的" },
      { pos: "n.", cn: "不幸的人" },
    ],
    collocations: [
      { en: "an unfortunate accident", cn: "不幸的事故" },
      { en: "an unfortunate victim", cn: "不幸的受害者" },
    ],
    examples: [
      { en: "Unfortunate incidents had occurred; mistaken ideas had been current.", cn: "不幸的事件曾发生过，错误的观念也曾流行过。", src: "动物农场" },
      { en: "My men were killed in a tragic and unfortunate incident.", cn: "我的人在一次悲惨和不幸的事故中死了。", src: "海军罪案调查处" },
      { en: "To lose one wife may be considered unfortunate but to lose three?", cn: "失去一位妻子可以说是一起不幸，可是失去三位妻子呢？", src: "福尔摩斯探案集" },
    ],
  },
  television: {
    word: "television", phonetic: "/ˈtelɪvɪʒn/", level: "中考",
    senses: [{ pos: "n.", cn: "电视，电视机" }],
    examples: [{ en: "She turned the television on.", cn: "她打开了电视。", src: "柯林斯" }],
  },
  computer: {
    word: "computer", phonetic: "/kəmˈpjuːtər/", level: "中考",
    senses: [{ pos: "n.", cn: "计算机，电脑" }],
    examples: [{ en: "The data is stored in the computer.", cn: "数据存储在计算机中。", src: "柯林斯" }],
  },
  show: {
    word: "show", phonetic: "/ʃoʊ/", level: "中考",
    senses: [
      { pos: "n.", cn: "演出，节目；展览" },
      { pos: "v.", cn: "给…看，展示；表明" },
    ],
    examples: [{ en: "The show starts at eight.", cn: "演出八点开始。", src: "柯林斯" }],
  },
  girl: {
    word: "girl", phonetic: "/ɡɜːrl/", level: "中考",
    senses: [{ pos: "n.", cn: "女孩，姑娘" }],
  },
  fighting: {
    word: "fighting", phonetic: "/ˈfaɪtɪŋ/", level: "高考",
    senses: [{ pos: "n.", cn: "战斗，打斗" }, { pos: "adj.", cn: "战斗的" }],
  },
  war: {
    word: "war", phonetic: "/wɔːr/", level: "中考",
    senses: [{ pos: "n.", cn: "战争；斗争" }],
    collocations: [{ en: "full-scale war", cn: "全面战争" }],
  },
  collect: {
    word: "collect", phonetic: "/kəˈlekt/", level: "四级",
    senses: [{ pos: "v.", cn: "收集，采集；领取" }],
  },
  signature: {
    word: "signature", phonetic: "/ˈsɪɡnətʃər/", level: "考研",
    senses: [{ pos: "n.", cn: "签名，署名" }],
    examples: [{ en: "He forged my signature.", cn: "他伪造了我的签名。", src: "柯林斯" }],
  },
  national: {
    word: "national", phonetic: "/ˈnæʃnəl/", level: "四级",
    senses: [{ pos: "adj.", cn: "国家的，全国的" }, { pos: "n.", cn: "国民" }],
  },
  internet: {
    word: "internet", phonetic: "/ˈɪntərnet/", level: "中考",
    senses: [{ pos: "n.", cn: "互联网，因特网" }],
  },
  impact: {
    word: "impact", phonetic: "/ˈɪmpækt/", level: "考研",
    senses: [{ pos: "n.", cn: "影响，冲击力" }, { pos: "v.", cn: "对…产生影响" }],
    collocations: [{ en: "have a profound impact on", cn: "对…产生深远影响" }],
  },
  life: {
    word: "life", phonetic: "/laɪf/", level: "中考",
    senses: [{ pos: "n.", cn: "生活；生命；一生" }],
  },
  measure: {
    word: "measure", phonetic: "/ˈmeʒər/", level: "考研",
    senses: [
      { pos: "n.", cn: "措施，方法；度量" },
      { pos: "v.", cn: "测量，衡量" },
    ],
    collocations: [{ en: "take measures", cn: "采取措施" }],
  },
  housing: {
    word: "housing", phonetic: "/ˈhaʊzɪŋ/", level: "考研",
    senses: [{ pos: "n.", cn: "住房，住宅；住房供给" }],
  },
  shortage: {
    word: "shortage", phonetic: "/ˈʃɔːrtɪdʒ/", level: "考研",
    senses: [{ pos: "n.", cn: "短缺，不足" }],
    collocations: [{ en: "housing shortage", cn: "住房短缺" }],
  },
  behavior: {
    word: "behavior", phonetic: "/bɪˈheɪvjər/", level: "考研",
    senses: [{ pos: "n.", cn: "行为，举止" }],
  },
  multiple: {
    word: "multiple", phonetic: "/ˈmʌltɪpl/", level: "考研",
    senses: [{ pos: "adj.", cn: "多个的，多种的" }, { pos: "n.", cn: "倍数" }],
  },
  literacy: {
    word: "literacy", phonetic: "/ˈlɪtərəsi/", level: "考研",
    senses: [{ pos: "n.", cn: "读写能力；素养" }],
  },
  judgment: {
    word: "judgment", phonetic: "/ˈdʒʌdʒmənt/", level: "考研",
    senses: [{ pos: "n.", cn: "判断力；判决" }],
  },
  journalist: {
    word: "journalist", phonetic: "/ˈdʒɜːrnəlɪst/", level: "考研",
    senses: [{ pos: "n.", cn: "记者，新闻工作者" }],
  },
  dream: {
    word: "dream", phonetic: "/driːm/", level: "中考",
    senses: [{ pos: "n.", cn: "梦；梦想" }, { pos: "v.", cn: "做梦；梦想" }],
  },
  control: {
    word: "control", phonetic: "/kənˈtroʊl/", level: "四级",
    senses: [{ pos: "n./v.", cn: "控制，支配" }],
  },
  many: { word: "many", phonetic: "/ˈmeni/", level: "中考", senses: [{ pos: "det.", cn: "许多，大量" }] },
  very: { word: "very", phonetic: "/ˈveri/", level: "中考", senses: [{ pos: "adv.", cn: "非常，很" }] },
  have: { word: "have", phonetic: "/hæv/", level: "中考", senses: [{ pos: "v.", cn: "有；吃；经历" }] },
  them: { word: "them", phonetic: "/ðem/", level: "中考", senses: [{ pos: "pron.", cn: "他们，它们（宾格）" }] },
  this: { word: "this", phonetic: "/ðɪs/", level: "中考", senses: [{ pos: "pron.", cn: "这，这个" }] },
  that: { word: "that", phonetic: "/ðæt/", level: "中考", senses: [{ pos: "pron./conj.", cn: "那个；引导从句" }] },
  into: { word: "into", phonetic: "/ˈɪntuː/", level: "中考", senses: [{ pos: "prep.", cn: "进入，到…里面" }] },
  taken: { word: "taken", phonetic: "/ˈteɪkən/", level: "中考", senses: [{ pos: "v.", cn: "take 的过去分词：拿；采取" }] },
};

/* DECK 的词也能查（点例句里的加粗词 / 真题里的原词）。
   注意：DECK 现在启动时由壳灌入，所以这里做成函数，
   在 lookupWord 里按需合并 —— 不能在模块顶层遍历（那时还是空的）。 */
function mergeDeckInto(lex: Record<string, DictEntry>) {
  for (const w of DECK) {
    if (!w || !w.word) continue;
    lex[w.word] = {
      word: w.word,
      phonetic: w.phonetic,
      level: "考研",
      senses: w.senses.map((s) => ({ pos: s.pos, cn: s.cn.join("；") })),
      collocations: w.collocations,
      examples: [
        { en: w.sentence.en, cn: w.sentence.cn, src: "词书例句" },
        ...(w.exams ?? []).map((e) => ({ en: e.en, src: e.src })),
      ],
    };
  }
}

/* ---------- 词形还原（朴素规则） ---------- */
function candidates(raw: string): string[] {
  const w = raw.toLowerCase().replace(/[^a-z'-]/g, "");
  const out = [w];
  if (w.endsWith("ies")) out.push(w.slice(0, -3) + "y");
  if (w.endsWith("es")) out.push(w.slice(0, -2));
  if (w.endsWith("s")) out.push(w.slice(0, -1));
  if (w.endsWith("ing")) out.push(w.slice(0, -3), w.slice(0, -3) + "e");
  if (w.endsWith("ed")) out.push(w.slice(0, -2), w.slice(0, -1), w.slice(0, -2) + "e");
  if (w.endsWith("d")) out.push(w.slice(0, -1));
  return [...new Set(out)].filter(Boolean);
}

const cache = new Map<string, DictEntry | null>();

/* ---------- 查询：本地 → dictionaryapi.dev ---------- */
export async function lookupWord(raw: string): Promise<DictEntry | null> {
  const key = raw.toLowerCase().replace(/[^a-z'-]/g, "");
  if (!key) return null;
  if (cache.has(key)) return cache.get(key) ?? null;

  // 壳灌入的 DECK 词优先（含真题/词组），合并进本地词库视图
  const lex: Record<string, DictEntry> = { ...LEXICON };
  mergeDeckInto(lex);

  for (const c of candidates(key)) {
    if (lex[c]) {
      cache.set(key, lex[c]);
      return lex[c];
    }
  }

  /* 免费开放词典接口（英英，支持 CORS） */
  try {
    const res = await fetch(`https://api.dictionaryapi.dev/api/v2/entries/en/${encodeURIComponent(key)}`);
    if (!res.ok) throw new Error("not found");
    const json = (await res.json()) as Array<{
      word: string;
      phonetic?: string;
      phonetics?: { text?: string }[];
      meanings?: { partOfSpeech: string; definitions: { definition: string; example?: string }[] }[];
    }>;
    const d = json[0];
    const phonetic = d.phonetic || d.phonetics?.find((p) => p.text)?.text;
    const senses = (d.meanings ?? []).slice(0, 3).map((m) => ({
      pos: m.partOfSpeech === "noun" ? "n." : m.partOfSpeech === "verb" ? "v." : m.partOfSpeech === "adjective" ? "adj." : m.partOfSpeech === "adverb" ? "adv." : m.partOfSpeech + ".",
      cn: m.definitions[0]?.definition ?? "",
    }));
    const examples: DictExample[] = [];
    for (const m of d.meanings ?? []) {
      for (const def of m.definitions) {
        if (def.example) examples.push({ en: def.example, src: "Dictionary API" });
        if (examples.length >= 3) break;
      }
      if (examples.length >= 3) break;
    }
    const entry: DictEntry = { word: d.word, phonetic, senses, examples, fromApi: true };
    cache.set(key, entry);
    return entry;
  } catch {
    cache.set(key, null);
    return null;
  }
}
