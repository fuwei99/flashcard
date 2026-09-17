import { useState } from "react";
import StatusBar from "../components/StatusBar";
import { Lock, Unlock } from "lucide-react";

export default function LockScreen() {
  const [locked, setLocked] = useState(false);

  return (
    <div
      className="flex h-full flex-col"
      style={{ background: "linear-gradient(180deg, #077a75 0%, #2ba49e 40%, #3cafa9 100%)" }}
    >
      <StatusBar time="1:33" battery={96} />
      <div className="px-4 pb-3 pt-2">
        <h1 className="text-[21px] font-semibold text-white">锁机</h1>
      </div>
      <div className="flex flex-1 flex-col items-center justify-center gap-4 px-8 pb-20">
        <div
          className={`flex h-28 w-28 items-center justify-center rounded-full transition-colors ${
            locked ? "bg-white/30" : "bg-white/15"
          }`}
        >
          {locked ? (
            <Lock size={52} strokeWidth={1.6} className="text-white" />
          ) : (
            <Unlock size={52} strokeWidth={1.6} className="text-white" />
          )}
        </div>
        <p className="text-[16px] font-medium text-white">
          {locked ? "锁机中，保持专注…" : "开启锁机，专注当下"}
        </p>
        <p className="-mt-2 text-[11px] text-white/70">锁机期间将无法使用其他应用</p>
        <button
          onClick={() => setLocked((v) => !v)}
          className="mt-1 rounded-full bg-white px-10 py-2 text-[14px] font-semibold text-teal-700 shadow-lg active:opacity-80"
        >
          {locked ? "解除锁机" : "开始锁机"}
        </button>
      </div>
    </div>
  );
}
