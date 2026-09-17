import { useState } from "react";
import { X } from "lucide-react";
import type { TaskStyle } from "../api/backend";

const TODO_PRESETS: { label: string; style: TaskStyle }[] = [
  { label: "青绿", style: { gradient: "linear-gradient(135deg, #0c7a72 0%, #1596a0 60%, #2f7ba6 100%)" } },
  { label: "晚霞", style: { gradient: "linear-gradient(135deg, #f6b58c 0%, #e98a9a 100%)" } },
  { label: "深夜", style: { gradient: "linear-gradient(135deg, #1e2a4a 0%, #3a4d7a 100%)" } },
  { label: "云朵", style: { image: "https://images.pexels.com/photos/5312872/pexels-photo-5312872.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200", overlay: "bg-indigo-400/20" } },
  { label: "红叶", style: { image: "https://images.pexels.com/photos/35128280/pexels-photo-35128280.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200", position: "center 20%", overlay: "bg-slate-500/30" } },
  { label: "暮色", style: { image: "https://images.pexels.com/photos/9185457/pexels-photo-9185457.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200", overlay: "bg-blue-500/20" } },
];

const SET_PRESETS: { label: string; style: TaskStyle }[] = [
  { label: "粉", style: { color: "#f7a8bf" } },
  { label: "灰", style: { color: "#6f6f6f" } },
  { label: "藏蓝", style: { color: "#2c3352" } },
  { label: "青", style: { color: "#0e7d78" } },
  { label: "橙", style: { color: "#f0a06a" } },
  { label: "紫", style: { color: "#8b7bb8" } },
];

export default function TaskModal({
  mode,
  onClose,
  onSubmit,
}: {
  mode: "todo" | "set";
  onClose: () => void;
  onSubmit: (title: string, minutes: number, style: TaskStyle) => Promise<void>;
}) {
  const presets = mode === "todo" ? TODO_PRESETS : SET_PRESETS;
  const [title, setTitle] = useState("");
  const [minutes, setMinutes] = useState(30);
  const [preset, setPreset] = useState(0);
  const [saving, setSaving] = useState(false);

  const submit = async () => {
    if (!title.trim() || saving) return;
    setSaving(true);
    await onSubmit(title.trim(), minutes, presets[preset].style);
    setSaving(false);
  };

  return (
    <div className="absolute inset-0 z-40 flex items-end justify-center bg-black/40" onClick={onClose}>
      <div
        className="w-full rounded-t-2xl bg-white p-5 pb-6"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="mb-4 flex items-center justify-between">
          <h3 className="text-[16px] font-semibold text-neutral-800">
            {mode === "todo" ? "新建待办" : "新建待办集任务"}
          </h3>
          <button onClick={onClose} className="text-gray-400 active:text-gray-600">
            <X size={18} />
          </button>
        </div>

        <label className="mb-1 block text-[12px] text-gray-500">任务名称</label>
        <input
          autoFocus
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          placeholder="例如：背诵单词"
          className="mb-4 w-full rounded-lg border border-gray-200 px-3 py-2 text-[14px] outline-none focus:border-teal-500"
        />

        <label className="mb-1 block text-[12px] text-gray-500">
          专注时长：<span className="font-semibold text-teal-700">{minutes} 分钟</span>
        </label>
        <input
          type="range"
          min={5}
          max={180}
          step={5}
          value={minutes}
          onChange={(e) => setMinutes(Number(e.target.value))}
          className="mb-4 w-full accent-teal-600"
        />

        <label className="mb-2 block text-[12px] text-gray-500">卡片背景</label>
        <div className="mb-5 flex gap-2.5">
          {presets.map((p, i) => (
            <button
              key={p.label}
              onClick={() => setPreset(i)}
              className={`h-10 flex-1 rounded-lg bg-cover bg-center text-[10px] text-white [text-shadow:0_1px_3px_rgba(0,0,0,0.5)] ${
                preset === i ? "ring-2 ring-teal-600 ring-offset-2" : ""
              }`}
              style={{
                background: p.style.color ?? p.style.gradient,
                backgroundImage: p.style.image ? `url(${p.style.image})` : p.style.gradient,
                backgroundSize: "cover",
              }}
            >
              {p.label}
            </button>
          ))}
        </div>

        <button
          onClick={submit}
          disabled={!title.trim() || saving}
          className="w-full rounded-full bg-teal-700 py-2.5 text-[15px] font-medium text-white active:bg-teal-800 disabled:opacity-40"
        >
          {saving ? "保存中…" : "保存"}
        </button>
      </div>
    </div>
  );
}
