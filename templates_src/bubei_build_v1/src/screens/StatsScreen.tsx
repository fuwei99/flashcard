import { useEffect, useState } from "react";
import StatusBar from "../components/StatusBar";
import { Clock, MoreVertical, ChevronLeft, ChevronRight, Medal, CalendarArrowUp } from "lucide-react";
import { api, BASE_STATS, type FocusRecord } from "../api/backend";

const PIE = [
  { name: "数学1000题", time: "36小时51分", pct: 68.4, color: "#ef7d90" },
  { name: "数学学习", time: "13小时8分", pct: 24.4, color: "#8fccc4" },
  { name: "英语阅读练习-翻译-作文", time: "2小时0分", pct: 3.7, color: "#ddf1ec" },
  { name: "机械学习", time: "1小时30分", pct: 2.8, color: "#7fa4ab" },
  { name: "锁机", time: "25分钟", pct: 0.8, color: "#f6cf8d" },
];

function polar(cx: number, cy: number, r: number, deg: number) {
  const rad = ((deg - 90) * Math.PI) / 180;
  return [cx + r * Math.cos(rad), cy + r * Math.sin(rad)];
}

function slicePath(cx: number, cy: number, r: number, a0: number, a1: number) {
  const [x0, y0] = polar(cx, cy, r, a0);
  const [x1, y1] = polar(cx, cy, r, a1);
  const large = a1 - a0 > 180 ? 1 : 0;
  return `M ${cx} ${cy} L ${x0} ${y0} A ${r} ${r} 0 ${large} 1 ${x1} ${y1} Z`;
}

function PieChart() {
  let angle = 0;
  const slices = PIE.map((s) => {
    const a0 = angle;
    angle += (s.pct / 100) * 360;
    return { ...s, a0, a1: angle };
  });
  return (
    <div className="relative mx-auto w-[250px]">
      <div className="absolute left-[58px] top-0 text-[11px] text-neutral-600">1小时30分</div>
      <div className="absolute left-[8px] top-[16px] text-[11px] text-neutral-600">2小时0分</div>
      <div className="absolute left-[48px] top-[60px] w-[150px] truncate text-center text-[10px] text-neutral-500">
        英语阅读<span className="opacity-70">练习-翻</span>…&nbsp;机械学习
      </div>
      <div className="absolute left-0 top-[106px] text-[11px] text-neutral-600">13小时8分</div>
      <div className="absolute left-[38px] top-[128px] text-[11px] text-neutral-700">数学学习</div>
      <div className="absolute bottom-[52px] right-[40px] text-[11px] text-neutral-700">数学1000题</div>
      <div className="absolute bottom-[28px] right-0 text-[11px] text-neutral-600">36小时51分</div>
      <svg viewBox="0 0 250 266" className="block w-full">
        <g transform="translate(125,133)">
          {slices.map((s) => (
            <path key={s.name} d={slicePath(0, 0, 82, s.a0 - 105, s.a1 - 105)} fill={s.color} />
          ))}
        </g>
        <line x1={74} y1={23} x2={102} y2={48} stroke="#9aa" strokeWidth={1} />
        <line x1={55} y1={31} x2={88} y2={56} stroke="#9aa" strokeWidth={1} />
        <line x1={48} y1={117} x2={74} y2={123} stroke="#9aa" strokeWidth={1} />
        <line x1={184} y1={210} x2={205} y2={228} stroke="#9aa" strokeWidth={1} />
      </svg>
    </div>
  );
}

