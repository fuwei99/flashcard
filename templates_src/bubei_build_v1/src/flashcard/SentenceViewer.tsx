import { useEffect, useRef, useState } from "react";
import type { WordCard } from "./data";
import { speak } from "./tts";

/* ============================================================
   例句轮播卡（NPR 听力风格）
   布局：header(flex-none) + 例句区(flex-1) + 释义面板(固定 212px)
   ============================================================ */

const StarIco = ({ cls = "", filled = false }: { cls?: string; filled?: boolean }) => (
  <svg viewBox="0 0 24 24" className={cls} fill={filled ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.9" strokeLinejoin="round">
    <path d="M12 3l2.7 5.6 6.1.8-4.5 4.2 1.1 6L12 16.7 6.6 19.6l1.1-6L3.2 9.4l6.1-.8L12 3z" />
  </svg>
);

function orangeWord(text: string, word: string) {
  return text.split(new RegExp(`(${word}\\w*)`, "i")).map((seg, i) =>
    seg.toLowerCase().startsWith(word.toLowerCase()) ? (
      <b key={i} className="font-bold text-[#f0a824]">{seg}</b>
    ) : (
      <span key={i}>{seg}</span>
    )
  );
}

export default function SentenceViewer({
  word,
  startMeaning = 0,
  onClose,
  onNextWord,
}: {
  word: WordCard;
  startMeaning?: number;
  onClose: () => void;
  onNextWord?: () => void;
}) {
  const details = word.meaningDetails ?? [];
  const [mIdx, setMIdx] = useState(Math.min(startMeaning, Math.max(0, details.length - 1)));
  const [exIdx, setExIdx] = useState(0);
  const [revealed, setRevealed] = useState(false);
  const [starred, setStarred] = useState<Set<string>>(new Set());
  const [drag, setDrag] = useState(0);
  const startX = useRef<number | null>(null);

  const detail = details[mIdx];
  const examples = detail?.examples ?? [];
  const ex = examples[exIdx];

  useEffect(() => {
    if (ex) speak(ex.en);
  }, [mIdx, exIdx]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!detail || !ex) return null;

  const go = (dir: 1 | -1) => {
    setDrag(0);
    if (dir === 1) {
      if (exIdx + 1 < examples.length) setExIdx(exIdx + 1);
      else if (mIdx + 1 < details.length) {
        setMIdx(mIdx + 1);
        setExIdx(0);
        setRevealed(false);
      }
    } else {
      if (exIdx > 0) setExIdx(exIdx - 1);
      else if (mIdx > 0) {
        const pm = mIdx - 1;
        setMIdx(pm);
        setExIdx(details[pm].examples.length - 1);
        setRevealed(false);
      }
    }
  };

  const onDown = (x: number) => (startX.current = x);
  const onMove = (x: number) => {
    if (startX.current !== null) setDrag(Math.max(-80, Math.min(80, x - startX.current)));
  };
  const onUp = (x: number) => {
    if (startX.current === null) return;
    const dx = x - startX.current;
    startX.current = null;
    if (dx < -50) go(1);
    else if (dx > 50) go(-1);
    else setDrag(0);
  };

  const exKey = `${mIdx}-${exIdx}`;
  const isStar = starred.has(exKey);
  const pos = word.senses.find((s) => s.cn.includes(detail.meaning))?.pos ?? "";

  return (
    <div
      className="absolute inset-0 z-[60] flex flex-col"
      style={{ background: "linear-gradient(168deg, #121214 0%, #131216 55%, #1a1522 100%)" }}
    >
      {/* 例句大卡 */}
      <div
        className="mx-4 mt-[40px] flex min-h-0 flex-1 select-none flex-col overflow-hidden rounded-[20px] bg-[#1d2337] shadow-[0_18px_60px_rgba(0,0,0,0.5)] transition-transform duration-150"
        style={{ transform: `translateX(${drag}px)` }}
        onTouchStart={(e) => onDown(e.touches[0].clientX)}
        onTouchMove={(e) => onMove(e.touches[0].clientX)}
        onTouchEnd={(e) => onUp(e.changedTouches[0].clientX)}
        onMouseDown={(e) => onDown(e.clientX)}
        onMouseMove={(e) => startX.current !== null && onMove(e.clientX)}
        onMouseUp={(e) => onUp(e.clientX)}
        onMouseLeave={(e) => startX.current !== null && onUp(e.clientX)}
      >
        {/* 头部 */}
        <div className="flex flex-none items-center justify-between px-[20px] pt-[16px]">
          <span className="text-[15px] text-[#a9b0c8]">{ex.src}</span>
          <span className="flex flex-col gap-[4px]">
            <i className="h-[2.5px] w-[18px] rounded-full bg-[#a9b0c8]" />
            <i className="h-[2.5px] w-[18px] rounded-full bg-[#a9b0c8]" />
          </span>
        </div>

        {/* 例句区（弹性，撑满剩余空间） */}
        <div
          className="flex min-h-[150px] flex-1 cursor-pointer flex-col justify-end px-[20px] pb-[12px]"
          onClick={() => speak(ex.en)}
        >
          <p className="text-[20px] font-bold leading-[1.5] text-[#f0f0f2]">
            {orangeWord(ex.en, word.word)}
          </p>
          <p className="mt-[8px] text-[15px] leading-relaxed text-[#8a91a8]">{ex.cn}</p>

          <div className="mt-[16px] flex items-center">
            <button
              onClick={(e) => {
                e.stopPropagation();
                setStarred((s) => {
                  const n = new Set(s);
                  if (n.has(exKey)) n.delete(exKey);
                  else n.add(exKey);
                  return n;
                });
              }}
              className={`${isStar ? "text-[#f0a824]" : "text-[#8a91a8]"} active:scale-90`}
            >
              <StarIco cls="h-[20px] w-[20px]" filled={isStar} />
            </button>
            <span className="flex flex-1 justify-center gap-[8px]">
              {examples.map((_, i) => (
                <i key={i} className={`h-[6px] w-[6px] rounded-full ${i === exIdx ? "bg-[#c9cfdf]" : "bg-[#454e6b]"}`} />
              ))}
            </span>
            <span className="w-[20px]" />
          </div>
        </div>

        {/* 释义面板：固定高度，内部可滚动 */}
        <div className="relative h-[212px] flex-none border-t border-white/[0.05] bg-[#232a48]">
          <div
            className={`h-full overflow-y-auto px-[20px] pb-[40px] pt-[18px] [scrollbar-width:none] [&::-webkit-scrollbar]:hidden ${
              revealed ? "" : "pointer-events-none select-none blur-[10px] opacity-50"
            }`}
          >
            <p className="text-[17px] leading-[1.6] text-[#ececef]">
              <b className="mr-2 font-bold">{pos}</b>
              {detail.enDef ?? detail.meaning}
            </p>
            {detail.pattern && (
              <span className="mt-[14px] inline-block rounded-[10px] border border-[#4a5578] px-[13px] py-[7px] text-[15px] font-semibold text-[#c9cfdf]">
                {detail.pattern}
              </span>
            )}
          </div>

          {!revealed && (
            <button
              onClick={() => setRevealed(true)}
              className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 whitespace-nowrap px-[18px] py-[10px] text-[16px] text-[#c9cfdf] active:opacity-70"
            >
              <span className="absolute left-0 top-0 h-[11px] w-[11px] border-l-2 border-t-2 border-[#8a91a8]" />
              <span className="absolute right-0 top-0 h-[11px] w-[11px] border-r-2 border-t-2 border-[#8a91a8]" />
              <span className="absolute bottom-0 left-0 h-[11px] w-[11px] border-b-2 border-l-2 border-[#8a91a8]" />
              <span className="absolute bottom-0 right-0 h-[11px] w-[11px] border-b-2 border-r-2 border-[#8a91a8]" />
              查看双语释义
            </button>
          )}

          <span className="absolute bottom-[12px] right-[18px] text-[14px] tabular-nums text-[#8a91a8]">
            {exIdx + 1}/{examples.length}
          </span>
        </div>
      </div>

      {/* 考义胶囊 + 词义圆点 */}
      <div className="flex flex-none items-center justify-center gap-[10px] pt-[12px]">
        <span className="rounded-full bg-[#e3a83c] px-[11px] py-[3px] text-[12px] font-semibold text-[#241a05]">考义</span>
        {details.map((_, i) => (
          <button
            key={i}
            onClick={() => {
              setMIdx(i);
              setExIdx(0);
              setRevealed(false);
            }}
            className={`h-[8px] w-[8px] rounded-full ${i === mIdx ? "bg-[#e3a83c]" : "bg-[#5a5a60]"}`}
          />
        ))}
      </div>

      {/* 底部操作 */}
      <footer className="grid flex-none grid-cols-2 pb-[26px] pt-[16px]">
        <button
          onClick={() => {
            onClose();
            onNextWord?.();
          }}
          className="flex flex-col items-center gap-[9px] active:opacity-60"
        >
          <span className="text-[18px] font-semibold text-[#ececef]">下一词</span>
          <span className="h-[4px] w-[22px] rounded-full bg-[#2ec4a5]" />
        </button>
        <button onClick={onClose} className="flex flex-col items-center gap-[9px] active:opacity-60">
          <span className="text-[18px] font-semibold text-[#ececef]">收起卡片</span>
          <span className="h-[4px] w-[22px] rounded-full bg-[#e3a83c]" />
        </button>
      </footer>
    </div>
  );
}
