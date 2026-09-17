import { useEffect, useState } from "react";
import { lookupWord, type DictEntry } from "./dict";
import { speak } from "./tts";

/* ============================================================
   点词查词浮层：小卡（截图 1/2）+ 详细释义大卡（截图 3）
   卡片底色 #262c44（深藏蓝），词头橙色 #f0a824
   ============================================================ */

const Speaker = ({ cls = "" }: { cls?: string }) => (
  <svg viewBox="0 0 24 24" className={cls} fill="currentColor">
    <path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z" />
  </svg>
);

const StarIco = ({ cls = "", filled = false }: { cls?: string; filled?: boolean }) => (
  <svg viewBox="0 0 24 24" className={cls} fill={filled ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.9" strokeLinejoin="round">
    <path d="M12 3l2.7 5.6 6.1.8-4.5 4.2 1.1 6L12 16.7 6.6 19.6l1.1-6L3.2 9.4l6.1-.8L12 3z" />
  </svg>
);

/* ---------- 可点词文本 ---------- */
export function ClickableText({
  text,
  boldWord,
  selected,
  onWord,
  className = "",
}: {
  text: string;
  boldWord?: string;
  selected?: string | null;
  onWord: (w: string) => void;
  className?: string;
}) {
  const tokens = text.split(/([A-Za-z][A-Za-z'-]*)/g);
  return (
    <p className={className}>
      {tokens.map((tk, i) => {
        const isWord = /^[A-Za-z]/.test(tk);
        if (!isWord) return <span key={i}>{tk}</span>;
        const isBold = boldWord && tk.toLowerCase().startsWith(boldWord.toLowerCase());
        const isSel = selected && tk.toLowerCase() === selected.toLowerCase();
        return (
          <span
            key={i}
            onClick={(e) => {
              e.stopPropagation();
              onWord(tk);
            }}
            className={`cursor-pointer rounded-[4px] transition-colors ${
              isSel ? "bg-[#4a5578]/80 px-[2px] -mx-[2px]" : "active:bg-white/15"
            } ${isBold ? "font-bold text-white" : ""}`}
          >
            {tk}
          </span>
        );
      })}
    </p>
  );
}

/* ---------- 主浮层 ---------- */
export function DictLayer({
  word,
  onClose,
  isFav,
  onToggleFav,
}: {
  word: string;
  onClose: () => void;
  isFav: (w: string) => boolean;
  onToggleFav: (w: string) => void;
}) {
  const [entry, setEntry] = useState<DictEntry | null>(null);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState(false);
  const [tab, setTab] = useState("例句");

  useEffect(() => {
    let alive = true;
    setLoading(true);
    setEntry(null);
    setExpanded(false);
    setTab("例句");
    lookupWord(word).then((e) => {
      if (!alive) return;
      setEntry(e);
      setLoading(false);
      if (e) speak(e.word);
    });
    return () => {
      alive = false;
    };
  }, [word]);

  const headWord = entry?.word ?? word.toLowerCase();
  const fav = isFav(headWord);

  /* ============ 详细释义大卡（bottom sheet） ============ */
  if (expanded && entry) {
    const tabs = ["柯林斯", "例句", "派生", "词根", "近义", "真题", "笔记"];
    return (
      <div className="absolute inset-0 z-[70] flex flex-col justify-end bg-black/55" onClick={onClose}>
        <div
          className="flex h-[94%] flex-col rounded-t-[24px] bg-[#1e2338] px-[22px]"
          onClick={(e) => e.stopPropagation()}
        >
          {/* 拖拽条 */}
          <div className="flex flex-none justify-center pb-1 pt-[10px]">
            <span className="h-[4px] w-[44px] rounded-full bg-white/20" />
          </div>

          <div className="min-h-0 flex-1 overflow-y-auto pb-24 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
            {/* 词头 */}
            <div className="flex items-start justify-between pt-[10px]">
              <div className="flex items-baseline gap-3">
                <h2 className="text-[34px] font-extrabold leading-tight text-[#f0a824]">{headWord}</h2>
                {entry.level && (
                  <span className="rounded-[5px] bg-[#33395a] px-[8px] py-[3px] text-[12px] text-[#a9b0c8]">{entry.level}</span>
                )}
              </div>
              <button
                onClick={() => onToggleFav(headWord)}
                className={`mt-2 ${fav ? "text-[#f0a824]" : "text-[#a9b0c8]"} active:scale-90`}
              >
                <StarIco cls="h-[22px] w-[22px]" filled={fav} />
              </button>
            </div>

            {entry.phonetic && (
              <button onClick={() => speak(headWord)} className="mt-[10px] flex items-center gap-2 active:opacity-70">
                <span className="flex items-center gap-[6px] rounded-full bg-[#2c3350] px-[12px] py-[5px]">
                  <span className="text-[11px] text-[#a9b0c8]">美</span>
                  <Speaker cls="h-[11px] w-[11px] text-[#a9b0c8]" />
                </span>
                <span className="text-[15px] text-[#a9b0c8]">{entry.phonetic}</span>
              </button>
            )}

            {/* 词义 */}
            <div className="mt-[18px] space-y-[6px]">
              {entry.senses.map((s, i) => (
                <p key={i} className="text-[17px] leading-relaxed text-[#ececef]">
                  <span className="mr-2 text-[15px] text-[#a9b0c8]">{s.pos}</span>
                  <span className={i === 0 ? "font-bold" : ""}>{s.cn}</span>
                </p>
              ))}
            </div>

            {/* tab 行 */}
            <div className="mt-[22px] flex gap-[26px] border-b border-white/[0.08] pb-[10px] text-[16px]">
              {tabs.map((t) => (
                <button
                  key={t}
                  onClick={() => setTab(t)}
                  className={`relative pb-[2px] ${tab === t ? "font-semibold text-[#f0f0f2]" : "text-[#8a91a8]"}`}
                >
                  {t}
                  {tab === t && (
                    <span className="absolute -bottom-[11px] left-1/2 h-[3px] w-[20px] -translate-x-1/2 rounded-full bg-[#f0a824]" />
                  )}
                </button>
              ))}
            </div>

            {/* 词组搭配 */}
            {(entry.collocations ?? []).length > 0 && (
              <div className="mt-[18px] border-b border-white/[0.08] pb-[18px]">
                {entry.collocations!.map((c) => (
                  <div key={c.en} className="mb-[12px]">
                    <p className="text-[17px] text-[#ececef]">{c.en}</p>
                    <p className="mt-[2px] text-[15px] text-[#8a91a8]">{c.cn}</p>
                  </div>
                ))}
                <button className="text-[14px] font-medium text-[#f0a824] active:opacity-70">
                  学习所有考研真题词组 <span className="opacity-70">›</span>
                </button>
              </div>
            )}

            {/* 例句 */}
            <div className="mt-[20px] space-y-[24px]">
              {(entry.examples ?? []).length === 0 && (
                <p className="pt-6 text-center text-[14px] text-[#5a6178]">暂无例句</p>
              )}
              {(entry.examples ?? []).map((ex, i) => (
                <div key={i}>
                  <p className="text-[17px] leading-[1.6] text-[#ececef]">
                    {ex.en.split(new RegExp(`(${headWord}\\w*)`, "i")).map((seg, j) =>
                      seg.toLowerCase().startsWith(headWord.toLowerCase()) ? (
                        <b key={j} className="font-bold text-white">{seg}</b>
                      ) : (
                        <span key={j}>{seg}</span>
                      )
                    )}
                  </p>
                  {ex.cn && <p className="mt-[5px] text-[15px] leading-relaxed text-[#8a91a8]">{ex.cn}</p>}
                  <div className="mt-[8px] flex items-center justify-between">
                    <span className="text-[13px] text-[#5a6178]">{ex.src ? `来自 ${ex.src}` : ""}</span>
                    <button
                      onClick={() => speak(ex.en)}
                      className="flex h-[30px] w-[30px] items-center justify-center rounded-full bg-[#2c3350] text-[#a9b0c8] active:scale-90"
                    >
                      <Speaker cls="h-[14px] w-[14px]" />
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </div>

          {/* 关闭钮 */}
          <button
            onClick={onClose}
            className="absolute bottom-[26px] right-[22px] flex h-[54px] w-[54px] items-center justify-center rounded-full bg-[#2b3152]/95 text-[#ececef] shadow-lg active:scale-90"
          >
            <svg viewBox="0 0 24 24" className="h-[20px] w-[20px]" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>
      </div>
    );
  }

  /* ============ 查词小卡 ============ */
  return (
    <div className="absolute inset-0 z-[70]" onClick={onClose}>
      <div
        className="absolute left-[22px] right-[22px] top-[38%] rounded-[18px] bg-[#262c44] px-[22px] pb-[22px] pt-[20px] shadow-[0_18px_60px_rgba(0,0,0,0.55)]"
        onClick={(e) => e.stopPropagation()}
      >
        {loading ? (
          <div className="py-8 text-center">
            <p className="text-[15px] text-[#8a91a8]">查询中…</p>
          </div>
        ) : !entry ? (
          <div className="py-6 text-center">
            <p className="text-[20px] font-bold text-[#f0a824]">{word.toLowerCase()}</p>
            <p className="mt-3 text-[14px] text-[#8a91a8]">没有查到这个词 🤔</p>
          </div>
        ) : (
          <>
            <div className="flex items-start justify-between">
              <div className="flex items-baseline gap-[10px]">
                <h2 className="text-[30px] font-extrabold leading-tight text-[#f0a824]">{headWord}</h2>
                {entry.level && (
                  <span className="rounded-[5px] bg-[#33395a] px-[8px] py-[3px] text-[12px] text-[#a9b0c8]">{entry.level}</span>
                )}
              </div>
              <button
                onClick={() => onToggleFav(headWord)}
                className={`mt-1 ${fav ? "text-[#f0a824]" : "text-[#a9b0c8]"} active:scale-90`}
              >
                <StarIco cls="h-[22px] w-[22px]" filled={fav} />
              </button>
            </div>

            {entry.phonetic && (
              <button onClick={() => speak(headWord)} className="mt-[10px] flex items-center gap-2 active:opacity-70">
                <span className="flex items-center gap-[6px] rounded-full bg-[#2c3350] px-[12px] py-[5px]">
                  <span className="text-[11px] text-[#a9b0c8]">美</span>
                  <Speaker cls="h-[11px] w-[11px] text-[#a9b0c8]" />
                </span>
                <span className="text-[15px] text-[#a9b0c8]">{entry.phonetic}</span>
              </button>
            )}

            <div className="mt-[22px] space-y-[5px]">
              {entry.senses.slice(0, 2).map((s, i) => (
                <p key={i} className="text-[17px] leading-relaxed text-[#ececef]">
                  <span className="mr-2 text-[15px] text-[#a9b0c8]">{s.pos}</span>
                  <span className={i === 0 ? "font-bold" : ""}>{s.cn}</span>
                </p>
              ))}
            </div>

            <button
              onClick={() => setExpanded(true)}
              className="mt-[18px] text-[15px] text-[#a9b0c8] active:opacity-70"
            >
              查看详细释义 <span className="text-[#7a8098]">›</span>
            </button>
          </>
        )}
      </div>
    </div>
  );
}
