import { Bluetooth, Link2, Moon, BellOff, Zap } from "lucide-react";

export default function StatusBar({
  time,
  battery,
  light = true,
}: {
  time: string;
  battery: number;
  light?: boolean;
}) {
  const color = light ? "text-white" : "text-neutral-800";
  const border = light ? "border-white" : "border-neutral-700";
  return (
    <div className={`flex items-center justify-between px-4 pt-1.5 pb-0.5 ${color}`}>
      <div className="flex items-center gap-1.5">
        <span className="text-[13px] font-semibold tracking-wide">{time}</span>
        <span className="inline-flex h-[11px] w-[9px] items-center justify-center rounded-[2px] bg-emerald-400 text-[6px] font-bold text-white">
          1
        </span>
        <span className="text-[10px] tracking-widest">•••</span>
      </div>
      <div className="flex items-center gap-1">
        <Bluetooth size={10} strokeWidth={2.4} />
        <Link2 size={11} strokeWidth={2.4} />
        <Moon size={10} strokeWidth={2.4} />
        <BellOff size={10} strokeWidth={2.4} />
        {[0, 1].map((i) => (
          <span key={i} className="flex items-end gap-[1px]">
            <span className="mr-[1px] text-[6px] font-bold leading-none">5G</span>
            <span className={`h-[3px] w-[1.5px] rounded-sm ${light ? "bg-white/80" : "bg-neutral-500"}`} />
            <span className={`h-[4.5px] w-[1.5px] rounded-sm ${light ? "bg-white/80" : "bg-neutral-500"}`} />
            <span className={`h-[6px] w-[1.5px] rounded-sm ${light ? "bg-white" : "bg-neutral-800"}`} />
            <span className={`h-[7.5px] w-[1.5px] rounded-sm ${light ? "bg-white" : "bg-neutral-800"}`} />
          </span>
        ))}
        <span className={`relative ml-0.5 flex h-[10px] w-[20px] items-center justify-center rounded-[3px] border ${border}`}>
          <span
            className="absolute left-[1px] top-[1px] bottom-[1px] rounded-[2px] bg-emerald-400"
            style={{ width: `${Math.min(battery, 100) * 0.17}px` }}
          />
          <span className={`relative z-10 text-[6.5px] font-bold ${light ? "text-white" : "text-neutral-800"}`}>{battery}</span>
          <span className={`absolute -right-[2.5px] h-[4px] w-[1.5px] rounded-r ${light ? "bg-white" : "bg-neutral-700"}`} />
        </span>
        <Zap size={9} strokeWidth={2.6} className="fill-current" />
      </div>
    </div>
  );
}
