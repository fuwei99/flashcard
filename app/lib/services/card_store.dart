/// 卡牌状态存储：调度状态 + 卡牌私有 KV
/// ================================================================
/// 落盘位置（公共目录）：
///   <Documents>/Flashcard/progress.json        快照（全量）
///   <Documents>/Flashcard/progress.log.jsonl   追加日志（一行一次变更）
///
/// 为什么要拆成两个文件：
///   以前每答一张卡都要把整份状态 `json.encode` 再写盘 —— 1 万张卡时
///   每次滑动要重写 ~1MB，越背越卡。现在改成 **append-only**：
///   答一张卡 = 往 jsonl 追加一行，O(1)；启动时先读快照、再按顺序
///   叠加日志（后写覆盖先写）；日志行数超过阈值就 compact 回快照。
///
/// 追加日志的额外好处：崩了不丢（append 是原子的），而且 Agent 能直接
/// 读 jsonl 看到「最近改了什么」。
///
/// 公共目录不可用时退回 SharedPreferences（app 私有，Agent 读不到）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'data_dir.dart';
import 'scheduler.dart';

class CardStore {
  static const _snapFile = 'progress.json';
  static const _journalFile = 'progress.log.jsonl';
  static const _dueFile = 'due.jsonl';

  // 公共文件不可用时的兜底（老版本数据也在这）
  static const _kStates = 'fc_card_states_v1';
  static const _kKv = 'fc_card_kv_v1';

  final Map<String, CardState> _states = {};
  final Map<String, Map<String, dynamic>> _kv = {};
  SharedPreferences? _prefs;

  File? _snap;
  File? _journal;
  int _journalLines = 0;

  /// due 索引重建的节流计数：每 [_dueEvery] 次状态变更重建一次 due.jsonl。
  /// 索引是派生数据，滞后几行无妨 —— Agent 可叠加 progress.log.jsonl 补齐。
  int _sinceDue = 0;
  static const _dueEvery = 10;

  /// 是否落在公共文件上（Agent 可读）
  bool get fileBacked => DataDir.available;

  Future<void> init() async {
    await DataDir.root(); // 先解析公共目录
    _prefs = await SharedPreferences.getInstance();

    final root = DataDir.cachedRoot;
    if (root != null) {
      _snap = File('${root.path}/$_snapFile');
      _journal = File('${root.path}/$_journalFile');
    }

    var fromFile = false;

    // 1) 快照
    final doc = DataDir.readJsonSync(_snapFile);
    if (doc != null) {
      _applyDoc(doc);
      fromFile = true;
    }

    // 2) 叠加追加日志（后写覆盖先写）
    final j = _journal;
    if (j != null && j.existsSync()) {
      _replayJournal(j);
      fromFile = true;
    }

    if (fromFile) {
      // 这里**不**再 _flushPrefs()：公共文件才是主存，prefs 只是它不可用时的
      // 兜底备份。以前每次冷启动都把全部状态 encode 一遍写进 prefs，
      // 1 万张卡就是 1MB 级写入 —— 正是 append-only 优化想干掉的东西。
      // 备份的同步交给 compact（本身就会刷），启动时不再额外写。
      // 日志太长就压一次
      if (_journalLines > _compactThreshold) _compact();
      _writeDueIndex();
      return;
    }

    // 3) 都没有 → 退回 prefs（老版本数据），然后写成新格式
    _loadPrefs();
    _compact();
    _flushPrefs();
    _writeDueIndex();
  }

  /// 公共目录从「不可用」翻成「可用」后重新挂上文件（授权回调里调）。
  ///
  /// 首次安装时 init() 那次探测必然失败（还没权限），数据全在 prefs 里。
  /// 用户点了授权之后调用这里，把内存里的数据搬进公共文件，
  /// 之后 Agent / 文件管理器就都能读到了。已经挂在文件上的直接跳过。
  Future<void> rebind() async {
    if (_snap != null) return;
    await DataDir.root();
    final root = DataDir.cachedRoot;
    if (root == null) return;
    _snap = File('${root.path}/$_snapFile');
    _journal = File('${root.path}/$_journalFile');
    // 内存里的数据才是刚跑出来的权威值：写成快照 + 刷 prefs 兜底
    _compact();
  }

