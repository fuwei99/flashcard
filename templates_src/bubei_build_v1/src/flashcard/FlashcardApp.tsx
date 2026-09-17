import { useEffect, useMemo, useRef, useState } from "react";
import castleBg from "../assets/castle.jpg";
import { DECK, setDeck, SAMPLE_DECK, type WordCard } from "./data";
import { speak } from "./tts";
import { DictLayer, ClickableText } from "./DictPopup";
import SentenceViewer from "./SentenceViewer";
import { PassageRead, PassageCloze } from "./Passage";
import {
  loadDeck,
  commit as bridgeCommit,
  on as bridgeOn,
  post as bridgePost,
  log as bridgeLog,
  hasBridge,
} from "../bridge";

/* ============================================================
   不背单词 · 暗黑风复刻
   主页(Fairytale) + 学习(认识/不认识) + 复习(认识/模糊/忘记了)
   ============================================================ */

type Screen = "home" | "learn" | "review";
type Face = "front" | "back";
type Tab = "colloc" | "deriv" | "syn" | "root" | "note";

const BG = "linear-gradient(168deg, #121214 0%, #131216 55%, #1a1522 100%)";
const LEARN_BG = "linear-gradient(172deg, #131417 0%, #16151b 45%, #2a211d 100%)";

function shuffle<T>(arr: T[], seed: number): T[] {
  const a = [...arr];
  let s = seed;
  for (let i = a.length - 1; i > 0; i--) {
    s = (s * 9301 + 49297) % 233280;
    const j = Math.floor((s / 233280) * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}



/* ---------------- 图标 ---------------- */
const Speaker = ({ cls = "" }: { cls?: string }) => (
  <svg viewBox="0 0 24 24" className={cls} fill="currentColor">
    <path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z" />
  </svg>
);
const Chevron = ({ cls = "" }: { cls?: string }) => (
  <svg viewBox="0 0 24 24" className={cls} fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
    <path d="M15 18l-6-6 6-6" />
  </svg>
);
const Undo = ({ cls = "" }: { cls?: string }) => (
  <svg viewBox="0 0 24 24" className={cls} fill="none" stroke="currentColor" strokeWidth="2.1" strokeLinecap="round" strokeLinejoin="round">
    <path d="M9 14L4 9l5-5" />
    <path d="M4 9h10a6 6 0 0 1 0 12h-3" />
  </svg>
);
const Star = ({ cls = "", filled = false }: { cls?: string; filled?: boolean }) => (
  <svg viewBox="0 0 24 24" className={cls} fill={filled ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.9" strokeLinejoin="round">
    <path d="M12 3l2.7 5.6 6.1.8-4.5 4.2 1.1 6L12 16.7 6.6 19.6l1.1-6L3.2 9.4l6.1-.8L12 3z" />
  </svg>
);
const Dots = ({ cls = "" }: { cls?: string }) => (
  <svg viewBox="0 0 24 24" className={cls} fill="currentColor">
    <circle cx="5" cy="12" r="1.9" /><circle cx="12" cy="12" r="1.9" /><circle cx="19" cy="12" r="1.9" />
  </svg>
);
const NoteAdd = ({ cls = "" }: { cls?: string }) => (
  <svg viewBox="0 0 24 24" className={cls} fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round">
    <path d="M4 20h7" />
    <path d="M14.5 4.5l3 3L8 17l-4 1 1-4 9.5-9.5z" strokeLinejoin="round" />
    <path d="M18 15v5M15.5 17.5h5" strokeWidth="1.7" />
  </svg>
);
const SentSwitch = ({ cls = "" }: { cls?: string }) => (
  <svg viewBox="0 0 24 24" className={cls} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
    <rect x="3.5" y="5" width="17" height="14" rx="3.5" />
    <path d="M7.5 10h6M7.5 14h9" />
  </svg>
);
const TextSearch = ({ cls = "" }: { cls?: string }) => (
  <svg viewBox="0 0 24 24" className={cls} fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round">
    <path d="M4 6h13M4 11h7M4 16h5" />
    <circle cx="16.5" cy="15.5" r="3.4" />
    <path d="M19 18l2.4 2.4" />
  </svg>
);
const Bulb = ({ cls = "" }: { cls?: string }) => (
  <svg viewBox="0 0 24 24" className={cls} fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
    <path d="M9 18h6M10 21h4" />
    <path d="M12 3a6 6 0 0 1 3.5 10.9c-.8.6-1.5 1.3-1.5 2.1h-4c0-.8-.7-1.5-1.5-2.1A6 6 0 0 1 12 3z" />
  </svg>
);

/* ---------------- 顶栏 ---------------- */
function TopBar({
  counter, onBack, canUndo, onUndo, fav, onFav, onKnown, onSpell, onMenu,
}: {
  counter: string; onBack: () => void; canUndo: boolean; onUndo: () => void;
  fav: boolean; onFav: () => void; onKnown?: () => void; onSpell: () => void;
  onMenu?: () => void;
}) {
  return (
    <header className="flex h-[52px] flex-none items-center justify-between pl-4 pr-5 pt-2">
      <button onClick={onBack} className="flex items-center gap-2 text-[#c9c9ce] active:opacity-60">
        <Chevron cls="h-[22px] w-[22px]" />
        <span className="text-[15px] font-medium tabular-nums text-[#b9b9bf]">{counter}</span>
      </button>
      <div className="flex items-center gap-[26px]">
        <button onClick={onUndo} disabled={!canUndo} className={canUndo ? "text-[#a8a8ae] active:opacity-60" : "text-[#4a4a4f]"}>
          <Undo cls="h-[20px] w-[20px]" />
        </button>
        <button onClick={onFav} className={`${fav ? "text-[#f0f0f2]" : "text-[#a8a8ae]"} active:scale-90`}>
          <Star cls="h-[21px] w-[21px]" filled={fav} />
        </button>
        {onKnown && (
          <button onClick={onKnown} className="pb-[2px] text-[16px] font-semibold leading-none text-[#c9c9ce] underline decoration-[#8a8a90] decoration-[1.5px] underline-offset-[5px] active:opacity-60">
            熟
          </button>
        )}
        <button onClick={onSpell} className="pb-[2px] text-[15px] font-bold leading-none tracking-tight text-[#c9c9ce] underline decoration-[#8a8a90] decoration-[1.5px] underline-offset-[5px] active:opacity-60">
          abc
        </button>
        <button onClick={onMenu} className="text-[#a8a8ae] active:opacity-60"><Dots cls="h-[20px] w-[20px]" /></button>
      </div>
    </header>
  );
}

/* ---------------- 单词 Hero（含熟练度小圆点） ---------------- */
function Hero({ word, syllable = false, dots = 1 }: { word: WordCard; syllable?: boolean; dots?: number }) {
  return (
    <div className="px-[34px]">
      <div className="flex items-start gap-[14px]">
        <h1 className="text-[34px] font-extrabold leading-[1.15] tracking-[-0.01em] text-[#f5f5f7]">
          {syllable ? word.syllable : word.word}
        </h1>
        <span className="mt-[14px] flex flex-col gap-[3px]">
          {[0, 1, 2].map((i) => (
            <span key={i} className={`h-[4px] w-[4px] rounded-full ${i >= 3 - dots ? "bg-[#2ec4a5]" : "bg-[#4a4a4f]"}`} />
          ))}
        </span>
      </div>
      <div className="mt-[14px] flex items-center gap-3">
        <button onClick={() => speak(word.word)} className="flex items-center gap-[6px] rounded-full bg-[#29292e] px-[13px] py-[6px] active:scale-95">
          <span className="text-[11px] font-medium text-[#b9b9bf]">美</span>
          <Speaker cls="h-[12px] w-[12px] text-[#b9b9bf]" />
        </button>
        <span className="text-[15px] tracking-wide text-[#b9b9bf]">{word.phonetic}</span>
      </div>
    </div>
  );
}

function SenseLine({
  word,
  onMeaningTap,
}: {
  word: WordCard;
  onMeaningTap?: (meaningIdx: number) => void;
}) {
  const details = word.meaningDetails ?? [];
  return (
    <div className="mt-[22px] space-y-[10px] px-[34px]">
      {word.senses.map((s, si) => (
        <p key={si} className="flex flex-wrap items-baseline gap-x-[18px] gap-y-2">
          <span className="text-[16px] text-[#a8a8ae]">{s.pos}</span>
          {s.cn.map((m, mi) => {
            const dIdx = details.findIndex((d) => d.meaning === m);
            const bound = dIdx >= 0; // 只有绑定例句的词义才有虚线 + 可点
            const primary = si === 0 && mi === 0;
            return (
              <span
                key={mi}
                onClick={bound && onMeaningTap ? () => onMeaningTap(dIdx) : undefined}
                className={`pb-[5px] text-[17px] leading-snug ${
                  bound
                    ? "cursor-pointer underline decoration-dashed decoration-[#5a5a60] decoration-[1.5px] underline-offset-[7px] active:decoration-[#e3a83c] active:text-[#e3a83c]"
                    : ""
                } ${primary ? "font-bold text-[#f0f0f2]" : "font-normal text-[#d5d5da]"}`}
              >
                {m}
              </span>
            );
          })}
        </p>
      ))}
    </div>
  );
}

function Switch({ on, onTap }: { on: boolean; onTap: () => void }) {
  return (
    <button
      onClick={onTap}
      className={`relative h-[28px] w-[50px] flex-none rounded-full transition-colors ${on ? "bg-[#f0a824]" : "bg-[#3a3a44]"}`}
    >
      <span
        className={`absolute top-[3px] h-[22px] w-[22px] rounded-full bg-white shadow transition-all ${on ? "left-[25px]" : "left-[3px]"}`}
      />
    </button>
  );
}

function DashBtn({ label, color, onClick, dim = false }: { label: string; color: string; onClick?: () => void; dim?: boolean }) {
  return (
    <button onClick={onClick} className="flex flex-col items-center gap-[9px] active:opacity-60">
      <span className={`text-[18px] font-semibold ${dim ? "text-[#7c7c82]" : "text-[#ececef]"}`}>{label}</span>
      <span className={`h-[4px] w-[22px] rounded-full ${color}`} />
    </button>
  );
}

/* ---------------- 词义详情（例句卡 + tab 卡） ---------------- */
const TAB_LABELS: Record<Tab, string> = {
  colloc: "词组搭配", deriv: "派生", syn: "近义", root: "词根", note: "笔记",
};

function DetailBody({
  w, tab, setTab, note, onNoteOpen, onExamOpen, onWordTap, selWord, onOpenViewer, onOpenViewerAt, tabOrder,
}: {
  w: WordCard; tab: Tab; setTab: (t: Tab) => void; note: string;
  onNoteOpen: () => void; onExamOpen: () => void;
  onWordTap: (word: string) => void; selWord: string | null;
  onOpenViewer?: () => void;
  onOpenViewerAt?: (m: number) => void;
  tabOrder?: Tab[];
}) {
  const order = tabOrder ?? ["colloc", "deriv", "syn", "root"];
  const tabs: [Tab, string][] = [
    ...order.map((t) => [t, TAB_LABELS[t]] as [Tab, string]),
    ...(note ? ([["note", "笔记"]] as [Tab, string][]) : []),
  ];
  const details = w.meaningDetails ?? [];
  return (
    <>
      <div className="relative mx-4 mt-[22px] rounded-[16px] bg-[#222226]/90 px-[18px] pb-[46px] pt-[17px]">
        <ClickableText
          text={w.sentence.en}
          boldWord={w.word}
          selected={selWord}
          onWord={onWordTap}
          className="text-[17px] leading-[1.55] text-[#ececef]"
        />
        <p className="mt-[6px] text-[15px] leading-relaxed text-[#c5c5ca]">{w.sentence.cn}</p>
        <button
          onClick={() => (onOpenViewer && (w.meaningDetails?.length ?? 0) > 0 ? onOpenViewer() : speak(w.sentence.en))}
          className="absolute bottom-[13px] right-[13px] flex h-[34px] w-[34px] items-center justify-center rounded-full bg-[#2e2e33] text-[#b9b9bf] active:scale-90"
        >
          <SentSwitch cls="h-[17px] w-[17px]" />
        </button>
      </div>

      <div className="mx-4 mb-4 mt-[13px] flex min-h-[280px] flex-1 flex-col rounded-[16px] bg-[#222226]/90 px-[18px] pt-[19px]">
        <div className="flex-1">
          {tab === "colloc" && (
            <div>
              {w.collocations.map((c, ci) => {
                const mIdx = c.m ?? 0;
                const bound = c.m !== -1 && details.length > mIdx;
                return (
                  <p key={c.en} className="mb-[15px] flex items-baseline text-[16px] leading-snug">
                    <span
                      onClick={bound && onOpenViewerAt ? () => onOpenViewerAt(mIdx) : undefined}
                      className={
                        bound
                          ? "cursor-pointer pb-[4px] text-[#ececef] underline decoration-dashed decoration-[#5a5a60] decoration-[1.5px] underline-offset-[6px] active:text-[#e3a83c] active:decoration-[#e3a83c]"
                          : "text-[#ececef]"
                      }
                    >
                      {c.en}
                    </span>
                    <span className="ml-[13px] text-[#d5d5da]">{c.cn}</span>
                    <span className="ml-auto shrink-0 rounded-[4px] bg-[#2e2e33] px-[7px] py-[2px] text-[11px] text-[#8c8c92]">
                      {c.tag ?? (ci % 2 ? "核心高频" : "考研")}
                    </span>
                  </p>
                );
              })}
              <button onClick={onExamOpen} className="mt-[10px] text-[14px] text-[#a8a8ae] active:opacity-60">
                学习所有考研真题词组 <span className="text-[#7c7c82]">›</span>
              </button>
            </div>
          )}
          {tab === "deriv" && (
            <div>
              {(w.derivatives ?? []).map((d) => (
                <p key={d.word} className="mb-[15px] flex items-baseline text-[16px]">
                  {d.word === w.word && <span className="mr-[8px] text-[10px] text-[#e3a83c]">▶</span>}
                  <span
                    onClick={() => onWordTap(d.word)}
                    className="cursor-pointer text-[#ececef] underline decoration-dotted decoration-white/20 decoration-[1.5px] underline-offset-4 active:text-[#f0a824]"
                  >
                    {d.word}
                  </span>
                  <span className="ml-[13px] text-[14px] text-[#a8a8ae]">{d.pos}</span>
                  <span className="ml-[8px] truncate text-[#d5d5da]">{d.cn}</span>
                  <span className="ml-auto shrink-0 rounded-[4px] bg-[#2e2e33] px-[7px] py-[2px] text-[11px] text-[#8c8c92]">考研</span>
                </p>
              ))}
              <button className="mt-[6px] text-[14px] text-[#a8a8ae] active:opacity-60">
                查看全部 15 个派生词 <span className="text-[#7c7c82]">›</span>
              </button>
            </div>
          )}
          {tab === "syn" && (
            <div className="space-y-[15px]">
              {w.synonyms && (
                <p className="flex flex-wrap items-baseline gap-x-[6px] text-[16px] leading-relaxed">
                  <span className="mr-[4px] rounded-[5px] border border-[#4a4a4f] px-[7px] py-[2px] text-[12px] text-[#a8a8ae]">近义</span>
                  {w.synonyms.map((s, i) => (
                    <span
                      key={s}
                      onClick={() => onWordTap(s)}
                      className="cursor-pointer text-[#d5d5da] underline decoration-dotted decoration-white/20 decoration-[1.5px] underline-offset-4 active:text-[#f0a824]"
                    >
                      {s}
                      {i < w.synonyms!.length - 1 ? "," : ""}
                    </span>
                  ))}
                  <span className="ml-auto shrink-0 rounded-[4px] bg-[#2e2e33] px-[7px] py-[2px] text-[11px] text-[#8c8c92]">核心高频</span>
                </p>
              )}
              {w.antonyms && (
                <p className="flex flex-wrap items-baseline gap-x-[6px] text-[16px] leading-relaxed">
                  <span className="mr-[4px] rounded-[5px] border border-[#4a4a4f] px-[7px] py-[2px] text-[12px] text-[#a8a8ae]">反义</span>
                  {w.antonyms.map((s, i) => (
                    <span
                      key={s}
                      onClick={() => onWordTap(s)}
                      className="cursor-pointer text-[#d5d5da] underline decoration-dotted decoration-white/20 decoration-[1.5px] underline-offset-4 active:text-[#f0a824]"
                    >
                      {s}
                      {i < w.antonyms!.length - 1 ? "," : ""}
                    </span>
                  ))}
                  <span className="ml-auto shrink-0 rounded-[4px] bg-[#2e2e33] px-[7px] py-[2px] text-[11px] text-[#8c8c92]">易混辨析</span>
                </p>
              )}
            </div>
          )}
          {tab === "root" && (
            <div>
              {(w.root ?? []).map((r) => (
                <p key={r.text} className="mb-[14px] text-[16px]">
                  <span className="mr-[12px] rounded-[5px] border border-[#4a4a4f] px-[7px] py-[2px] text-[12px] text-[#a8a8ae]">{r.tag}</span>
                  <span className="text-[#ececef]">{r.text}</span>
                </p>
              ))}
              {w.rootSummary && <p className="mt-[4px] text-[16px] leading-[1.7] text-[#ececef]">{w.rootSummary}</p>}
              <button className="mt-[16px] text-[14px] text-[#a8a8ae] active:opacity-60">
                查看更多同根词 <span className="text-[#7c7c82]">›</span>
              </button>
            </div>
          )}
          {tab === "note" && (
            <div>
              <p className="text-[16px] leading-relaxed text-[#ececef]">{note || "暂无笔记"}</p>
              <button onClick={onNoteOpen} className="mt-[16px] flex items-center gap-[6px] text-[14px] text-[#a8a8ae] active:opacity-60">
                编辑笔记
                <svg viewBox="0 0 24 24" className="h-[13px] w-[13px]" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M14.5 4.5l3 3L8 17l-4 1 1-4 9.5-9.5z" />
                </svg>
              </button>
            </div>
          )}
        </div>
        <div className="flex flex-none items-center gap-[6px] pb-[15px] pt-3">
          {tabs.map(([key, label]) => (
            <button
              key={key}
              onClick={() => setTab(key)}
              className={`rounded-[9px] px-[11px] py-[7px] text-[13.5px] transition-colors ${
                tab === key ? "bg-[#38383e] font-semibold text-[#f0f0f2]" : "text-[#8c8c92]"
              }`}
            >
              {label}
            </button>
          ))}
          <span className="flex-1" />
          {!note && (
            <button onClick={onNoteOpen} className="mr-[4px] text-[#a8a8ae] active:scale-90">
              <NoteAdd cls="h-[18px] w-[18px]" />
            </button>
          )}
          <button onClick={onExamOpen} className="flex h-[32px] w-[32px] items-center justify-center rounded-full bg-[#2e2e33] text-[#b9b9bf] active:scale-90">
            <TextSearch cls="h-[16px] w-[16px]" />
          </button>
        </div>
      </div>
    </>
  );
}

/* ---------------- 主页 ---------------- */
function HomeScreen({
  learnCount, reviewCount, onLearn, onReview,
}: {
  learnCount: number; reviewCount: number; onLearn: () => void; onReview: () => void;
}) {
  return (
    <div className="relative flex h-full flex-col overflow-hidden">
      <img src={castleBg} alt="" className="absolute inset-0 h-full w-full object-cover" />
      <div className="absolute inset-0 bg-gradient-to-b from-black/35 via-transparent to-black/70" />

      <div className="relative flex h-full flex-col">
        {/* 头像 */}
        <div className="px-5 pt-5">
          <button className="relative block active:scale-95">
            <span className="flex h-[46px] w-[46px] items-center justify-center rounded-full border-2 border-black/60 bg-[#f7c948] text-[24px] shadow-lg">
              🐶
            </span>
            <span className="absolute -right-1 -top-1 flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-[#e34d64] px-1 text-[11px] font-bold text-white">
              1
            </span>
          </button>
        </div>

        {/* 词书名 */}
        <h1 className="mt-[15%] text-center text-[44px] font-bold tracking-wide text-[#f0f0f2] [text-shadow:0_2px_20px_rgba(0,0,0,0.5)]">
          Fairytale
        </h1>

        <div className="flex-1" />

        {/* Learn / Review 卡片 */}
        <div className="grid grid-cols-2 gap-[13px] px-4">
          {[
            { label: "Learn", n: learnCount, act: onLearn, disabled: learnCount === 0 },
            { label: "Review", n: reviewCount, act: onReview, disabled: reviewCount === 0 },
          ].map((c) => (
            <button
              key={c.label}
              onClick={c.act}
              disabled={c.disabled}
              className="rounded-[16px] bg-[#1c1c20]/75 px-[20px] py-[16px] text-left backdrop-blur-md transition-transform active:scale-[0.97] disabled:opacity-45"
            >
              <span className="block text-[22px] font-bold text-[#ececef]">{c.label}</span>
              <span className="mt-[2px] block text-[17px] font-semibold text-[#e3a83c]">{c.n}</span>
            </button>
          ))}
        </div>

        {/* 底部导航 */}
        <nav className="flex items-center justify-between px-[38px] pb-[26px] pt-[22px]">
          <button className="text-[#e8e8ea] active:opacity-60">
            <svg viewBox="0 0 24 24" className="h-[24px] w-[24px]" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12 4L3 8.5 12 13l9-4.5L12 4z" />
              <path d="M5 11v4.5c0 1.5 3.1 3 7 3s7-1.5 7-3V11" />
            </svg>
          </button>
          <button className="text-[#8c8c92] active:opacity-60">
            <svg viewBox="0 0 24 24" className="h-[24px] w-[24px]" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
              <rect x="3.5" y="4.5" width="17" height="15" rx="2.5" />
              <path d="M3.5 9h17M9 13h6" />
            </svg>
          </button>
          <button className="text-[#8c8c92] active:opacity-60">
            <svg viewBox="0 0 24 24" className="h-[24px] w-[24px]" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
              <rect x="3.5" y="3.5" width="17" height="17" rx="3" />
              <path d="M7.5 14.5l3-3.5 2.5 2 3.5-4.5" />
            </svg>
          </button>
        </nav>
      </div>
    </div>
  );
}

/* ============================================================ */
export default function FlashcardApp() {
  const [screen, setScreen] = useState<Screen>("home");
  /* 全局进度 */
  const [learnedIds, setLearnedIds] = useState<Set<string>>(new Set());
  const [dueIds, setDueIds] = useState<string[]>([]);
  const [favs, setFavs] = useState<Set<string>>(new Set());
  const [notes, setNotes] = useState<Record<string, string>>({});
  /* 壳是否灌过队列 / 是否在拉 */
  const [booted, setBooted] = useState(false);
  const [booting, setBooting] = useState(false);

  /* 会话状态 */
  const [queue, setQueue] = useState<WordCard[]>([]);
  const [idx, setIdx] = useState(0);
  const [face, setFace] = useState<Face>("front");
  const [tab, setTab] = useState<Tab>("colloc");
  const [hinted, setHinted] = useState(false);
  const [missed, setMissed] = useState<string[]>([]);
  const [subPhase, setSubPhase] = useState<"passage" | "cloze" | "cards" | "choice" | "done">("cards");
  const [rIdx, setRIdx] = useState(0);
  const [revealed, setRevealed] = useState(false);
  const [, setPicked] = useState<number | null>(null);
  const [wrongs, setWrongs] = useState(0);
  /* 浮层 */
  const [noteOpen, setNoteOpen] = useState(false);
  const [draft, setDraft] = useState("");
  const [spellOpen, setSpellOpen] = useState(false);
  const [spellInput, setSpellInput] = useState("");
  const [spellState, setSpellState] = useState<"idle" | "right" | "wrong">("idle");
  const [examOpen, setExamOpen] = useState(false);
  /* 点词查词 */
  const [dictWord, setDictWord] = useState<string | null>(null);
  const [dictFavs, setDictFavs] = useState<Set<string>>(new Set());
  /* 例句轮播卡：{ 词, 起始词义序号 } */
  const [sentView, setSentView] = useState<{ w: WordCard; m: number } | null>(null);
  /* 设置 */
  const [menuOpen, setMenuOpen] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [orderOpen, setOrderOpen] = useState(false);
  const [prefs, setPrefs] = useState({
    passage: true,   // 语篇阅读
    cloze: true,     // 语篇填空
    confusion: true, // 易混辨析
    syllable: true,  // 拆分助记
    clozeEx: false,  // 例句填空（学习正面例句挖空）
  });
  const [tabOrder, setTabOrder] = useState<Tab[]>(["colloc", "deriv", "syn", "root"]);
  /* 撤销历史 */
  const [history, setHistory] = useState<{ idx: number; face: Face }[]>([]);
  /* 壳给的书有没有语篇（没有就不进语篇页） */
  const [hasPassage, setHasPassage] = useState(false);
  /* 本会话每张卡的评分（用于 web.finish 汇总 + 去重提交） */
  const ratedRef = useRef<Record<string, "again" | "hard" | "good">>({});

  const togglePref = (k: keyof typeof prefs) => setPrefs((p) => ({ ...p, [k]: !p[k] }));
  const moveTab = (i: number, d: number) => {
    setTabOrder((o) => {
      const j = i + d;
      if (j < 0 || j >= o.length) return o;
      const n = [...o];
      [n[i], n[j]] = [n[j], n[i]];
      return n;
    });
  };

  /* ------- 启动：从壳拉本轮队列 ------- */
  const boot = () => {
    setBooting(true);
    loadDeck()
      .then(({ deck, newIds, reviewIds }) => {
        if (!deck.length) {
          bridgeLog("boot: 壳没给队列，用样本兜底");
          setDeck(SAMPLE_DECK);
          setBooted(true);
          setBooting(false);
          return;
        }
        setDeck(deck);
        setDueIds(reviewIds);
        setLearnedIds(new Set(deck.map((w) => w.id).filter((id) => !newIds.includes(id))));
        setBooted(true);
        setBooting(false);
        bridgeLog(`boot: deck=${deck.length} new=${newIds.length} review=${reviewIds.length}`);
      })
      .catch((e) => {
        bridgeLog(`boot 失败: ${e}`);
        setDeck(SAMPLE_DECK);
        setBooted(true);
        setBooting(false);
      });
  };

  useEffect(() => {
    if (hasBridge) {
      // 壳驱动：等 web.start 再拉队列
      boot();
    } else {
      // 浏览器直开：用样本数据预览
      setDeck(SAMPLE_DECK);
      setBooted(true);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const learnRemaining = DECK.filter((w) => !learnedIds.has(w.id));
  const cur = queue[idx];
  const retestCards = useMemo(() => missed.map((id) => DECK.find((w) => w.id === id)!).filter(Boolean), [missed]);
  const rCur = retestCards[rIdx];
  const activeWord = subPhase === "choice" ? rCur : cur;

  /* ------- 会话启动 ------- */
  const startSession = (mode: "learn" | "review") => {
    const words = mode === "learn"
      ? learnRemaining
      : dueIds.map((id) => DECK.find((w) => w.id === id)!).filter(Boolean);
    if (!words.length) return;
    setQueue(words);
    setIdx(0);
    setFace("front");
    setTab("colloc");
    setHinted(false);
    setMissed([]);
    setHistory([]);
    // 语篇只有「学习」模式有；壳给的卡没有语篇就直进卡片
    setSubPhase(mode === "learn" && prefs.passage && hasPassage ? "passage" : "cards");
    setRIdx(0);
    setRevealed(false);
    setPicked(null);
    setWrongs(0);
    setScreen(mode);
  };

  const exitToHome = () => setScreen("home");

  /* ------- 卡片流转 ------- */
  /* 交评级给壳（唯一动 FSRS 的入口），同一张卡只交一次 */
  const rate = (id: string, r: "again" | "hard" | "good") => {
    const prev = ratedRef.current[id];
    // 取更差的那次：again < hard < good
    const order = { again: 0, hard: 1, good: 2 };
    if (prev && order[prev] <= order[r]) return;
    ratedRef.current[id] = r;
    bridgeCommit(id, r);
  };

  const flip = (miss: boolean) => {
    if (miss && !missed.includes(cur.id)) setMissed((m) => [...m, cur.id]);
    setHistory((h) => [...h, { idx, face: "front" }]);
    setFace("back");
    setTab("colloc");
    rate(cur.id, miss ? "again" : "good");
    speak(cur.word);
  };

  /* 复习三档里的「模糊」：翻到背面，但记 hard（不算错词） */
  const flipHard = () => {
    setHistory((h) => [...h, { idx, face: "front" }]);
    setFace("back");
    setTab("colloc");
    rate(cur.id, "hard");
    speak(cur.word);
  };

  const finishCards = (extraMiss?: string) => {
    const allMissed = extraMiss && !missed.includes(extraMiss) ? [...missed, extraMiss] : missed;
    if (extraMiss) setMissed(allMissed);
    if (screen === "review" && allMissed.length) {
      setRIdx(0);
      setRevealed(false);
      setPicked(null);
      setSubPhase("choice");
    } else {
      commit(allMissed);
      setSubPhase("done");
    }
  };

  const nextCard = (mistake = false) => {
    const miss = mistake ? cur.id : undefined;
    if (mistake && !missed.includes(cur.id)) setMissed((m) => [...m, cur.id]);
    if (mistake) rate(cur.id, "again");
    setHistory((h) => [...h, { idx, face: "back" }]);
    setFace("front");
    setTab("colloc");
    setHinted(false);
    if (idx + 1 < queue.length) setIdx(idx + 1);
    else finishCards(miss);
  };

  const markKnownTop = () => {
    if (screen !== "learn" && screen !== "review") return;
    if (subPhase !== "cards" || !cur) return;
    if (screen === "learn") setLearnedIds((s) => new Set(s).add(cur.id));
    rate(cur.id, "good"); // 标熟 = 已掌握，按 good 落 FSRS
    const nq = queue.filter((w) => w.id !== cur.id);
    setQueue(nq);
    setFace("front");
    setHinted(false);
    if (idx >= nq.length) finishCards();
  };

  /* 完成时落账 */
  const commit = (allMissed: string[]) => {
    if (screen === "learn") {
      setLearnedIds((s) => {
        const n = new Set(s);
        queue.forEach((w) => n.add(w.id));
        return n;
      });
      setDueIds((d) => [...new Set([...d, ...allMissed])]);
    } else {
      setDueIds((d) => {
        const done = queue.map((w) => w.id);
        const keep = d.filter((id) => !done.includes(id));
        return [...new Set([...keep, ...allMissed])];
      });
    }
    // 上报壳：本轮毕业数（标熟 + 认识过的）
    const graduated = Object.keys(ratedRef.current).filter(
      (id) => ratedRef.current[id] !== "again"
    ).length;
    bridgePost("web.progress", { phase: "done", done: queue.length, total: queue.length, graduated });
    bridgePost("web.finish", { graduated });
  };

  /* ------- 四选一（复习错词） ------- */
  const options = useMemo(() => {
    if (!rCur) return [];
    const others = shuffle(DECK.filter((w) => w.id !== rCur.id), rCur.id.charCodeAt(1) * 17).slice(0, 3);
    return shuffle([rCur, ...others], rCur.word.length * 31 + rIdx * 7);
  }, [rCur, rIdx]);

  const pick = (i: number) => {
    if (revealed) return;
    setPicked(i);
    setRevealed(true);
    if (options[i].id !== rCur.id) {
      setWrongs((w) => w + 1);
      rate(rCur.id, "again");
    } else {
      rate(rCur.id, "good");
    }
    speak(rCur.word);
  };

  const nextRetest = () => {
    setRevealed(false);
    setPicked(null);
    if (rIdx + 1 < retestCards.length) setRIdx(rIdx + 1);
    else {
      commit(missed);
      setSubPhase("done");
    }
  };

  /* ------- 浮层 ------- */
  const openNote = () => {
    if (!activeWord) return;
    setDraft(notes[activeWord.id] ?? "");
    setNoteOpen(true);
  };
  const saveNote = () => {
    if (!activeWord) return;
    setNotes((m) => ({ ...m, [activeWord.id]: draft.trim() }));
    setNoteOpen(false);
    if (draft.trim() && face === "back") setTab("note");
  };
  const openSpell = () => {
    setSpellInput("");
    setSpellState("idle");
    setSpellOpen(true);
  };
  const checkSpell = () => {
    if (!activeWord || spellState === "right") return;
    const ok = spellInput.trim().toLowerCase() === activeWord.word;
    setSpellState(ok ? "right" : "wrong");
    if (ok) speak(activeWord.word);
  };
  const toggleFav = () => {
    if (!activeWord) return;
    setFavs((f) => {
      const n = new Set(f);
      if (n.has(activeWord.id)) n.delete(activeWord.id);
      else n.add(activeWord.id);
      return n;
    });
  };

  const counter =
    subPhase === "choice"
      ? `${rIdx + 1}/${retestCards.length}`
      : `${Math.min(idx, queue.length)}/${queue.length}`;

  const sessionBg = screen === "learn" ? LEARN_BG : BG;

  /* ================= 渲染 ================= */
  if (screen === "home") {
    return <HomeScreen learnCount={learnRemaining.length} reviewCount={dueIds.length} onLearn={() => startSession("learn")} onReview={() => startSession("review")} />;
  }

  return (
    <div className="relative flex h-full flex-col overflow-hidden text-[#f0f0f2]" style={{ background: sessionBg }}>
      {(subPhase === "cards" || subPhase === "choice") && activeWord && (
        <TopBar
          counter={counter}
          onBack={exitToHome}
          canUndo={subPhase === "cards" && history.length > 0}
          onUndo={() => {
            if (subPhase !== "cards" || !history.length) return;
            const last = history[history.length - 1];
            setHistory((h) => h.slice(0, -1));
            setIdx(last.idx);
            setFace(last.face);
            setTab("colloc");
            setHinted(false);
          }}
          fav={favs.has(activeWord.id)}
          onFav={toggleFav}
          onKnown={subPhase === "cards" && face === "front" ? markKnownTop : undefined}
          onSpell={openSpell}
          onMenu={() => setMenuOpen(true)}
        />
      )}

      {/* ====== 语篇通读 ====== */}
      {subPhase === "passage" && (
        <PassageRead
          onExit={exitToHome}
          onWordTap={setDictWord}
          onStartCloze={prefs.cloze ? () => setSubPhase("cloze") : undefined}
          onStartCards={() => setSubPhase("cards")}
        />
      )}

      {/* ====== 语篇填空 ====== */}
      {subPhase === "cloze" && (
        <PassageCloze onBack={() => setSubPhase("passage")} onStartCards={() => setSubPhase("cards")} />
      )}

      {/* ====== 学习 · 正面（例句 + 提示一下） ====== */}
      {screen === "learn" && subPhase === "cards" && face === "front" && cur && (
        <>
          <div className="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[52px] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
            <Hero word={cur} />
            <div className="mt-[26px] space-y-[13px] px-[34px]">
              <div className="h-[26px] w-[168px] rounded-full bg-[#222226]" />
              <div className="h-[26px] w-[100px] rounded-full bg-[#222226]" />
            </div>
            {/* 例句卡（学习正面：先只给英文，点词可查） */}
            <div className="mx-4 mt-[56px] rounded-[16px] bg-[#28282c]/80 px-[18px] py-[19px]">
              <ClickableText
                text={
                  prefs.clozeEx
                    ? cur.sentence.en.replace(new RegExp(`${cur.word}\\w*`, "i"), "______")
                    : cur.sentence.en
                }
                boldWord={cur.word}
                selected={dictWord}
                onWord={setDictWord}
                className="text-[17px] leading-[1.6] text-[#ececef]"
              />
              {hinted && <p className="mt-[8px] text-[15px] leading-relaxed text-[#c5c5ca]">{cur.sentence.cn}</p>}
            </div>
          </div>
          {/* 提示一下 */}
          {!hinted && (
            <div className="mb-[26px] flex flex-none flex-col items-center gap-[10px]">
              <button onClick={() => setHinted(true)} className="flex h-[52px] w-[52px] items-center justify-center rounded-full bg-[#2e2e33]/90 text-[#c9c9ce] active:scale-90">
                <Bulb cls="h-[22px] w-[22px]" />
              </button>
              <span className="text-[14px] text-[#7c7c82]">提示一下</span>
            </div>
          )}
          <footer className="grid flex-none grid-cols-2 pb-[34px]">
            <DashBtn label="认识" color="bg-[#2ec4a5]" onClick={() => flip(false)} />
            <DashBtn label="不认识" color="bg-[#e34d64]" onClick={() => flip(true)} />
          </footer>
        </>
      )}

      {/* ====== 复习 · 正面（骨架 + 三档自评） ====== */}
      {screen === "review" && subPhase === "cards" && face === "front" && cur && (
        <>
          <div className="mt-[52px] flex-1">
            <Hero word={cur} />
            <div className="mt-[26px] space-y-[13px] px-[34px]">
              <div className="h-[26px] w-[168px] rounded-full bg-[#222226]" />
              <div className="h-[26px] w-[100px] rounded-full bg-[#222226]" />
            </div>
          </div>
          <p className="mb-[30px] text-center text-[14px] leading-[1.9] text-[#7c7c82]">
            瞬间想起词义，选「认识」<br />思考后想起词义，选「模糊」
          </p>
          <footer className="grid flex-none grid-cols-3 pb-[34px]">
            <DashBtn label="认识" color="bg-[#2ec4a5]" onClick={() => flip(false)} />
            <DashBtn label="模糊" color="bg-[#e3a83c]" onClick={() => flipHard()} />
            <DashBtn label="忘记了" color="bg-[#e34d64]" onClick={() => flip(true)} />
          </footer>
        </>
      )}

      {/* ====== 词义页（学习/复习共用） ====== */}
      {subPhase === "cards" && face === "back" && cur && (
        <>
          <div className="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[46px] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
            <Hero word={cur} syllable={prefs.syllable} />
            <SenseLine word={cur} onMeaningTap={(m) => setSentView({ w: cur, m })} />
            <DetailBody
              w={cur}
              tab={tab}
              setTab={setTab}
              note={notes[cur.id] ?? ""}
              onNoteOpen={openNote}
              onExamOpen={() => setExamOpen(true)}
              onWordTap={setDictWord}
              selWord={dictWord}
              onOpenViewer={() => setSentView({ w: cur, m: 0 })}
              onOpenViewerAt={(m) => setSentView({ w: cur, m })}
              tabOrder={tabOrder}
            />
          </div>
          <footer className="grid flex-none grid-cols-2 pb-[34px] pt-[6px]">
            <DashBtn label="下一词" color="bg-[#2ec4a5]" onClick={() => nextCard()} />
            <DashBtn label="记错了" color="bg-[#e34d64]" onClick={() => nextCard(true)} />
          </footer>
        </>
      )}

      {/* ====== 复习 · 错词四选一 ====== */}
      {subPhase === "choice" && rCur && (
        <>
          <div className="flex min-h-0 flex-1 flex-col overflow-y-auto pt-[52px] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
            <Hero word={rCur} />
            <div className="min-h-[60px] flex-1" />
            <div className="space-y-[13px] px-4 pb-5 pt-8">
              {options.map((o, i) => {
                const isRight = o.id === rCur.id;
                let cls = "bg-[#222226]/90";
                if (revealed) cls = isRight ? "bg-[#1d4239]" : "bg-[#4a1a24]";
                return (
                  <button
                    key={o.id}
                    onClick={() => pick(i)}
                    className={`relative block w-full rounded-[16px] px-[18px] text-left transition-colors duration-200 ${cls} ${revealed ? "py-[17px]" : "py-[21px]"}`}
                  >
                    {revealed && (
                      <span
                        onClick={(e) => {
                          e.stopPropagation();
                          setDictWord(o.word);
                        }}
                        className="mb-[3px] block text-[19px] font-semibold text-[#f0f0f2] underline decoration-dotted decoration-white/25 decoration-[1.5px] underline-offset-4 active:text-[#f0a824]"
                      >
                        {o.word}
                      </span>
                    )}
                    {!revealed && (
                      <>
                        <span className="block text-[15px] text-[#a8a8ae]">{o.senses[0].pos}</span>
                        <span className="mt-[3px] block text-[16.5px] leading-snug text-[#ececef]">{o.senses[0].cn.join("；")}</span>
                      </>
                    )}
                    {revealed && (
                      <span className="block text-[15.5px] leading-snug text-[#d5d5da]/85">
                        {isRight || prefs.confusion ? `${o.senses[0].pos} ${o.senses[0].cn.join("；")}` : "· · ·"}
                      </span>
                    )}
                    {revealed && isRight && (
                      <span
                        onClick={(e) => { e.stopPropagation(); openNote(); }}
                        className="absolute right-[13px] top-1/2 flex h-[36px] w-[36px] -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-[#d5d5da]"
                      >
                        <NoteAdd cls="h-[17px] w-[17px]" />
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          </div>
          <footer className="flex flex-none justify-center pb-[34px] pt-[6px]">
            {revealed ? (
              <DashBtn label="继续" color="bg-[#2ec4a5]" onClick={nextRetest} />
            ) : (
              <DashBtn label="看答案" color="bg-[#e34d64]" onClick={() => { setPicked(null); setRevealed(true); setWrongs((w) => w + 1); rate(rCur.id, "again"); speak(rCur.word); }} />
            )}
          </footer>
        </>
      )}

      {/* ====== 完成页 ====== */}
      {subPhase === "done" && (
        <div className="flex flex-1 flex-col items-center justify-center px-9 pb-12">
          <svg viewBox="0 0 24 24" className="h-[52px] w-[52px]">
            <path fill="#1db373" d="M12 1.6l2.1 1.8 2.7-.5 1 2.6 2.6 1-.5 2.7 1.8 2.1-1.8 2.1.5 2.7-2.6 1-1 2.6-2.7-.5-2.1 1.8-2.1-1.8-2.7.5-1-2.6-2.6-1 .5-2.7L1.6 12l1.8-2.1-.5-2.7 2.6-1 1-2.6 2.7.5L12 1.6z" />
            <path d="M8.4 12.2l2.3 2.3 4.6-4.7" fill="none" stroke="#fff" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
          <h2 className="mt-5 text-[22px] font-bold text-[#f5f5f7]">
            {screen === "learn" ? "本组学习完成" : "本轮复习完成"}
          </h2>
          <p className="mt-2 text-[13.5px] text-[#7c7c82]">
            {queue.length} 词 · 需复习 {missed.length} · 出错 {wrongs}
          </p>
          <div className="mt-9 w-full space-y-[13px]">
            {queue.map((w) => {
              const bad = missed.includes(w.id);
              return (
                <div key={w.id} className="flex items-center justify-between rounded-[14px] bg-[#222226]/90 px-[18px] py-[13px]">
                  <div className="flex items-center gap-3">
                    <span className={`h-[7px] w-[7px] rounded-full ${bad ? "bg-[#e34d64]" : "bg-[#2ec4a5]"}`} />
                    <span className="text-[16px] font-semibold text-[#ececef]">{w.word}</span>
                    {favs.has(w.id) && <Star cls="h-[13px] w-[13px] text-[#e3a83c]" filled />}
                  </div>
                  <span className="max-w-[45%] truncate text-[13px] text-[#8c8c92]">{w.senses[0].cn[0]}</span>
                </div>
              );
            })}
          </div>
          <button onClick={exitToHome} className="mt-10 flex flex-col items-center gap-[9px] active:opacity-60">
            <span className="text-[18px] font-semibold text-[#ececef]">返回主页</span>
            <span className="h-[4px] w-[22px] rounded-full bg-[#2ec4a5]" />
          </button>
        </div>
      )}

      {/* ====== 真题搜索浮层 ====== */}
      {examOpen && activeWord && (
        <div className="absolute inset-0 z-50 flex flex-col" style={{ background: BG }}>
          <div className="flex flex-none items-center gap-3 px-4 pt-[22px]">
            <div className="flex flex-1 items-center gap-2.5 rounded-full bg-[#26262b] px-4 py-[10px]">
              <svg viewBox="0 0 24 24" className="h-[16px] w-[16px] text-[#8c8c92]" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
                <circle cx="11" cy="11" r="6.5" />
                <path d="M16 16l4 4" />
              </svg>
              <span className="flex-1 text-[17px] text-[#ececef]">{activeWord.word}</span>
              <span className="flex h-[18px] w-[18px] items-center justify-center rounded-full bg-[#4a4a4f] text-[11px] text-[#c9c9ce]">✕</span>
            </div>
            <button onClick={() => setExamOpen(false)} className="text-[16px] text-[#c9c9ce] active:opacity-60">取消</button>
          </div>

          <div className="mt-[22px] flex flex-none gap-[30px] border-b border-white/[0.06] px-5 pb-[10px] text-[16px]">
            {["柯林斯", "派生", "词根", "近义", "真题", "笔记"].map((t) => (
              <span key={t} className={`relative pb-[2px] ${t === "真题" ? "font-semibold text-[#f0f0f2]" : "text-[#8c8c92]"}`}>
                {t}
                {t === "真题" && <span className="absolute -bottom-[11px] left-1/2 h-[3px] w-[22px] -translate-x-1/2 rounded-full bg-[#e3a83c]" />}
              </span>
            ))}
          </div>

          <div className="mt-[16px] flex flex-none flex-wrap gap-[10px] px-4">
            {["中考", "高考", "四级", "六级", "考研", "专升本", "雅思"].map((lv) => (
              <span
                key={lv}
                className={`rounded-full px-[19px] py-[7px] text-[14px] ${
                  lv === "考研" ? "bg-[#e3a83c] font-semibold text-[#241a05]" : "bg-[#26262b] text-[#8c8c92]"
                }`}
              >
                {lv}
              </span>
            ))}
          </div>

          <div className="mt-[18px] min-h-0 flex-1 overflow-y-auto px-5 pb-24 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
            <p className="mb-[18px] flex items-center gap-2 text-[14px] text-[#a8a8ae]">
              <svg viewBox="0 0 24 24" className="h-[15px] w-[15px]" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                <path d="M3 11l14-5v12L3 13v-2z" /><path d="M7 13.5V17a2 2 0 0 0 4 0" />
              </svg>
              在历年真题中出现 <b className="text-[#e3a83c]">{activeWord.exams?.length ?? 0}</b> 次
            </p>
            {(activeWord.exams ?? []).length === 0 && (
              <p className="mt-10 text-center text-[14px] text-[#5a5a60]">该词暂无真题记录</p>
            )}
            {(activeWord.exams ?? []).map((ex, i) => (
              <div key={i} className="mb-[26px]">
                <ClickableText
                  text={ex.en}
                  boldWord={activeWord.word}
                  selected={dictWord}
                  onWord={setDictWord}
                  className="text-[17px] leading-[1.6] text-[#ececef]"
                />
                <p className="mt-[7px] text-[13.5px] text-[#7c7c82]">{ex.src}</p>
              </div>
            ))}
          </div>

          <button
            onClick={() => setExamOpen(false)}
            className="absolute bottom-[26px] right-[22px] flex h-[54px] w-[54px] items-center justify-center rounded-full bg-[#2b2b3a]/90 text-[#ececef] shadow-lg backdrop-blur active:scale-90"
          >
            <svg viewBox="0 0 24 24" className="h-[20px] w-[20px]" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>
      )}

      {/* ====== 笔记浮层 ====== */}
      {noteOpen && activeWord && (
        <div className="absolute inset-0 z-50 flex flex-col" style={{ background: BG }}>
          <p className="pb-2 pt-[26px] text-center text-[17px] font-semibold text-[#ececef]">{activeWord.word} 的笔记</p>
          <div className="mx-4 mt-[100px] flex h-[46%] flex-col rounded-[16px] bg-[#26262b] p-[17px]">
            <textarea
              value={draft}
              onChange={(e) => setDraft(e.target.value.slice(0, 1000))}
              placeholder="写下你的笔记..."
              autoFocus
              className="w-full flex-1 resize-none bg-transparent text-[16px] leading-relaxed text-[#ececef] caret-[#e3a83c] outline-none placeholder:text-[#7c7c82]"
            />
            <div className="flex flex-none items-center gap-[9px] pt-3">
              <span className="rounded-full bg-[#37373d] px-[13px] py-[6px] text-[13px] text-[#c5c5ca]">{activeWord.word}</span>
              <span className="max-w-[180px] truncate rounded-full bg-[#37373d] px-[13px] py-[6px] text-[13px] text-[#c5c5ca]">
                {activeWord.senses[0].pos}
                {activeWord.senses[0].cn.join("；")}
              </span>
              <span className="flex-1" />
              <span className="text-[13px] tabular-nums text-[#7c7c82]">{draft.length}/1000</span>
            </div>
          </div>
          <div className="flex flex-1 items-end justify-between px-4 pb-[30px]">
            <button onClick={() => setNoteOpen(false)} className="flex h-[52px] w-[52px] items-center justify-center rounded-[16px] bg-[#26262b] text-[#ececef] active:scale-95">
              <svg viewBox="0 0 24 24" className="h-[20px] w-[20px]" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
                <path d="M6 6l12 12M18 6L6 18" />
              </svg>
            </button>
            <button
              onClick={saveNote}
              className={`flex h-[52px] w-[52px] items-center justify-center rounded-[16px] transition-colors active:scale-95 ${
                draft.trim() ? "bg-[#2ec4a5] text-[#0c2620]" : "bg-[#26262b] text-[#5a5a60]"
              }`}
            >
              <svg viewBox="0 0 24 24" className="h-[21px] w-[21px]" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M5 12.5l4.5 4.5L19 7.5" />
              </svg>
            </button>
          </div>
        </div>
      )}

      {/* ====== 拼写浮层 ====== */}
      {spellOpen && activeWord && (
        <div className="absolute inset-0 z-50 flex flex-col" style={{ background: BG }}>
          <p className="pb-2 pt-[26px] text-center text-[17px] font-semibold text-[#ececef]">拼写测验</p>
          <div className="flex-1 px-[34px] pt-[70px]">
            <p className="text-[18px] leading-relaxed text-[#ececef]">
              <span className="mr-3 text-[15px] text-[#a8a8ae]">{activeWord.senses[0].pos}</span>
              {activeWord.senses[0].cn.join("；")}
            </p>
            <input
              value={spellInput}
              onChange={(e) => {
                setSpellInput(e.target.value);
                if (spellState === "wrong") setSpellState("idle");
              }}
              onKeyDown={(e) => e.key === "Enter" && checkSpell()}
              autoFocus
              autoComplete="off"
              spellCheck={false}
              placeholder="拼出对应的英文单词"
              disabled={spellState === "right"}
              className={`mt-[44px] w-full border-b-2 bg-transparent pb-[10px] font-mono text-[26px] tracking-[0.12em] outline-none transition-colors placeholder:text-[15px] placeholder:tracking-normal placeholder:text-[#5a5a60] ${
                spellState === "right"
                  ? "border-[#2ec4a5] text-[#2ec4a5]"
                  : spellState === "wrong"
                  ? "border-[#e34d64] text-[#e34d64]"
                  : "border-[#3a3a40] text-[#f0f0f2] focus:border-[#8a8a90]"
              }`}
            />
            <div className="mt-[22px] min-h-[30px]">
              {spellState === "right" && <p className="text-[15px] font-medium text-[#2ec4a5]">拼写正确</p>}
              {spellState === "wrong" && <p className="text-[15px] font-medium text-[#e34d64]">再想想，或直接返回</p>}
            </div>
          </div>
          <footer className="grid flex-none grid-cols-2 pb-[34px]">
            <DashBtn label="返回" color="bg-[#5a5a60]" onClick={() => setSpellOpen(false)} dim />
            {spellState === "right" ? (
              <DashBtn label="完成" color="bg-[#2ec4a5]" onClick={() => setSpellOpen(false)} />
            ) : (
              <DashBtn label="检查" color="bg-[#2ec4a5]" onClick={checkSpell} />
            )}
          </footer>
        </div>
      )}

      {/* ====== 例句轮播卡 ====== */}
      {sentView && (
        <SentenceViewer
          word={sentView.w}
          startMeaning={sentView.m}
          onClose={() => setSentView(null)}
          onNextWord={subPhase === "cards" && face === "back" ? () => nextCard() : undefined}
        />
      )}

      {/* ====== 点词查词浮层 ====== */}
      {dictWord && (
        <DictLayer
          word={dictWord}
          onClose={() => setDictWord(null)}
          isFav={(w) => dictFavs.has(w)}
          onToggleFav={(w) =>
            setDictFavs((f) => {
              const n = new Set(f);
              if (n.has(w)) n.delete(w);
              else n.add(w);
              return n;
            })
          }
        />
      )}

      {/* ====== ••• 菜单下拉 ====== */}
      {menuOpen && (
        <div className="absolute inset-0 z-[72]" onClick={() => setMenuOpen(false)}>
          <div
            className="absolute right-[14px] top-[54px] w-[216px] overflow-hidden rounded-[18px] bg-[#262c44] shadow-[0_16px_50px_rgba(0,0,0,0.55)]"
            onClick={(e) => e.stopPropagation()}
          >
            {[
              {
                label: "设置",
                icon: (
                  <svg viewBox="0 0 24 24" className="h-[20px] w-[20px]" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round">
                    <path d="M4 7h10M18 7h2M4 17h2M10 17h10" />
                    <circle cx="15.5" cy="7" r="2.2" />
                    <circle cx="7.5" cy="17" r="2.2" />
                  </svg>
                ),
                act: () => {
                  setMenuOpen(false);
                  setSettingsOpen(true);
                },
              },
              {
                label: "沉浸场景",
                icon: (
                  <svg viewBox="0 0 24 24" className="h-[20px] w-[20px]" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                    <circle cx="12" cy="12" r="8.5" />
                    <path d="M13.5 8.5v5.2a2 2 0 1 1-1.4-1.9V8.5l3.4-1v2.2" />
                  </svg>
                ),
                act: () => setMenuOpen(false),
              },
              {
                label: "小窍门",
                icon: <Bulb cls="h-[20px] w-[20px]" />,
                act: () => setMenuOpen(false),
              },
              {
                label: "纠错｜举报",
                icon: (
                  <svg viewBox="0 0 24 24" className="h-[20px] w-[20px]" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M17 3l4 4-11 11-5 1 1-5L17 3z" />
                    <path d="M14.5 5.5l4 4" />
                  </svg>
                ),
                act: () => setMenuOpen(false),
              },
            ].map((it, i) => (
              <button
                key={it.label}
                onClick={it.act}
                className={`flex w-full items-center gap-[14px] px-[20px] py-[16px] text-left text-[#ececef] active:bg-white/5 ${
                  i > 0 ? "border-t border-white/[0.07]" : ""
                }`}
              >
                <span className="text-[#c9cfdf]">{it.icon}</span>
                <span className="text-[16px]">{it.label}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {/* ====== 学习设置抽屉 ====== */}
      {settingsOpen && (
        <div className="absolute inset-0 z-[74] flex flex-col justify-end bg-black/55" onClick={() => setSettingsOpen(false)}>
          <div className="rounded-t-[24px] bg-[#1e2338] px-5 pb-[34px] pt-[18px]" onClick={(e) => e.stopPropagation()}>
            <div className="relative mb-[18px]">
              <p className="text-center text-[17px] font-semibold text-[#ececef]">学习设置</p>
              <button
                onClick={() => setSettingsOpen(false)}
                className="absolute right-0 top-1/2 flex h-[30px] w-[30px] -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-[#c9cfdf] active:scale-90"
              >
                <svg viewBox="0 0 24 24" className="h-[14px] w-[14px]" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
                  <path d="M6 6l12 12M18 6L6 18" />
                </svg>
              </button>
            </div>

            {(
              [
                ["passage", "语篇阅读", "学习前先通读语篇"],
                ["cloze", "语篇填空", "通读后进行选词填空"],
                ["confusion", "易混辨析", "显示选择题错误选项词义"],
                ["syllable", "拆分助记", "词义页自动音节拆分"],
                ["clozeEx", "例句填空", "学习正面例句挖空目标词"],
              ] as [keyof typeof prefs, string, string][]
            ).map(([key, label, desc]) => (
              <div key={key} className="mb-[6px] flex items-center justify-between rounded-[14px] px-[6px] py-[10px]">
                <div>
                  <p className="text-[16px] font-medium text-[#ececef]">{label}</p>
                  <p className="mt-[2px] text-[12.5px] text-[#8a91a8]">{desc}</p>
                </div>
                <Switch on={prefs[key]} onTap={() => togglePref(key)} />
              </div>
            ))}

            <button
              onClick={() => {
                setSettingsOpen(false);
                setOrderOpen(true);
              }}
              className="mt-[8px] flex w-full items-center justify-between rounded-[14px] px-[6px] py-[12px] active:bg-white/5"
            >
              <span className="text-[16px] font-medium text-[#ececef]">助记顺序</span>
              <span className="max-w-[60%] truncate text-[13.5px] text-[#8a91a8]">
                {tabOrder.map((t) => TAB_LABELS[t]).join(" - ")} <span className="text-[#5a6178]">›</span>
              </span>
            </button>
          </div>
        </div>
      )}

      {/* ====== 助记顺序抽屉 ====== */}
      {orderOpen && (
        <div className="absolute inset-0 z-[74] flex flex-col justify-end bg-black/55" onClick={() => setOrderOpen(false)}>
          <div className="rounded-t-[24px] bg-[#1e2338] px-5 pb-[34px] pt-[18px]" onClick={(e) => e.stopPropagation()}>
            <div className="relative mb-[18px]">
              <p className="text-center text-[17px] font-semibold text-[#ececef]">助记顺序</p>
              <button
                onClick={() => {
                  setOrderOpen(false);
                  setSettingsOpen(true);
                }}
                className="absolute right-0 top-1/2 flex h-[30px] w-[30px] -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-[#c9cfdf] active:scale-90"
              >
                <svg viewBox="0 0 24 24" className="h-[14px] w-[14px]" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
                  <path d="M6 6l12 12M18 6L6 18" />
                </svg>
              </button>
            </div>

            {tabOrder.map((t, i) => (
              <div key={t} className="mb-[10px] flex items-center justify-between rounded-[14px] bg-[#262c44] px-[18px] py-[15px]">
                <span className="text-[16px] text-[#ececef]">{TAB_LABELS[t]}</span>
                <span className="flex items-center gap-[10px]">
                  <button
                    onClick={() => moveTab(i, -1)}
                    disabled={i === 0}
                    className="flex h-[30px] w-[30px] items-center justify-center rounded-full bg-white/10 text-[#c9cfdf] active:scale-90 disabled:opacity-25"
                  >
                    <svg viewBox="0 0 24 24" className="h-[14px] w-[14px]" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M12 19V5M5 12l7-7 7 7" />
                    </svg>
                  </button>
                  <button
                    onClick={() => moveTab(i, 1)}
                    disabled={i === tabOrder.length - 1}
                    className="flex h-[30px] w-[30px] items-center justify-center rounded-full bg-white/10 text-[#c9cfdf] active:scale-90 disabled:opacity-25"
                  >
                    <svg viewBox="0 0 24 24" className="h-[14px] w-[14px]" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
                      <path d="M12 5v14M5 12l7 7 7-7" />
                    </svg>
                  </button>
                </span>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
