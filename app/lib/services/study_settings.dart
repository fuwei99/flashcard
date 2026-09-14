/// 学习设置 + 每日进度
/// ================================================================
/// 管三件事：
///   1. 每日背诵量（dailyLimit）—— 在设置界面改
///   2. 今日已背多少（todayDone）—— 背一张 +1，跨天自动归零
///   3. 三种卡片类型开关：语义选项 / 短句选词 / 语篇选词
library;

import 'package:shared_preferences/shared_preferences.dart';

class StudySettings {
  static const _kDailyLimit = 'fc_daily_limit';
  static const _kTodayDate = 'fc_today_date';
  static const _kTodayDone = 'fc_today_done';

  static const _kModeChoice = 'fc_mode_choice';
  static const _kModeSentenceCloze = 'fc_mode_sentence_cloze';
  static const _kModePassageCloze = 'fc_mode_passage_cloze';

  int dailyLimit = 20;
  String todayDate = '';
  int todayDone = 0;

  /// 语义选项（英→中选义）
  bool modeChoice = true;

  /// 短句选词（真题例句挖空）
  bool modeSentenceCloze = true;

  /// 语篇选词（章首文章整篇填词）
  bool modePassageCloze = true;

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    dailyLimit = _prefs!.getInt(_kDailyLimit) ?? 20;
    todayDate = _prefs!.getString(_kTodayDate) ?? '';
    todayDone = _prefs!.getInt(_kTodayDone) ?? 0;
    modeChoice = _prefs!.getBool(_kModeChoice) ?? true;
    modeSentenceCloze = _prefs!.getBool(_kModeSentenceCloze) ?? true;
    modePassageCloze = _prefs!.getBool(_kModePassageCloze) ?? true;
    _rolloverIfNewDay();
  }

  /// 跨天自动把今日进度清零
  void _rolloverIfNewDay() {
    final d = dateStr(DateTime.now());
    if (todayDate != d) {
      todayDate = d;
      todayDone = 0;
      _prefs?.setString(_kTodayDate, d);
      _prefs?.setInt(_kTodayDone, 0);
    }
  }

  static String dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> setDailyLimit(int n) async {
    dailyLimit = n.clamp(1, 999);
    await _prefs?.setInt(_kDailyLimit, dailyLimit);
  }

  // ---------- 三种卡片类型开关 ----------
  Future<void> setModeChoice(bool v) async {
    modeChoice = v;
    await _prefs?.setBool(_kModeChoice, v);
  }

  Future<void> setModeSentenceCloze(bool v) async {
    modeSentenceCloze = v;
    await _prefs?.setBool(_kModeSentenceCloze, v);
  }

  Future<void> setModePassageCloze(bool v) async {
    modePassageCloze = v;
    await _prefs?.setBool(_kModePassageCloze, v);
  }

  /// 至少保留一种考法，否则「忘记/模糊」的卡无处可考
  bool get anyRetestEnabled => modeChoice || modeSentenceCloze;

  /// 背完一张，记一笔
  Future<void> markDone() async {
    _rolloverIfNewDay();
    todayDone++;
    await _prefs?.setInt(_kTodayDone, todayDone);
  }

  Future<void> resetToday() async {
    todayDone = 0;
    await _prefs?.setInt(_kTodayDone, 0);
  }

  int get remainingToday => (dailyLimit - todayDone).clamp(0, dailyLimit);

  double get todayProgress =>
      dailyLimit <= 0 ? 0 : (todayDone / dailyLimit).clamp(0.0, 1.0);
}
