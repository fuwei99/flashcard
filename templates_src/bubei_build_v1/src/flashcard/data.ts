export interface Sense {
  pos: string;
  cn: string[];
}

export interface SenseExample {
  en: string;
  cn: string;
  src: string;
}

/** 词义 ↔ 例句绑定：meaning 必须与某个 sense.cn 完全一致 */
export interface MeaningDetail {
  meaning: string;
  enDef?: string;   // 英文释义（例句卡下半屏）
  pattern?: string; // 用法框，如 ~ (for sth)
  examples: SenseExample[];
}

export interface WordCard {
  id: string;
  word: string;
  syllable: string;
  phonetic: string;
  verified?: boolean;
  senses: Sense[];
  sentence: { en: string; cn: string };
  /** m: 绑定的词义序号（-1 = 无绑定例句，不划虚线）; tag: 右侧标签 */
  collocations: { en: string; cn: string; m?: number; tag?: string }[];
  derivatives?: { word: string; pos: string; cn: string }[];
  synonyms?: string[];
  antonyms?: string[];
  root?: { tag: string; text: string }[];
  rootSummary?: string;
  exams?: { en: string; src: string }[];
  meaningDetails?: MeaningDetail[];
}

/* 语篇：{{word}} 标记目标词（供通读高亮 + 填空挖空） */
export const PASSAGE = {
  title: "Campus Voices",
  tag: "语篇通读",
  en: "The housing shortage remains a key {{component}} of campus life debates. Last month, a peaceful forum turned into an unfortunate {{incident}} when a minor dispute began to {{escalate}}. Officials promised a campus-wide {{referendum}} to hear every voice, hoping to {{alleviate}} the tension. The decision had a {{profound}} impact on students, and many called it a {{terrific}} step forward.",
  cn: "住房短缺仍是校园生活争论的关键组成部分。上个月，一场和平论坛因一次小小的争执逐步升级，演变成一起不幸的事件。校方承诺举行全校公投以倾听每个人的声音，希望以此缓解紧张情绪。这一决定对学生产生了深远影响，许多人称其为极好的一步。",
};

/* ------------------------------------------------------------
   装成模板后，DECK 不再是硬编码真源 —— 启动时由 bridge.loadDeck()
   从壳的 session.plan 拉进这个数组（原地 mutate，保持 const 绑定，
   所有 import 方都能看到更新）。下面的样本数据只在浏览器直开
   （无壳）时兜底，方便本地预览。
   ------------------------------------------------------------ */
export const DECK: WordCard[] = [];

/** 壳注入的卡原地写入 DECK（保持引用不变） */
export function setDeck(d: WordCard[]) {
  DECK.length = 0;
  DECK.push(...d);
}

