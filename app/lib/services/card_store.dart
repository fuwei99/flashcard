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

  // 公共文件不可用时的兜底（老版本数据也在这）
  static const _kStates = 'fc_card_states_v1';
  static const _kKv = 'fc_card_kv_v1';

  final Map<String, CardState> _states = {};
  final Map<String, Map<String, dynamic>> _kv = {};
  SharedPreferences? _prefs;

  File? _snap;
  File? _journal;
  int _journalLines = 0;

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
      _flushPrefs();
      // 日志太长就压一次
      if (_journalLines > _compactThreshold) _compact();
      return;
    }

    // 3) 都没有 → 退回 prefs（老版本数据），然后写成新格式
    _loadPrefs();
    _compact();
    _flushPrefs();
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
  int reviewDueCount(List<String> allIds) => reviewDue(allIds).length;

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
  }

  Future<void> reset() async {
    _states.clear();
    _kv.clear();
    await _prefs?.remove(_kStates);
    await _prefs?.remove(_kKv);
    _compact();
  }

  // ---------- 追加日志 ----------

  /// 日志行数超过这个值就 compact（至少 500，且不低于卡片数的 3 倍）
  int get _compactThreshold => math.max(500, _states.length * 3);

  Map<String, dynamic> _doc() => {
        'card_states': _states.map((k, v) => MapEntry(k, v.toJson())),
        'card_kv': _kv,
      };

  /// 追加一行变更；失败就退回整份快照，绝不丢数据
  void _append(String cardId, {CardState? st, Map<String, dynamic>? kv}) {
    final j = _journal;
    if (j == null) {
      _writeSnap();
      return;
    }
    try {
      final rec = <String, dynamic>{'id': cardId};
      if (st != null) rec['st'] = st.toJson();
      if (kv != null) rec['kv'] = kv;
      j.writeAsStringSync(
        '${json.encode(rec)}\n',
        mode: FileMode.append,
        flush: true,
      );
      _journalLines++;
      if (_journalLines > _compactThreshold) _compact();
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
  void _compact() {
    _writeSnap();
    try {
      final j = _journal;
      if (j != null && j.existsSync()) j.writeAsStringSync('', flush: true);
    } catch (_) {}
    _journalLines = 0;
    // 压完顺手把 prefs 兜底也刷一遍，保证两处一致
    _flushPrefs();
  }

  void _writeSnap() {
    DataDir.writeJsonSync(_snapFile, _doc());
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
