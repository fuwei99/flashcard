import StatusBar from "../components/StatusBar";
import { User, ChevronRight, Settings, BadgeCheck, CloudUpload, Palette, CircleHelp } from "lucide-react";

const items = [
  { icon: BadgeCheck, label: "我的成就" },
  { icon: CloudUpload, label: "数据备份" },
  { icon: Palette, label: "主题设置" },
  { icon: CircleHelp, label: "帮助与反馈" },
  { icon: Settings, label: "设置" },
];

export default function ProfileScreen() {
  return (
    <div className="flex h-full flex-col bg-[#f4f7f7]">
      <div style={{ background: "linear-gradient(180deg, #077a75 0%, #2ba49e 70%, #3cafa9 100%)" }}>
        <StatusBar time="1:34" battery={96} />
        <div className="px-4 pb-6 pt-2">
          <h1 className="text-[21px] font-semibold text-white">我的</h1>
          <div className="mt-4 flex items-center gap-3">
            <div className="flex h-12 w-12 items-center justify-center rounded-full bg-white/25">
              <User size={26} className="fill-white text-white" />
            </div>
            <div>
              <p className="text-[16px] font-medium text-white">学习打卡人</p>
              <p className="text-[11px] text-white/70">已坚持专注 337 天</p>
            </div>
          </div>
        </div>
      </div>
      <div className="flex-1 overflow-y-auto px-2.5 py-3">
        <div className="overflow-hidden rounded-xl bg-white shadow-sm">
          {items.map((it, i) => (
            <button
              key={it.label}
              className={`flex w-full items-center justify-between px-4 py-3 active:bg-gray-50 ${
                i > 0 ? "border-t border-gray-100" : ""
              }`}
            >
              <div className="flex items-center gap-2.5">
                <it.icon size={17} className="text-teal-700" strokeWidth={2} />
                <span className="text-[13px] text-neutral-800">{it.label}</span>
              </div>
              <ChevronRight size={15} className="text-gray-300" />
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