/** 浏览器直开预览用的样本（不参与模板运行） */
export const SAMPLE_DECK: WordCard[] = [
  {
    id: "w0",
    word: "component",
    syllable: "com·po·nent",
    phonetic: "/kəmˈpoʊnənt/",
    senses: [
      { pos: "n.", cn: ["成分，部件，组成部分"] },
      { pos: "adj.", cn: ["组成的，构成的"] },
    ],
    sentence: {
      en: "Televisions and computers have many components in them.",
      cn: "电视机和电脑拥有很多部件。",
    },
    collocations: [
      { en: "a key component", cn: "关键组成部分" },
      { en: "an electronic component", cn: "电子零件" },
    ],
    derivatives: [
      { word: "compose", pos: "v.", cn: "组成；使平静；写作" },
      { word: "component", pos: "n.", cn: "成分，组成部分" },
      { word: "composition", pos: "n.", cn: "构成；作品；创作" },
    ],
    synonyms: ["element", "part", "constituent"],
    root: [
      { tag: "前缀", text: "com- = 共同，一起" },
      { tag: "词根", text: "pon = 放置" },
    ],
    rootSummary: "component = 放在一起的东西 ⇨ 组成整体的部分 ⇨ 成分，部件",
    exams: [
      { en: "Most work-related behaviors have multiple components.", src: "考研二 2021 完形" },
      {
        en: "Together, they make up the reading component of your overall literacy, or relationship to your surrounding textual environment.",
        src: "考研一 2015 阅读",
      },
      {
        en: "Sharpening judgment by absorbing and reflecting on law is a desirable component of a journalist's intellectual preparation for his or her career.",
        src: "考研一 2007 阅读",
      },
      {
        en: "Of all the components of a good night's sleep, dreams seem to be least within our control.",
        src: "考研一 2005 阅读",
      },
    ],
    meaningDetails: [
      {
        meaning: "成分，部件，组成部分",
        enDef: "one of several parts of which sth is made （机器、系统等的）组成部分，部件",
        pattern: "~ (of / in sth)",
        examples: [
          { en: "Televisions and computers have many components in them.", cn: "电视机和电脑拥有很多部件。", src: "词书例句" },
          { en: "Trust is a vital component in any relationship.", cn: "信任是任何一段关系中至关重要的组成部分。", src: "柯林斯" },
          { en: "The factory supplies electrical components for cars.", cn: "这家工厂为汽车供应电气元件。", src: "牛津词典" },
        ],
      },
    ],
  },
  {
    id: "w1",
    word: "terrific",
    syllable: "te·rri·fic",
    phonetic: "/təˈrɪfɪk/",
    verified: true,
    senses: [{ pos: "adj.", cn: ["极好的", "极大的，巨大的"] }],
    sentence: { en: "Girls! That was a terrific show!", cn: "姑娘们，你们的表演太棒啦！" },
    collocations: [
      { en: "a terrific idea", cn: "超棒的主意" },
      { en: "a terrific time", cn: "愉快的时光" },
    ],
    derivatives: [{ word: "terrifically", pos: "adv.", cn: "非常，极其" }],
    synonyms: ["fantastic", "marvelous", "superb"],
    antonyms: ["terrible", "awful"],
    root: [
      { tag: "词根", text: "terr = 使惊吓，使恐惧" },
      { tag: "后缀", text: "-fic = 造成…的" },
    ],
    rootSummary: "terrific = 原义「令人惊恐的」⇨ 语义弱化转褒 ⇨ 好得惊人的，极好的",
    meaningDetails: [
      {
        meaning: "极好的",
        enDef: "extremely good; wonderful 极好的，绝妙的",
        examples: [
          { en: "Girls! That was a terrific show!", cn: "姑娘们，你们的表演太棒啦！", src: "词书例句" },
          { en: "You look terrific in that dress.", cn: "你穿那条裙子好看极了。", src: "老友记" },
        ],
      },
      {
        meaning: "极大的，巨大的",
        enDef: "very great in amount or degree 极大的，异乎寻常的",
        examples: [
          { en: "The plane crashed with a terrific bang.", cn: "飞机在一声巨响中坠毁。", src: "柯林斯" },
          { en: "He is under terrific pressure at work.", cn: "他工作压力非常大。", src: "牛津词典" },
        ],
      },
    ],
  },
  {
    id: "w2",
    word: "escalate",
    syllable: "es·ca·late",
    phonetic: "/ˈeskəleɪt/",
    senses: [{ pos: "v.", cn: ["（使）逐步升级", "（使）逐步扩大"] }],
    sentence: {
      en: "The fighting escalated into a full-scale war.",
      cn: "这场战斗逐步升级为全面战争。",
    },
    collocations: [
      { en: "escalate into", cn: "升级为" },
      { en: "escalating costs", cn: "不断上涨的成本" },
    ],
    derivatives: [
      { word: "escalation", pos: "n.", cn: "升级，扩大" },
      { word: "escalator", pos: "n.", cn: "自动扶梯" },
    ],
    synonyms: ["intensify", "worsen"],
    antonyms: ["de-escalate", "diminish"],
    root: [
      { tag: "词根", text: "scal = 梯子，攀登" },
      { tag: "前缀", text: "e- = 向外，向上" },
    ],
    rootSummary: "escalate = 沿梯子向上 ⇨ 步步登高 ⇨ 逐步升级",
    meaningDetails: [
      {
        meaning: "（使）逐步升级",
        enDef: "to become or make sth greater, worse, more serious（使）扩大，加剧，恶化",
        pattern: "~ (into sth)",
        examples: [
          { en: "The fighting escalated into a full-scale war.", cn: "这场战斗逐步升级为全面战争。", src: "词书例句" },
          { en: "Officials fear the conflict could escalate further.", cn: "官员们担心冲突可能进一步升级。", src: "NPR 听力" },
        ],
      },
    ],
  },
  {
    id: "w3",
    word: "referendum",
    syllable: "refe·ren·dum",
    phonetic: "/ˌrefəˈrendəm/",
    verified: true,
    senses: [{ pos: "n.", cn: ["全民投票，全民公投"] }],
    sentence: {
      en: "I am collecting signatures for a national referendum.",
      cn: "我为全国公民投票收集签名。",
    },
    collocations: [
      { en: "hold a referendum", cn: "举行全民公投", tag: "核心高频" },
      { en: "a referendum on", cn: "就…进行公投", m: -1 },
    ],
    derivatives: [{ word: "refer", pos: "v.", cn: "提交；参考" }],
    synonyms: ["plebiscite", "public vote"],
    root: [
      { tag: "前缀", text: "re- = 再；回，向后；加强语气" },
      { tag: "词根", text: "fer = 携带，搬运" },
    ],
    rootSummary: "referendum = 来自拉丁语 referendum (参考对象) ⇨ 公民投票，全民公决",
    meaningDetails: [
      {
        meaning: "全民投票，全民公投",
        enDef: "an occasion when all the people of a country can vote on an important issue 全民公决，全民公投",
        pattern: "~ (on sth)",
        examples: [
          { en: "I am collecting signatures for a national referendum.", cn: "我为全国公民投票收集签名。", src: "词书例句" },
          { en: "The country held a referendum on independence.", cn: "该国就独立问题举行了全民公投。", src: "BBC 新闻" },
        ],
      },
    ],
  },
  {
    id: "w4",
    word: "incident",
    syllable: "in·ci·dent",
    phonetic: "/ˈɪnsɪdənt/",
    senses: [{ pos: "n.", cn: ["事件", "(两国间的) 冲突"] }],
    sentence: { en: "This was a very unfortunate incident.", cn: "这是一次非常不幸的事件。" },
    collocations: [
      { en: "an unfortunate incident", cn: "不幸的事件" },
      { en: "a shooting incident", cn: "枪击事件" },
    ],
    derivatives: [
      { word: "incidence", pos: "n.", cn: "发生 (率)" },
      { word: "incidentally", pos: "adv.", cn: "顺便提一句" },
    ],
    synonyms: ["event", "occurrence", "episode"],
    root: [
      { tag: "前缀", text: "in- = 在…上，向内" },
      { tag: "词根", text: "cid = 落下，降临" },
    ],
    rootSummary: "incident = 落到头上的事 ⇨ 发生的事件，(偶发的) 冲突",
    meaningDetails: [
      {
        meaning: "事件",
        enDef: "something that happens, especially sth unusual or unpleasant 事件，事故",
        examples: [
          { en: "This was a very unfortunate incident.", cn: "这是一次非常不幸的事件。", src: "词书例句" },
          { en: "The incident was caught on camera.", cn: "这一事件被摄像机拍了下来。", src: "NPR 听力" },
          { en: "Police are investigating the incident.", cn: "警方正在调查这一事件。", src: "BBC 新闻" },
        ],
      },
      {
        meaning: "(两国间的) 冲突",
        enDef: "a serious or violent event, such as a crime, an accident or an attack （两国间的）冲突，摩擦",
        examples: [
          { en: "The border incident raised tensions between the two countries.", cn: "边境冲突加剧了两国间的紧张局势。", src: "NPR 听力" },
        ],
      },
    ],
  },
  {
    id: "w5",
    word: "profound",
    syllable: "pro·found",
    phonetic: "/prəˈfaʊnd/",
    verified: true,
    senses: [{ pos: "adj.", cn: ["深刻的，深远的", "渊博的"] }],
    sentence: {
      en: "The Internet has had a profound impact on our lives.",
      cn: "互联网对我们的生活产生了深远的影响。",
    },
    collocations: [
      { en: "a profound impact", cn: "深远的影响" },
      { en: "profound changes", cn: "深刻的变化" },
    ],
    derivatives: [{ word: "profoundly", pos: "adv.", cn: "深刻地，极大地" }],
    synonyms: ["deep", "far-reaching"],
    antonyms: ["superficial", "shallow"],
    root: [
      { tag: "前缀", text: "pro- = 向前，在前" },
      { tag: "词根", text: "found = 底部，基础" },
    ],
    rootSummary: "profound = 直达底部的 ⇨ 深的 ⇨ 深刻的，意义深远的",
    meaningDetails: [
      {
        meaning: "深刻的，深远的",
        enDef: "very great; felt or experienced very strongly 巨大的，深切的，深远的",
        examples: [
          { en: "The Internet has had a profound impact on our lives.", cn: "互联网对我们的生活产生了深远的影响。", src: "词书例句" },
          { en: "Her death was a profound shock to all of us.", cn: "她的去世让我们所有人深感震惊。", src: "柯林斯" },
        ],
      },
    ],
  },
  {
    id: "w6",
    word: "alleviate",
    syllable: "al·le·vi·ate",
    phonetic: "/əˈliːvieɪt/",
    senses: [{ pos: "v.", cn: ["减轻，缓解"] }],
    sentence: {
      en: "Measures were taken to alleviate the housing shortage.",
      cn: "已采取措施缓解住房短缺问题。",
    },
    collocations: [
      { en: "alleviate poverty", cn: "缓解贫困" },
      { en: "alleviate the pain", cn: "减轻疼痛" },
    ],
    derivatives: [{ word: "alleviation", pos: "n.", cn: "减轻，缓解" }],
    synonyms: ["relieve", "ease", "mitigate"],
    antonyms: ["aggravate", "worsen"],
    root: [
      { tag: "前缀", text: "al- = 去，向 (=ad-)" },
      { tag: "词根", text: "lev = 轻" },
    ],
    rootSummary: "alleviate = 使变轻 ⇨ 减轻 (痛苦、问题)，缓解",
    meaningDetails: [
      {
        meaning: "减轻，缓解",
        enDef: "to make sth less severe 减轻，缓和，缓解",
        examples: [
          { en: "Measures were taken to alleviate the housing shortage.", cn: "已采取措施缓解住房短缺问题。", src: "词书例句" },
          { en: "The drugs did nothing to alleviate her pain.", cn: "药物丝毫没有减轻她的疼痛。", src: "牛津词典" },
        ],
      },
    ],
  },
];