  // ---------- 读 / 写 ----------

  CardState stateOf(String cardId) => _states[cardId] ?? CardState();

  Map<String, dynamic> kvOf(String cardId) => _kv[cardId] ?? {};

  /// 落盘策略：公共文件可用时只 append 追加日志（O(1)），**不**再全量刷 prefs；
  /// 只有目录不可用（没文件兜底）时才回退到 prefs 全量写。
  /// 之前这里每答一张卡就 `_flushPrefs()` 把全部状态 encode 一遍，
  /// 直接把 append-only 的优化废掉，卡越多越卡 —— 是回归。
  void putKv(String cardId, String key, dynamic value) {
    final rec = _kv[cardId] ??= <String, dynamic>{};
    rec[key] = value;
    _append(cardId, kv: rec);
    if (_journal == null) _flushPrefs();
  }

  void putState(String cardId, CardState st) {
    _states[cardId] = st;
    _append(cardId, st: st);
    if (_journal == null) _flushPrefs();
  }

  /// 复习提交：跑完 FSRS 后落盘，同时把「输入侧」也写进日志 ——
  /// 评分、复习前状态、间隔、当时可提取概率 R。
  /// 只写结果状态（putState）的日志做不了 FSRS 参数拟合；补齐后
  /// progress.log.jsonl 就是一条可用的 revlog（老行无 rev 字段，回放时忽略）。
  void putReview(String cardId, CardState prev, CardState next, Rating rating) {
    _states[cardId] = next;
    final now = DateTime.now();
    final last = prev.lastReview;
    final elapsed = last == null
        ? 0
        : DateTime(now.year, now.month, now.day)
            .difference(DateTime(last.year, last.month, last.day))
            .inDays;
    final recall = prev.stability > 0
        ? forgettingCurve(elapsed.toDouble(), prev.stability)
        : 0.0;
    _append(cardId, st: next, rev: {
      'rating': rating.key,
      'at': now.toIso8601String(),
      'elapsed_days': elapsed,
      'prev_state': prev.state,
      'prev_stability': prev.stability,
      'prev_difficulty': prev.difficulty,
      'retrievability': double.parse(recall.toStringAsFixed(4)),
    });
    if (_journal == null) _flushPrefs();
  }

