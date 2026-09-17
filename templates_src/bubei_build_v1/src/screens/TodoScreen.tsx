import { useEffect, useState } from "react";
import StatusBar from "../components/StatusBar";
import AppHeader from "../components/AppHeader";
import TaskModal from "../components/TaskModal";
import { X } from "lucide-react";
import { api, type Task, type TaskStyle } from "../api/backend";

function TaskCard({
  task,
  editing,
  onStart,
  onDelete,
}: {
  task: Task;
  editing: boolean;
  onStart: () => void;
  onDelete: () => void;
}) {
  const s = task.style;
  return (
    <div
      className="relative h-[84px] shrink-0 overflow-hidden rounded-lg bg-cover shadow-md"
      style={{
        backgroundImage: s.image ? `url(${s.image})` : s.gradient,
        backgroundColor: s.color,
        backgroundPosition: s.position ?? "center",
        backgroundSize: s.gradient || s.color ? undefined : "cover",
      }}
    >
      {s.overlay && <div className={`absolute inset-0 ${s.overlay}`} />}
      <div className="relative flex h-full flex-col justify-between px-4 py-2.5">
        <h2 className="text-[17px] font-medium text-white [text-shadow:0_1px_5px_rgba(0,0,0,0.45)]">
          {task.title}
        </h2>
        <p className="text-[12px] text-white [text-shadow:0_1px_4px_rgba(0,0,0,0.45)]">
          {task.minutes} 分钟
        </p>
      </div>
      <button
        onClick={onStart}
        className="absolute right-6 top-1/2 -translate-y-1/2 text-[19px] font-medium text-white [text-shadow:0_1px_6px_rgba(0,0,0,0.5)] active:scale-95"
      >
        开始
      </button>
      {editing && (
        <button
          onClick={onDelete}
          className="absolute right-1.5 top-1.5 flex h-5 w-5 items-center justify-center rounded-full bg-black/40 text-white active:bg-red-500"
        >
          <X size={12} strokeWidth={3} />
        </button>
      )}
    </div>
  );
}

export default function TodoScreen({ onStartFocus }: { onStartFocus: (t: Task) => void }) {
  const [tasks, setTasks] = useState<Task[] | null>(null);
  const [showModal, setShowModal] = useState(false);
  const [editing, setEditing] = useState(false);

  const reload = () => api.listTasks("todo").then(setTasks);
  useEffect(() => {
    reload();
  }, []);

  const handleAdd = async (title: string, minutes: number, style: TaskStyle) => {
    await api.createTask({ title, minutes, group: "todo", style });
    await reload();
    setShowModal(false);
  };

  const handleDelete = async (id: string) => {
    setTasks((ts) => ts?.filter((t) => t.id !== id) ?? null);
    await api.deleteTask(id);
  };

  return (
    <div
      className="relative flex h-full flex-col"
      style={{ background: "linear-gradient(180deg, #077a75 0%, #2ba49e 30%, #3cafa9 100%)" }}
    >
      <StatusBar time="1:27" battery={94} />
      <AppHeader title="待办" onAdd={() => setShowModal(true)} />
      <div className="flex-1 space-y-2.5 overflow-y-auto px-2.5 pb-3 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden">
        {tasks === null ? (
          <p className="pt-10 text-center text-[13px] text-white/70">加载中…</p>
        ) : tasks.length === 0 ? (
          <p className="pt-10 text-center text-[13px] text-white/70">暂无待办，点右上角 + 新建</p>
        ) : (
          tasks.map((t) => (
            <TaskCard
              key={t.id}
              task={t}
              editing={editing}
              onStart={() => onStartFocus(t)}
              onDelete={() => handleDelete(t.id)}
            />
          ))
        )}
        {tasks && tasks.length > 0 && (
          <button
            onClick={() => setEditing((e) => !e)}
            className="mx-auto block rounded-full bg-black/15 px-4 py-1 text-[11px] text-white/80 active:bg-black/25"
          >
            {editing ? "完成管理" : "管理待办"}
          </button>
        )}
      </div>

      {showModal && (
        <TaskModal mode="todo" onClose={() => setShowModal(false)} onSubmit={handleAdd} />
      )}
    </div>
  );
}
