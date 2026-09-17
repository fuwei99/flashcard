// 模拟后端：基于 localStorage 的异步 CRUD API
export interface TaskStyle {
  image?: string;
  gradient?: string;
  color?: string;
  overlay?: string;
  position?: string;
}

export interface Task {
  id: string;
  title: string;
  minutes: number;
  group: "todo" | "set";
  style: TaskStyle;
}

export interface FocusRecord {
  id: string;
  taskId: string;
  title: string;
  minutes: number;
  endedAt: number; // timestamp
}

const TASKS_KEY = "focus_app_tasks_v2";
const RECORDS_KEY = "focus_app_records_v2";

const delay = (ms = 180) => new Promise((r) => setTimeout(r, ms));
const uid = () => Math.random().toString(36).slice(2, 10);

const SEED_TASKS: Task[] = [
  {
    id: "t1", title: "背诵单词", minutes: 35, group: "todo",
    style: {
      image: "https://images.pexels.com/photos/35128280/pexels-photo-35128280.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200",
      position: "center 20%", overlay: "bg-slate-500/30",
    },
  },
  {
    id: "t2", title: "考研阅读两篇", minutes: 40, group: "todo",
    style: {
      image: "https://images.pexels.com/photos/28452283/pexels-photo-28452283.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200",
      overlay: "bg-slate-400/40",
    },
  },
  {
    id: "t3", title: "英语改错", minutes: 25, group: "todo",
    style: { image: "images/doodle-tea.png", position: "center 45%" },
  },
  {
    id: "t4", title: "机械听课", minutes: 120, group: "todo",
    style: {
      image: "https://images.pexels.com/photos/5312872/pexels-photo-5312872.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200",
      overlay: "bg-indigo-400/20",
    },
  },
  {
    id: "t5", title: "机械刷题", minutes: 180, group: "todo",
    style: {
      image: "https://images.pexels.com/photos/3721579/pexels-photo-3721579.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200",
      position: "center 60%",
    },
  },
  {
    id: "t6", title: "线性代数听课", minutes: 60, group: "todo",
    style: { gradient: "linear-gradient(135deg, #0c7a72 0%, #1596a0 60%, #2f7ba6 100%)" },
  },
  {
    id: "t7", title: "旋转体听课刷题", minutes: 60, group: "todo",
    style: {
      image: "https://images.pexels.com/photos/1603933/pexels-photo-1603933.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200",
      overlay: "bg-slate-900/30",
    },
  },
  {
    id: "t8", title: "政治听课", minutes: 60, group: "todo",
    style: {
      image: "https://images.pexels.com/photos/9185457/pexels-photo-9185457.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200",
      overlay: "bg-blue-500/20",
    },
  },
  {
    id: "t9", title: "设计毕业设计报告", minutes: 35, group: "todo",
    style: {
      image: "https://images.pexels.com/photos/36023403/pexels-photo-36023403.jpeg?auto=compress&cs=tinysrgb&fit=crop&h=627&w=1200",
      overlay: "bg-rose-300/20",
    },
  },
  { id: "s1", title: "凸轮机构", minutes: 120, group: "set", style: { color: "#f7a8bf" } },
  { id: "s2", title: "数学试卷", minutes: 25, group: "set", style: { color: "#6f6f6f" } },
  { id: "s3", title: "清理房间", minutes: 35, group: "set", style: { color: "#2c3352" } },
];

function load<T>(key: string, seed: T): T {
  try {
    const raw = localStorage.getItem(key);
    if (raw) return JSON.parse(raw) as T;
  } catch { /* ignore */ }
  localStorage.setItem(key, JSON.stringify(seed));
  return seed;
}

function save(key: string, val: unknown) {
  localStorage.setItem(key, JSON.stringify(val));
}

export const api = {
  async listTasks(group: "todo" | "set"): Promise<Task[]> {
    await delay();
    return load<Task[]>(TASKS_KEY, SEED_TASKS).filter((t) => t.group === group);
  },

  async createTask(input: Omit<Task, "id">): Promise<Task> {
    await delay();
    const tasks = load<Task[]>(TASKS_KEY, SEED_TASKS);
    const task: Task = { ...input, id: uid() };
    tasks.push(task);
    save(TASKS_KEY, tasks);
    return task;
  },

  async deleteTask(id: string): Promise<void> {
    await delay();
    const tasks = load<Task[]>(TASKS_KEY, SEED_TASKS).filter((t) => t.id !== id);
    save(TASKS_KEY, tasks);
  },

  async listRecords(): Promise<FocusRecord[]> {
    await delay();
    return load<FocusRecord[]>(RECORDS_KEY, []);
  },

  async createRecord(input: Omit<FocusRecord, "id">): Promise<FocusRecord> {
    await delay(100);
    const records = load<FocusRecord[]>(RECORDS_KEY, []);
    const rec: FocusRecord = { ...input, id: uid() };
    records.push(rec);
    save(RECORDS_KEY, records);
    return rec;
  },
};

// 历史基础数据（与截图一致的底数）
export const BASE_STATS = {
  count: 337,
  totalMinutes: 342 * 60 + 11,
  days: 69,
};