function Card({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <div className={`rounded-xl bg-white px-4 py-3 shadow-sm ${className}`}>{children}</div>;
}

function StatNumber({ big, unit, big2, unit2 }: { big: string; unit?: string; big2?: string; unit2?: string }) {
  return (
    <span className="text-teal-800">
      <span className="text-[30px] font-semibold leading-none">{big}</span>
      {unit && <span className="ml-0.5 text-[11px] font-medium">{unit}</span>}
      {big2 && <span className="ml-0.5 text-[30px] font-semibold leading-none">{big2}</span>}
      {unit2 && <span className="ml-0.5 text-[11px] font-medium">{unit2}</span>}
    </span>
  );
}

const TEAL = "#0e7d78";

function isToday(ts: number) {
  const d = new Date(ts);
  const n = new Date();
  return d.getFullYear() === n.getFullYear() && d.getMonth() === n.getMonth() && d.getDate() === n.getDate();
}

export default function StatsScreen() {
  const [records, setRecords] = useState<FocusRecord[]>([]);
  const [seg, setSeg] = useState(3);
  const [showRecords, setShowRecords] = useState(false);

  useEffect(() => {
    api.listRecords().then(setRecords);
  }, []);

  const todayRecs = records.filter((r) => isToday(r.endedAt));
  const todayMin = todayRecs.reduce((s, r) => s + r.minutes, 0);

  const totalCount = BASE_STATS.count + records.length;
  const totalMin = BASE_STATS.totalMinutes + records.reduce((s, r) => s + r.minutes, 0);
  const avgMin = Math.round(totalMin / BASE_STATS.days);

  return (
    <div
      className="flex h-full flex-col"
      style={{ background: "linear-gradient(180deg, #077a75 0%, #2ba49e 40%, #3cafa9 100%)" }}
    >
      <StatusBar time="1:32" battery={96} />
      <div className="flex items-center justify-between px-4 pb-3 pt-2">
        <h1 className="text-[21px] font-semibold text-white">统计数据</h1>
        <div className="flex items-center gap-4 text-white">
          <span className="flex h-5 items-end gap-[3px]">
            <span className="h-3 w-[3.5px] rounded-full bg-white" />
            <span className="h-[18px] w-[3.5px] rounded-full bg-white" />
            <span className="h-2.5 w-[3.5px] rounded-full bg-white" />
          </span>
          <Clock size={19} strokeWidth={2.2} />
          <Medal size={19} strokeWidth={2.2} />
          <MoreVertical size={18} strokeWidth={2.6} />
        </div>
      </div>

      <div className="flex-1 space-y-2.5 overflow-y-auto px-2.5 pb-3 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        {/* 累计专注 */}
        <Card>
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-1.5" style={{ color: TEAL }}>
              <span className="text-[14px] font-semibold">累计专注</span>
              <CalendarArrowUp size={16} strokeWidth={2.2} />
            </div>
            <svg viewBox="0 0 24 24" className="h-4.5 w-4.5" fill={TEAL}>
              <circle cx="6" cy="18" r="3" />
              <circle cx="12" cy="8" r="3" fill="none" stroke={TEAL} strokeWidth="2" />
              <circle cx="19" cy="13" r="3" fill="none" stroke={TEAL} strokeWidth="2" />
            </svg>
          </div>
          <div className="mt-2 flex items-end justify-between">
            <div>
              <p className="mb-1.5 text-[11px] font-medium" style={{ color: TEAL }}>次数</p>
              <StatNumber big={String(totalCount)} />
            </div>
            <div className="text-center">
              <p className="mb-1.5 text-[11px] font-medium" style={{ color: TEAL }}>时长</p>
              <StatNumber big={String(Math.floor(totalMin / 60))} unit="小时" big2={String(totalMin % 60)} unit2="分钟" />
            </div>
            <div className="text-right">
              <p className="mb-1.5 text-[11px] font-medium" style={{ color: TEAL }}>日均时长</p>
              <StatNumber big={String(Math.floor(avgMin / 60))} unit="小时" big2={String(avgMin % 60)} unit2="分钟" />
            </div>
          </div>
        </Card>

        {/* 当日专注 */}
        <Card>
          <div className="flex items-center justify-between" style={{ color: TEAL }}>
            <span className="text-[14px] font-semibold">
              当日专注 <span className="ml-1 font-medium">{new Date().toISOString().slice(0, 10)}</span>
            </span>
            <span className="flex items-center gap-4">
              <ChevronLeft size={17} strokeWidth={2.6} />
              <ChevronRight size={17} strokeWidth={2.6} />
            </span>
          </div>
          <div className="mt-2 flex items-end justify-between">
            <div>
              <p className="mb-1.5 text-[11px] font-medium" style={{ color: TEAL }}>次数</p>
              <StatNumber big={String(todayRecs.length)} />
            </div>
            <div className="text-right">
              <p className="mb-1.5 text-[11px] font-medium" style={{ color: TEAL }}>时长</p>
              <StatNumber big={String(todayMin)} unit="分钟" />
            </div>
          </div>
        </Card>

        {/* 专注时长分布 */}
        <Card>
          <div className="flex items-center justify-between" style={{ color: TEAL }}>
            <span className="text-[13px] font-semibold">
              专注时长分布 <span className="ml-0.5 text-[11px] font-medium">2026-04-17 ~ 2026-09-18</span>
            </span>
            <span className="flex items-center gap-2">
              <span className="text-[11px] font-medium">分享</span>
              <ChevronLeft size={15} strokeWidth={2.6} />
              <ChevronRight size={15} strokeWidth={2.6} />
            </span>
          </div>

          <div className="mx-auto mt-3 flex w-[92%] overflow-hidden rounded-full border border-teal-200 text-[12px]">
            {["日", "周", "月", "自定义"].map((s, i) => (
              <button
                key={s}
                onClick={() => setSeg(i)}
                className={`flex-1 py-1 ${i < 3 ? "border-r border-teal-100" : ""} ${
                  seg === i ? "bg-teal-100/80 font-medium text-teal-800" : "text-teal-700"
                }`}
              >
                {s}
              </button>
            ))}
          </div>

          <div className="mt-3">
            <PieChart />
          </div>

          <p className="mt-1 text-center text-[12px] text-neutral-700">
            总计 53 小时 54 分钟 日均 21 分钟
          </p>

          <button
            onClick={() => setShowRecords((v) => !v)}
            className="mx-auto mt-3 block rounded-full bg-teal-50 px-8 py-1.5 text-[12px] font-medium active:bg-teal-100"
            style={{ color: TEAL }}
          >
            {showRecords ? "收起专注记录" : "查看专注记录"}
          </button>

          {showRecords && (
            <div className="mt-3 rounded-lg bg-gray-50 p-3">
              {records.length === 0 ? (
                <p className="text-center text-[11px] text-gray-400">还没有专注记录，去待办页开始一个任务吧</p>
              ) : (
                <ul className="space-y-1.5">
                  {[...records].reverse().slice(0, 8).map((r) => (
                    <li key={r.id} className="flex justify-between text-[11px] text-neutral-700">
                      <span>{r.title}</span>
                      <span className="text-gray-400">
                        {r.minutes} 分钟 · {new Date(r.endedAt).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}

          <div className="mt-4 grid grid-cols-2 gap-x-4 gap-y-2.5">
            {PIE.map((s) => (
              <div key={s.name} className="flex items-center justify-between gap-1.5">
                <div className="flex min-w-0 items-center gap-1.5">
                  <span className="h-2 w-2 shrink-0 rounded-full" style={{ background: s.color }} />
                  <div className="min-w-0">
                    <p className="truncate text-[11px] text-neutral-800">{s.name}</p>
                    <p className="text-[10px] text-neutral-500">{s.time}</p>
                  </div>
                </div>
                <span className="shrink-0 text-[11px] text-neutral-600">{s.pct}%</span>
              </div>
            ))}
          </div>
        </Card>

        {/* 本月专注时段分布 */}
        <Card className="pb-10">
          <div className="flex items-center justify-between" style={{ color: TEAL }}>
            <span className="text-[13px] font-semibold">
              本月专注时段分布 <span className="ml-0.5 font-medium">2026年09月</span>
            </span>
            <span className="flex items-center gap-4">
              <ChevronLeft size={16} strokeWidth={2.6} />
              <ChevronRight size={16} strokeWidth={2.6} />
            </span>
          </div>
        </Card>
      </div>
    </div>
  );
}
