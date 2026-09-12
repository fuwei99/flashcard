/// 卡牌状态存储：调度状态 + 卡牌私有 KV
/// 用 shared_preferences 的 JSON blob，简单可靠；后期可换 sqflite。
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'scheduler.dart';

class CardStore {
  static const _kStates = 'fc_card_states_v1';
  static const _kKv = 'fc_card_kv_v1';

  final Map<String, CardState> _states = {};
  final Map<String, Map<String, dynamic>> _kv = {};
  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final rawStates = _prefs!.getString(_kStates);
    if (rawStates != null) {
      final m = json.decode(rawStates) as Map<String, dynamic>;
      m.forEach((k, v) {
        _states[k] = CardState.fromJson(Map<String, dynamic>.from(v as Map));
      });
    }
    final rawKv = _prefs!.getString(_kKv);
    if (rawKv != null) {
      final m = json.decode(rawKv) as Map<String, dynamic>;
      m.forEach((k, v) {
        _kv[k] = Map<String, dynamic>.from(v as Map);
      });
    }
  }

  CardState stateOf(String cardId) =>
      _states[cardId] ?? CardState();

  Map<String, dynamic> kvOf(String cardId) => _kv[cardId] ?? {};

  void putKv(String cardId, String key, dynamic value) {
    (_kv[cardId] ??= {})[key] = value;
    _flushKv();
  }

  void putState(String cardId, CardState st) {
    _states[cardId] = st;
    _flushStates();
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

  void _flushStates() {
    _prefs?.setString(
      _kStates,
      json.encode(_states.map((k, v) => MapEntry(k, v.toJson()))),
    );
  }

  void _flushKv() {
    _prefs?.setString(_kKv, json.encode(_kv));
  }

  Future<void> reset() async {
    _states.clear();
    _kv.clear();
    await _prefs?.remove(_kStates);
    await _prefs?.remove(_kKv);
  }
}
