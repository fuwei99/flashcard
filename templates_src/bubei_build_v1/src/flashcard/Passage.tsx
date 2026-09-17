import { useMemo, useState } from "react";
import { PASSAGE } from "./data";
import { speak } from "./tts";
import { ClickableText } from "./DictPopup";

/* ============================================================
   语篇通读 + 语篇填空（不背单词暗黑风）
   数据来自 PASSAGE，{{word}} 为目标词标记
   ============================================================ */

type Part = { type: "text"; text: string } | { type: "word"; word: string };

function parsePassage(en: string): Part[] {
  const out: Part[] = [];
  const re = /\{\{(.+?)\}\}/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(en))) {
    if (m.index > last) out.push({ type: "text", text: en.slice(last, m.index) });
    out.push({ type: "word", word: m[1] });
    last = m.index + m[0].length;
  }
  if (last < en.length) out.push({ type: "text", text: en.slice(last) });
  return out;
}

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

function DashBtn({ label, color, onClick, dim = false }: { label: string; color: string; onClick?: () => void; dim?: boolean }) {
  return (
    <button onClick={onClick} className="flex flex-col items-center gap-[9px] active:opacity-60">
      <span className={`text-[18px] font-semibold ${dim ? "text-[#7c7c82]" : "text-[#ececef]"}`}>{label}</span>
      <span className={`h-[4px] w-[22px] rounded-full ${color}`} />
    </button>
  );
}

function Head({ title, onBack, onSpeak }: { title: string; onBack: () => void; onSpeak?: () => void }) {
  return (
    <header className="flex h-[52px] flex-none items-center justify-between pl-4 pr-5 pt-2">
      <button onClick={onBack} className="flex items-center gap-2 text-[#c9c9ce] active:opacity-60">
        <Chevron cls="h-[22px] w-[22px]" />
        <span className="text-[15px] font-medium text-[#b9b9bf]">{title}</span>
      </button>
      {onSpeak && (
        <button onClick={onSpeak} className="flex h-[34px] w-[34px] items-center justify-center rounded-full bg-[#29292e] text-[#b9b9bf] active:scale-90">
          <Speaker cls="h-[16px] w-[16px]" />
        </button>
      )}
    </header>
  );
}

/* ================= 语篇通读 ================= */
export function PassageRead({
  onExit,
  onWordTap,
  onStartCloze,
  onStartCards,
}: {
  onExit: () => void;
  onWordTap: (w: string) => void;
  onStartCloze?: () => void;
  onStartCards: () => void;
}) {
  const parts = useMemo(() => parsePassage(PASSAGE.en), []);
  const plain = PASSAGE.en.replace(/\{\{|\}\}/g, "");

  return (
    <>
      <Head title="语篇通读" onBack={onExit} onSpeak={() => speak(plain, 1)} />
      <div className="min-h-0 flex-1 overflow-y-auto px-[26px] pb-4 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <div className="mt-[10px] flex items-baseline gap-3">
          <h1 className="text-[26px] font-extrabold text-[#f5f5f7]">{PASSAGE.title}</h1>
          <span className="rounded-[5px] bg-[#29292e] px-[8px] py-[3px] text-[12px] text-[#a8a8ae]">{PASSAGE.tag}</span>
        </div>

        <p className="mt-[20px] text-[18px] leading-[1.85] text-[#d5d5da]">
          {parts.map((p, i) =>
            p.type === "word" ? (
              <span
                key={i}
                onClick={() => onWordTap(p.word)}
                className="mx-[2px] cursor-pointer pb-[3px] font-bold text-[#f0a824] underline decoration-dashed decoration-[#f0a824]/50 decoration-[1.5px] underline-offset-[6px] active:opacity-70"
              >
                {p.word}
              </span>
            ) : (
              <ClickableText key={i} text={p.text} onWord={onWordTap} className="inline" />
            )
          )}
        </p>

        <p className="mt-[22px] border-t border-white/[0.07] pt-[18px] text-[15px] leading-[1.9] text-[#8c8c92]">
          {PASSAGE.cn}
        </p>
        <p className="mt-[16px] text-center text-[12.5px] text-[#5a5a60]">点按任意单词可查看释义</p>
      </div>
      <footer className={`grid flex-none ${onStartCloze ? "grid-cols-2" : "grid-cols-1"} pb-[30px] pt-[10px]`}>
        {onStartCloze && <DashBtn label="语篇填空" color="bg-[#e3a83c]" onClick={onStartCloze} />}
        <DashBtn label="进入单词背诵" color="bg-[#2ec4a5]" onClick={onStartCards} />
      </footer>
    </>
  );
}