  /// 到期 / 新卡 的复习队列
  List<String> dueQueue(List<String> allIds) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = <String>[];
    final fresh = <String>[];
    for (final id in allIds) {
      if (isKnown(id)) continue; // 标熟 = 永久出队
      final st = _states[id];
      if (st == null || st.isNew) {
        fresh.add(id);
      } else if (st.due == null || !st.due!.isAfter(today)) {
        due.add(id);
      }
    }
    return [...due, ...fresh];
  }

  /// 已处理过的卡片数（学过 或 标熟）—— 章节进度条用它
  int countLearned(List<String> ids) =>
      ids.where((id) => isLearned(id) || isKnown(id)).length;

  /// 某张卡是否学过
  bool isLearned(String id) {
    final s = _states[id];
    return s != null && !s.isNew;
  }

  /// 标熟：永久出队（可撤销）。落在卡牌私有 KV 里，key = 'known'。
  /// 跟 FSRS 的 state 分开存 —— 标熟是「人为判定」，不该污染调度数据；
  /// 撤销时把 key 抹掉，调度历史原样保留。
  bool isKnown(String id) => _kv[id]?['known'] == true;

  void setKnown(String id, bool v) => putKv(id, 'known', v);

  /// 到期复习队列（已学 + 到期，不含新卡）
  List<String> reviewDue(List<String> allIds) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = <String>[];
    for (final id in allIds) {
      if (isKnown(id)) continue; // 标熟 = 永久出队
      final st = _states[id];
      if (st != null &&
          !st.isNew &&
          st.due != null &&
          !st.due!.isAfter(today)) {
        due.add(id);
      }
    }
    return due;
  }

  /// 到期复习数量
  ///
  /// 直接计数，不构造中间 List —— 以前是 `reviewDue(allIds).length`，
  /// 6500 词的书每次调用都要 new 一个 List 装全部到期 id 只为取个 length，
  /// 而首页每次刷新会调好几次。
  int reviewDueCount(List<String> allIds) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var n = 0;
    for (final id in allIds) {
      if (isKnown(id)) continue; // 标熟 = 永久出队
      final st = _states[id];
      if (st != null &&
          !st.isNew &&
          st.due != null &&
          !st.due!.isAfter(today)) {
        n++;
      }
    }
    return n;
  }

  // ---------- 导入 / 导出 ----------

  /// 导出指定卡片的进度（只导这些卡的）
  Map<String, dynamic> exportProgress(List<String> ids) {
    final states = <String, dynamic>{};
    final kv = <String, dynamic>{};
    for (final id in ids) {
      final s = _states[id];
      if (s != null) states[id] = s.toJson();
      final k = _kv[id];
      if (k != null) kv[id] = k;
    }
    return {'card_states': states, 'card_kv': kv};
  }

  /// 导入进度并合并（同 id 覆盖）
  void importProgress(Map<String, dynamic> progress) {
    final states = progress['card_states'];
    if (states is Map) {
      states.forEach((k, v) {
        if (v is Map) {
          _states[k.toString()] =
              CardState.fromJson(Map<String, dynamic>.from(v));
        }
      });
    }
    final kv = progress['card_kv'];
    if (kv is Map) {
      kv.forEach((k, v) {
        if (v is Map) _kv[k.toString()] = Map<String, dynamic>.from(v);
      });
    }
    _compact();
    _flushPrefs();
    _writeDueIndex();
  }

  Future<void> reset() async {
    _states.clear();
    _kv.clear();
    await _prefs?.remove(_kStates);
    await _prefs?.remove(_kKv);
    _compact();
    _writeDueIndex();
  }

  // ---------- 追加日志 ----------

  /// 日志行数超过这个值就 compact（至少 500，且不低于卡片数的 3 倍）
  int get _compactThreshold => math.max(500, _states.length * 3);

  Map<String, dynamic> _doc() => {
        'card_states': _states.map((k, v) => MapEntry(k, v.toJson())),
        'card_kv': _kv,
      };

  /// 追加一行变更；失败就退回整份快照，绝不丢数据
  void _append(String cardId,
      {CardState? st, Map<String, dynamic>? kv, Map<String, dynamic>? rev}) {
    final j = _journal;
    if (j == null) {
      _writeSnap();
      return;
    }
    try {
      final rec = <String, dynamic>{'id': cardId};
      if (st != null) rec['st'] = st.toJson();
      if (kv != null) rec['kv'] = kv;
      if (rev != null) rec['rev'] = rev;
      // flush:false —— 答一张卡就 fsync 一次，在主线程上是几十毫秒级的开销，
      // 越背越卡。append 写入 OS 页缓存后进程崩溃并不丢（OS 保证已写数据），
      // 只有整机掉电才可能丢最后几行；真正的一致性由 compact 的
      // 「写临时文件 + rename」快照兜底（DataDir.writeJsonSync 那边是 fsync 的）。
      j.writeAsStringSync(
        '${json.encode(rec)}\n',
        mode: FileMode.append,
        flush: false,
      );
      _journalLines++;
      if (_journalLines > _compactThreshold) _compact();
      _sinceDue++;
      if (_sinceDue >= _dueEvery) _writeDueIndex();
    } catch (_) {
      _writeSnap();
    }
  }

  void _replayJournal(File j) {
    try {
      for (final line in j.readAsLinesSync()) {
        final t = line.trim();
        if (t.isEmpty) continue;
        _journalLines++;
        try {
          final m = json.decode(t);
          if (m is! Map) continue;
          final id = m['id']?.toString();
          if (id == null || id.isEmpty) continue;
          final st = m['st'];
          if (st is Map) {
            _states[id] = CardState.fromJson(Map<String, dynamic>.from(st));
          }
          final kv = m['kv'];
          if (kv is Map) _kv[id] = Map<String, dynamic>.from(kv);
        } catch (_) {
          // 单行坏了就跳过，不影响其它行
        }
      }
    } catch (_) {}
  }

  /// 把当前状态写成快照，并清空日志
  ///
  /// **顺序不能反**：快照确认写成功，才允许清日志。
  /// 以前是无条件先写后清，快照一旦写失败（磁盘满 / 权限刚丢），
  /// 就变成「快照还是旧的 + 日志已被抹掉」——这段时间复习的全没了，
  /// 而且不报错，用户下次打开才发现进度倒退。
  void _compact() {
    if (!_writeSnap()) {
      // 快照没落上：日志原样留着（下次启动重放），只是不重置行数计数，
      // 这样下一次写操作还会再试一次 compact。
      return;
    }
    try {
      final j = _journal;
      if (j != null && j.existsSync()) j.writeAsStringSync('', flush: true);
    } catch (_) {}
    _journalLines = 0;
    // 压完顺手把 prefs 兜底也刷一遍，保证两处一致。
    // 只在**有文件兜底**时才需要这次同步 —— 纯 prefs 模式下 _append
    // 每次都刷过了，没必要再刷一遍。
    _flushPrefs();
    _writeDueIndex();
  }

  /// 写快照；返回是否成功
  bool _writeSnap() {
    return DataDir.writeJsonSync(_snapFile, _doc());
  }

  static String? _day(DateTime? d) =>
      d == null ? null : d.toIso8601String().substring(0, 10);

  /// 派生索引 due.jsonl：按 due 升序，一行一张卡。
  ///
  /// 给 Agent / 外部工具直接读 —— 「下次复习啥」看文件头几行就行，
  /// 不用解析 progress.json 再遍历。真相源仍是 _states，删了能重建。
  /// 每 [_dueEvery] 次状态变更重建一次；compact / 启动时也会重建。
  /// 字段：id / due / state / s(稳定性) / d(难度) / reps / lapses / last / known。
  void _writeDueIndex() {
    final r = DataDir.cachedRoot;
    if (r == null) return;
    try {
      final entries = _states.entries.toList()
        ..sort((a, b) {
          final da = a.value.due;
          final db = b.value.due;
          if (da == null && db == null) return 0;
          if (da == null) return -1;
          if (db == null) return 1;
          return da.compareTo(db);
        });
      final sb = StringBuffer();
      for (final e in entries) {
        final s = e.value;
        sb.writeln(json.encode({
          'id': e.key,
          'due': _day(s.due),
          'state': s.state,
          's': s.stability,
          'd': s.difficulty,
          'reps': s.reps,
          'lapses': s.lapses,
          'last': _day(s.lastReview),
          'known': _kv[e.key]?['known'] == true,
        }));
      }
      final f = File('${r.path}/$_dueFile');
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(sb.toString(), flush: true);
      tmp.renameSync(f.path);
      _sinceDue = 0;
    } catch (_) {}
  }

  // ---------- prefs 兜底 ----------

  void _loadPrefs() {
    final rawStates = _prefs?.getString(_kStates);
    if (rawStates != null) {
      try {
        final m = json.decode(rawStates) as Map<String, dynamic>;
        m.forEach((k, v) {
          _states[k] = CardState.fromJson(Map<String, dynamic>.from(v as Map));
        });
      } catch (_) {}
    }
    final rawKv = _prefs?.getString(_kKv);
    if (rawKv != null) {
      try {
        final m = json.decode(rawKv) as Map<String, dynamic>;
        m.forEach((k, v) {
          _kv[k] = Map<String, dynamic>.from(v as Map);
        });
      } catch (_) {}
    }
  }

  void _applyDoc(Map<String, dynamic> doc) {
    _states.clear();
    _kv.clear();
    final states = doc['card_states'];
    if (states is Map) {
      states.forEach((k, v) {
        if (v is Map) {
          _states[k.toString()] =
              CardState.fromJson(Map<String, dynamic>.from(v));
        }
      });
    }
    final kv = doc['card_kv'];
    if (kv is Map) {
      kv.forEach((k, v) {
        if (v is Map) _kv[k.toString()] = Map<String, dynamic>.from(v);
      });
    }
  }

  void _flushPrefs() {
    _prefs?.setString(
      _kStates,
      json.encode(_states.map((k, v) => MapEntry(k, v.toJson()))),
    );
    _prefs?.setString(_kKv, json.encode(_kv));
  }
}
