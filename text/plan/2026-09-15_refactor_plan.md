# 2026-09-15 核心重构与 Bug 彻底整治计划

> **状态**：待执行（夜间审阅定稿，次日白天自由时段推进）  
> **涉及模块**：WebView 桥接与模板、存储层、会话状态机、干扰项算法

---

## 一、问题根因与技术定性

### 1. BUG-010 · 点击卡顿与幽灵穿透跳正面（神秘 Bug 破案）
- **用户体感**：在词义页点击「下一词」，屏幕毫无动静（卡住），再次点击，直接越过了新卡片的正面「忘记/模糊/记得」，瞬间跌进新卡片的词义解析。
- **技术根因**：
  1. **石器时代的全页重载**：每次切卡调用 `ctrl.loadHtmlString(html)`，WebView 必须销毁旧 DOM、重新解析完整 HTML、重新编译注入的 JS 与 CSS。在 Android 平台上耗时 150ms~400ms 不等。
  2. **切页期间无全局遮罩/防抖**：旧页面停在屏幕上，用户以为没点上产生「连击（Double Tap）」。
  3. **幽灵点击穿透（Ghost Click Passthrough）**：新页面在毫无防备的瞬间渲染完毕，此时正面底部的「记得」按钮刚好重叠在用户刚刚疯狂连击的屏幕区域。新页面的 `script.js` 刚绑定事件就立刻捕获到了这记延迟点击，直接触发 `toMeaning("good")`，正面直接被秒跳！
- **本质定性**：**非 SPA 架构在移动端 WebView 上的必然恶果。**

---

### 2. 存储选型辨析：「一张卡一个 JSON」vs SQLite
- **天赢设想**：既然单个大 JSON 有写崩风险，能不能「一张卡存一个 JSON 文件」？
- **现实死穴**：
  - **I/O 灾难与碎片化**：考研大纲 5500~6500 词。若存成 6000 个 JSON 文件，在移动端闪存文件系统上会产生海量 inode 和随机 I/O。
  - **排课遍历性能劣化**：每天打开 App 算「今天到期该复习谁」，必须对 6000 个小文件执行 `readdir` + `file.read` 反序列化。每次进 App 都要卡顿数秒，电量直接尿崩。
- **正解方案**：**单表 SQLite（`sqflite`）**。
  - 单行事务原子写入，永不损坏整库。
  - 在 `due` 字段建 B-Tree 索引，`SELECT * FROM card_states WHERE due <= ?` 查询耗时 < 5ms。

---

### 3. 会话状态机缺陷：重测连坐未毕业
- **现状**：`StudySession` 在重测轮中只有在整池所有卡片「全部 choice+cloze 双过」时，才执行 `pending.isEmpty -> graduated.add(...)`。
- **致命后果**：池内 5 张卡，4 张在第一轮就全对了，剩下 1 张死磕到第三轮。若中途强杀、电话切出被杀后台，那 4 张原本已掌握的卡**没有任何持久化记录**，用户白学。

---

### 4. 干扰项生成逻辑缺陷
- **现状**：虽然为选项加了词性标签，但抽取 3 个错误选项时未按目标词性过滤。若只有正确答案是动词，其他全是形容词，属于送分假题；且存在同义词撞车判定为错误的风险。

---

## 二、重构执行路线图

### 阶段一：WebView 升级为 SPA 架构（彻底根治卡顿与幽灵点击）
1. **单次载入模板骨架**：
   - 整个会话生命周期只调用一次 `loadHtmlString`。
   - 骨架加载完毕后，原生与 WebView 完全走 JS 桥通信。
2. **增量数据挂载接口**：
   - 在 WebView 内置 `window.Flashcard.mountCard(cardData)` 方法。
   - 原生只负责 `ctrl.runJavaScript('window.Flashcard.mountCard(${jsonEncode(data)})')`。
   - JS 侧使用 DOM 数据绑定快速替换文本与选项，零 DOM 销毁重绘，切卡响应时间压缩至 5ms 以内。
3. **物理防抖门锁（Debounce Lock）**：
   - JS 侧在切卡后的 250ms 内锁定一切点击事件，彻底阻断 Android 触摸事件队列的幽灵穿透。

---

### 阶段二：状态机重构（逐卡独立毕业与即时落盘）
1. **即时毕业机制**：
   - 在重测轮，任何卡片只要其通过集合包含了 `retestModes`（choice + cloze），**立即**移入 `graduated`，并抛出通知给原生层执行 `_write()` 立即落盘。
   - 绝不在整池完全清空前扣押已过关的卡片。
2. **逃生口设计**：
   - 重测连续错误达到阈值（如连续错 3 次），提供「标为生词并稍后复习」跳过按钮，避免将用户死锁在重测队列中。

---

### 阶段三：存储层换血（SQLite 替换 SharedPreferences）
1. **建立 SQLite 表结构**：
   ```sql
   CREATE TABLE card_states (
       card_id TEXT PRIMARY KEY,
       stability REAL,
       difficulty REAL,
       reps INTEGER,
       lapses INTEGER,
       due TEXT,
       last_review TEXT,
       state TEXT
   );
   CREATE INDEX idx_card_due ON card_states(due);
   CREATE TABLE card_kv (
       card_id TEXT,
       key TEXT,
       value TEXT,
       PRIMARY KEY (card_id, key)
   );
   ```
2. **数据无缝迁移**：
   - 首次启动检测 SharedPreferences 旧数据，若存在则一次性导入 SQLite 并归档清理。

---

### 阶段四：干扰项筛选算法收紧
1. **同词性严格抽样**：
   - 优先在同词库中筛选 `pos == cur.pos` 的非同义词。
   - 仅当同词性候选池不足 3 个时，才平滑降级到全池随机。

---

## 三、验证与测试用例

1. **幽灵连击测试**：在真机上极速快速连击词义页底部按钮，验证是否会出现正面被秒跳现象。
2. **崩溃落盘测试**：进入重测池，答对第一张后直接强杀进程，重新进入确认该卡是否已成功记录为已复习。
3. **性能基准测试**：6000 词库下的到期队列拉取耗时，目标控制在 10ms 以内。
