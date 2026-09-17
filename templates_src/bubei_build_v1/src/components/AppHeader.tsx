import { Clock, MoreVertical, Plus } from "lucide-react";

function ChartBarsIcon() {
  return (
    <span className="flex h-5 items-end justify-center gap-[3px]">
      <span className="h-3 w-[3.5px] rounded-full bg-white" />
      <span className="h-[18px] w-[3.5px] rounded-full bg-white" />
      <span className="h-2.5 w-[3.5px] rounded-full bg-white" />
    </span>
  );
}

export default function AppHeader({
  title,
  plusBadge = false,
  onAdd,
}: {
  title: string;
  plusBadge?: boolean;
  onAdd?: () => void;
}) {
  return (
    <div className="flex items-end justify-between px-4 pb-3 pt-2.5">
      <div>
        <h1 className="text-[21px] font-semibold text-white">{title}</h1>
        <button className="mt-1.5 rounded-full bg-black/20 px-3 py-1 text-[11px] text-white active:bg-black/30">
          点击开启学霸模式
        </button>
      </div>
      <div className="mb-1.5 flex items-center gap-4">
        <span className="text-center text-[10px] font-bold leading-tight tracking-[0.15em] text-white">
          必开
          <br />
          权限
        </span>
        <ChartBarsIcon />
        <Clock size={19} strokeWidth={2.2} className="text-white" />
        <button onClick={onAdd} className="relative active:opacity-60">
          <Plus size={23} strokeWidth={2.4} className="text-white" />
          {plusBadge && (
            <Plus size={11} strokeWidth={3} className="absolute -bottom-0.5 -right-1 text-white" />
          )}
        </button>
        <MoreVertical size={18} strokeWidth={2.6} className="text-white" />
      </div>
    </div>
  );
}
