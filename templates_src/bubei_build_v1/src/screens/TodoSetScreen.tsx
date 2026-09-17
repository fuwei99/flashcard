import { useEffect, useState } from "react";
import StatusBar from "../components/StatusBar";
import AppHeader from "../components/AppHeader";
import TaskModal from "../components/TaskModal";
import { ChevronDown, Settings, Plus, X } from "lucide-react";
import { api, type Task, type TaskStyle } from "../api/backend";

function SmallPieIcon() {
  return (
    <svg viewBox="0 0 24 24" className="h-5 w-5 text-gray-500" fill="none" stroke="currentColor" strokeWidth={2}>
      <path d="M11 4.06A8 8 0 1 0 19.94 13H11V4.06z" />
      <path d="M14 2.2V10h7.8A8.01 8.01 0 0 0 14 2.2z" fill="currentColor" stroke="none" />
    </svg>
  );
}

export default function TodoSetScreen({ onStartFocus }: { onStartFocus: (t: Task) => void }) {
  const [tasks, setTasks] = useState<Task[] | null>(null);
  const [showModal, setShowModal] = useState(false);
  const [collapsed, setCollapsed] = useState(false);
  const [editing, setEditing] = useState(false);

  const reload = () => api.listTasks("set").then(setTasks);
  useEffect(() => {
    reload();
  }, []);

  const handleAdd = async (title: string, minutes: number, style: TaskStyle) => {
    await api.createTask({ title, minutes, group: "set", style });
    await reload();
    setShowModal(false);
  };

  const handleDelete = async (id: string) => {
    setTasks((ts) => ts?.filter((t) => t.id !== id) ?? null);
    await api.deleteTask(id);
  };

  return (
    <div className="relative flex h-full flex-col bg-white">
      <div style={{ background: "linear-gradient(180deg, #077a75 0%, #2ba49e 70%, #3cafa9 100%)" }}>
        <StatusBar time="1:46" battery={100} />
        <AppHeader title="待办集" plusBadge onAdd={() => setShowModal(true)} />
      </div>

      {/* group header row */}
      <div className="relative flex items-center justify-between border-b border-gray-100 py-3.5 pl-5 pr-4">
        <span className="absolute bottom-0 left-0 top-0 w-[4px] bg-sky-500" />
        <span className="text-[17px] font-medium text-neutral-800">10.30任务</span>
        <div className="flex items-center gap-4 text-gray-500">
          <button onClick={() => setCollapsed((c) => !c)} className="active:opacity-60">
            <ChevronDown
              size={21}
              strokeWidth={2.4}
              className={`transition-transform ${collapsed ? "-rotate-90" : ""}`}
            />
          </button>
          <SmallPieIcon />
          <button onClick={() => setEditing((e) => !e)} className="active:opacity-60">
            <Settings
              size={19}
              strokeWidth={2.2}
              className={editing ? "fill-teal-600 text-teal-600" : "fill-gray-500 text-gray-500"}
            />
          </button>
          <button onClick={() => setShowModal(true)} className="active:opacity-60">
            <Plus size={22} strokeWidth={2.2} />
          </button>
        </div>
      </div>

      {/* solid color cards */}
      <div className="flex-1 space-y-2.5 overflow-y-auto bg-white px-2.5 py-2.5">
        {!collapsed &&
          (tasks === null ? (
            <p className="pt-8 text-center text-[13px] text-gray-400">加载中…</p>
          ) : tasks.length === 0 ? (
            <p className="pt-8 text-center text-[13px] text-gray-400">暂无任务，点 + 新建</p>
          ) : (
            tasks.map((t) => (
              <div
                key={t.id}
                className="relative rounded-lg px-4 py-2.5 shadow-sm"
                style={{ backgroundColor: t.style.color }}
              >
                <h2 className="text-[16px] font-medium text-white">{t.title}</h2>
                <p className="mt-2.5 text-[12px] text-white">{t.minutes} 分钟</p>
                <button
                  onClick={() => onStartFocus(t)}
                  className="absolute right-6 top-1/2 -translate-y-1/2 text-[17px] font-medium text-white active:scale-95"
                >
                  开始
                </button>
                <span className="absolute bottom-2 right-1 top-2 w-[3px] rounded bg-white/40" />
                {editing && (
                  <button
                    onClick={() => handleDelete(t.id)}
                    className="absolute right-1.5 top-1.5 flex h-5 w-5 items-center justify-center rounded-full bg-black/40 text-white active:bg-red-500"
                  >
                    <X size={12} strokeWidth={3} />
                  </button>
                )}
              </div>
            ))
          ))}
      </div>

      {showModal && (
        <TaskModal mode="set" onClose={() => setShowModal(false)} onSubmit={handleAdd} />
      )}
    </div>
  );
}
