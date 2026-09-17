import { Lock, User } from "lucide-react";
import type { TabKey } from "../types";

function TodoIcon({ active }: { active: boolean }) {
  const c = active ? "bg-teal-700" : "bg-gray-400";
  return (
    <span className="flex h-5 w-6 flex-col items-center justify-center gap-[4px]">
      <span className={`h-[2.5px] w-5 rounded-full ${c}`} />
      <span className={`h-[2.5px] w-5 rounded-full ${c}`} />
    </span>
  );
}

function TodoSetIcon({ active }: { active: boolean }) {
  const c = active ? "bg-teal-700" : "bg-gray-400";
  return (
    <span className="flex h-5 w-6 flex-col items-end justify-center gap-[3px]">
      <span className={`h-[2.5px] w-5 rounded-full ${c}`} />
      <span className={`h-[2.5px] w-3.5 rounded-full ${c}`} />
      <span className={`h-[2.5px] w-4 rounded-full ${c}`} />
    </span>
  );
}

function PieIcon({ active }: { active: boolean }) {
  const c = active ? "text-teal-700" : "text-gray-400";
  return (
    <svg viewBox="0 0 24 24" className={`h-5 w-5 ${c}`} fill="currentColor">
      <path d="M11 3.05A9 9 0 1 0 20.95 13H11V3.05z" />
      <path d="M13 2.05V10h7.95A9.004 9.004 0 0 0 13 2.05z" opacity={active ? 1 : 0.85} transform="translate(1,-1)" />
    </svg>
  );
}

const tabs: { key: TabKey; label: string }[] = [
  { key: "todo", label: "待办" },
  { key: "todoset", label: "待办集" },
  { key: "lock", label: "锁机" },
  { key: "stats", label: "统计数据" },
  { key: "me", label: "我的" },
];

export default function BottomNav({
  active,
  onChange,
}: {
  active: TabKey;
  onChange: (t: TabKey) => void;
}) {
  return (
    <nav className="grid grid-cols-5 border-t border-gray-100 bg-white pb-2.5 pt-1.5">
      {tabs.map((t) => {
        const isActive = active === t.key;
        const textColor = isActive ? "text-teal-700" : "text-gray-400";
        return (
          <button
            key={t.key}
            onClick={() => onChange(t.key)}
            className="flex flex-col items-center gap-0.5 outline-none active:opacity-60"
          >
            {t.key === "todo" && <TodoIcon active={isActive} />}
            {t.key === "todoset" && <TodoSetIcon active={isActive} />}
            {t.key === "lock" && <Lock size={19} className={`${textColor} py-px`} strokeWidth={2.4} />}
            {t.key === "stats" && <PieIcon active={isActive} />}
            {t.key === "me" && <User size={19} className={`${textColor} fill-current py-px`} strokeWidth={2.4} />}
            <span className={`text-[11px] ${textColor} ${isActive ? "font-medium" : ""}`}>{t.label}</span>
          </button>
        );
      })}
    </nav>
  );
}
