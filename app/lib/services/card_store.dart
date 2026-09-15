/// 卡牌状态存储：调度状态 + 卡牌私有 KV
/// ================================================================
/// 落盘位置：<公共目录>/Flashcard/progress.json
///
///   {
///     "card_states": { "<cardId>": { ...FSRS 状态... } },
///     "card_kv":     { "<cardId>": { ...卡片私有数据... } }
///   }
///
/// 这个文件可以直接用文本编辑器 / Agent 改，改完重启 app 生效。
/// 公共目录不可用时退回 SharedPreferences（app 私有，Agent 读不到）。
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'data_dir.dart';
import 'scheduler.dart';

class CardStore {
  static const _fileName = 'progress.json';

  // 公共文件不可用时的兜底（老版本数据也在这）
  static const _kStates = 'fc_card_states_v1';
  static const _kKv = 'fc_card_kv_v1';

  final Map<String, CardState> _states = {};
  final Map<String, Map<String, dynamic>> _kv = {};
  SharedPreferences? _prefs;

  /// 是否落在公共文件上（Agent 可读）
  bool get fileBacked => DataDir.available;

  Future<void> init() async {
    await DataDir.root(); // 先解析公共目录，后面同步写才有根
    _prefs = await SharedPreferences.getInstance();

    // 1) 公共文件优先 —— Agent 改过的以它为准
    final doc = DataDir.readJsonSync(_fileName);
    if (doc != null) {
      _applyDoc(doc);
      _flushPrefs(); // 顺手备份一份到 prefs
      return;
    }

    // 2) 退回 prefs（老版本数据）
    _loadPrefs();

    // 3) 首次：把老数据搬到公共文件
    _flushFile();
  }

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

  Map<String, dynamic> toDoc() => {
        'card_states': _states.map((k, v) => MapEntry(k, v.toJson())),
        'card_kv': _kv,
      };

  // ---------- 读 ----------

  CardState stateOf(String cardId) => _states[cardId] ?? CardState();

  Map<String, dynamic> kvOf(String cardId) => _kv[cardId] ?? {};

  // ---------- 写 ----------

  void putKv(String cardId, String key, dynamic value) {
    (_kv[cardId] ??= {})[key] = value;
    _flush();
  }

  void putState(String cardId, CardState st) {
    _states[cardId] = st;
    _flush();
  }

  /// 到期 / 新卡 的复习队列
  List<String> dueQueue(List<String> allIds) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = <String>[];
    final fresh = <String>[];
    for (final id in allIds) {
      final st = _states[id];
      if (st == null || st.isNew) {
        fresh.add(id);
      } else if (st.due == null || !st.due!.isAfter(today)) {
        due.add(id);
      }
    }
    return [...due, ...fresh];
  }

  int get dueCount => _states.values
      .where((s) =>
          !s.isNew &&
          s.due != null &&
          !s.due!.isAfter(DateTime.now()))
      .length;

  /// 已学过的卡片数（state != new）
  int countLearned(List<String> ids) => ids.where(isLearned).length;

  /// 某张卡是否学过
  bool isLearned(String id) {
    final s = _states[id];
    return s != null && !s.isNew;
  }

  /// 到期复习队列（已学 + 到期，不含新卡）
  List<String> reviewDue(List<String> allIds) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final due = <String>[];
    for (final id in allIds) {
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
    _flush();
  }

  Future<void> reset() async {
    _states.clear();
    _kv.clear();
    await _prefs?.remove(_kStates);
    await _prefs?.remove(_kKv);
    _flush();
  }

  // ---------- 落盘 ----------

  void _flush() {
    _flushFile();
    _flushPrefs();
  }

  void _flushFile() {
    DataDir.writeJsonSync(_fileName, toDoc());
  }

  void _flushPrefs() {
    _prefs?.setString(
      _kStates,
      json.encode(_states.map((k, v) => MapEntry(k, v.toJson()))),
    );
    _prefs?.setString(_kKv, json.encode(_kv));
  }
}
