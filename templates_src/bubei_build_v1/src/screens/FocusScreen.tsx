import { useEffect, useRef, useState } from "react";
import StatusBar from "../components/StatusBar";
import { Pause, Play } from "lucide-react";
import type { Task } from "../api/backend";
import { api } from "../api/backend";

function fmt(sec: number) {
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

export default function FocusScreen({
  task,
  onExit,
}: {
  task: Task;
  onExit: (finished: boolean) => void;
}) {
  const total = task.minutes * 60;
  const [left, setLeft] = useState(total);
  const [paused, setPaused] = useState(false);
  const leftRef = useRef(total);
  leftRef.current = left;

  useEffect(() => {
    if (paused) return;
    const id = setInterval(() => {
      setLeft((v) => (v > 0 ? v - 1 : 0));
    }, 1000);
    return () => clearInterval(id);
  }, [paused]);

  const elapsedMin = Math.max(1, Math.round((total - leftRef.current) / 60));
  const done = left === 0;

  const finish = async (record: boolean) => {
    if (record) {
      await api.createRecord({
        taskId: task.id,
        title: task.title,
        minutes: done ? task.minutes : elapsedMin,
        endedAt: Date.now(),
      });
    }
    onExit(record);
  };

  const progress = 1 - left / total;
  const R = 108;
  const C = 2 * Math.PI * R;

  return (
    <div
      className="flex h-full flex-col"
      style={{ background: "linear-gradient(180deg, #06615d 0%, #0e7d78 50%, #17948e 100%)" }}
    >
      <StatusBar time="1:28" battery={94} />
      <div className="flex flex-1 flex-col items-center justify-center px-8 pb-16">
        <p className="mb-1 text-[13px] tracking-widest text-white/60">正在专注</p>
        <h2 className="mb-8 text-[22px] font-semibold text-white">{task.title}</h2>

        <div className="relative mb-10 flex h-64 w-64 items-center justify-center">
          <svg viewBox="0 0 240 240" className="absolute inset-0 h-full w-full -rotate-90">
            <circle cx="120" cy="120" r={R} fill="none" stroke="rgba(255,255,255,0.15)" strokeWidth="8" />
            <circle
              cx="120" cy="120" r={R} fill="none" stroke="#fff" strokeWidth="8" strokeLinecap="round"
              strokeDasharray={C}
              strokeDashoffset={C * (1 - progress)}
              style={{ transition: "stroke-dashoffset 1s linear" }}
            />
          </svg>
          <div className="text-center">
            <p className="font-mono text-[52px] font-light tabular-nums text-white">{fmt(left)}</p>
            <p className="text-[12px] text-white/60">共 {task.minutes} 分钟</p>
          </div>
        </div>

        {done ? (
          <>
            <p className="mb-5 text-[16px] text-white">🎉 专注完成！</p>
            <button
              onClick={() => finish(true)}
              className="rounded-full bg-white px-14 py-2.5 text-[15px] font-semibold text-teal-700 active:opacity-80"
            >
              保存记录
            </button>
          </>
        ) : (
          <div className="flex items-center gap-8">
            <button
              onClick={() => finish(false)}
              className="rounded-full border border-white/50 px-7 py-2 text-[14px] text-white active:bg-white/10"
            >
              放弃
            </button>
            <button
              onClick={() => setPaused((p) => !p)}
              className="flex h-16 w-16 items-center justify-center rounded-full bg-white text-teal-700 shadow-lg active:opacity-80"
            >
              {paused ? <Play size={26} className="ml-1 fill-current" /> : <Pause size={26} className="fill-current" />}
            </button>
            <button
              onClick={() => finish(true)}
              className="rounded-full border border-white/50 px-7 py-2 text-[14px] text-white active:bg-white/10"
            >
              完成
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