/* ================= 语篇填空 ================= */
export function PassageCloze({
  onBack,
  onStartCards,
}: {
  onBack: () => void;
  onStartCards: () => void;
}) {
  const parts = useMemo(() => parsePassage(PASSAGE.en), []);
  const targets = useMemo(() => parts.filter((p): p is { type: "word"; word: string } => p.type === "word").map((p) => p.word), [parts]);
  const bank = useMemo(() => shuffle(targets, 42), [targets]);

  const [filled, setFilled] = useState<(string | null)[]>(() => targets.map(() => null));
  const [errorChip, setErrorChip] = useState<string | null>(null);
  const [wrongs, setWrongs] = useState(0);

  const nextBlank = filled.findIndex((f) => f === null);
  const done = nextBlank === -1;
  const usedWords = new Set(filled.filter(Boolean) as string[]);

  const tapChip = (w: string) => {
    if (done || usedWords.has(w)) return;
    if (targets[nextBlank] === w) {
      setFilled((f) => {
        const n = [...f];
        n[nextBlank] = w;
        return n;
      });
      speak(w);
    } else {
      setErrorChip(w);
      setWrongs((x) => x + 1);
      setTimeout(() => setErrorChip(null), 550);
    }
  };

  let blankIdx = -1;

  return (
    <>
      <Head title="语篇填空" onBack={onBack} />
      <div className="min-h-0 flex-1 overflow-y-auto px-[26px] pb-4 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        <div className="mt-[10px] flex items-baseline justify-between">
          <h1 className="text-[26px] font-extrabold text-[#f5f5f7]">{PASSAGE.title}</h1>
          <span className="text-[13px] tabular-nums text-[#8c8c92]">
            {filled.filter(Boolean).length}/{targets.length}
          </span>
        </div>

        <p className="mt-[20px] text-[18px] leading-[2.05] text-[#d5d5da]">
          {parts.map((p, i) => {
            if (p.type === "text") return <span key={i}>{p.text}</span>;
            blankIdx += 1;
            const bi = blankIdx;
            const val = filled[bi];
            const isActive = bi === nextBlank;
            return (
              <span
                key={i}
                className={`mx-[3px] inline-block min-w-[92px] border-b-2 pb-[1px] text-center font-bold transition-colors ${
                  val
                    ? "border-[#2ec4a5]/60 text-[#2ec4a5]"
                    : isActive
                    ? "border-[#e3a83c] text-transparent"
                    : "border-[#4a4a4f] text-transparent"
                }`}
              >
                {val ?? "____"}
              </span>
            );
          })}
        </p>

        {done ? (
          <div className="mt-[26px] rounded-[14px] bg-[#1d4239]/60 px-[18px] py-[14px]">
            <p className="text-[15px] font-semibold text-[#3fe0b4]">✓ 全部填对！</p>
            <p className="mt-[4px] text-[13px] text-[#8fccc4]">出错 {wrongs} 次 · 建议现在进入单词背诵巩固</p>
          </div>
        ) : (
          <p className="mt-[20px] text-center text-[12.5px] text-[#5a5a60]">按顺序为琥珀色空格选择正确的单词</p>
        )}

        {/* 词库 chips */}
        <div className="mt-[18px] flex flex-wrap justify-center gap-[10px] pb-2">
          {bank.map((w) => {
            const used = usedWords.has(w);
            const isErr = errorChip === w;
            return (
              <button
                key={w}
                onClick={() => tapChip(w)}
                disabled={used}
                className={`rounded-[12px] px-[16px] py-[9px] text-[16px] font-semibold transition-all ${
                  used
                    ? "bg-[#1c1c20] text-[#4a4a4f]"
                    : isErr
                    ? "animate-pulse bg-[#4a1a24] text-[#ff8a8a]"
                    : "bg-[#26262b] text-[#ececef] active:scale-95 active:bg-[#33333a]"
                }`}
              >
                {w}
              </button>
            );
          })}
        </div>
      </div>
      <footer className="grid flex-none grid-cols-2 pb-[30px] pt-[10px]">
        <DashBtn label="返回语篇" color="bg-[#5a5a60]" onClick={onBack} dim />
        {done ? (
          <DashBtn label="进入单词背诵" color="bg-[#2ec4a5]" onClick={onStartCards} />
        ) : (
          <DashBtn label="跳过填空" color="bg-[#e3a83c]" onClick={onStartCards} />
        )}
      </footer>
    </>
  );
}
