/// 学习设置 + 每日进度
/// ================================================================
/// 管两件事：
///   1. 每日背诵量（dailyLimit）—— 在设置界面改
///   2. 今日已背多少（todayDone）—— 背一张 +1，跨天自动归零
library;

import 'package:shared_preferences/shared_preferences.dart';

class StudySettings {
  static const _kDailyLimit = 'fc_daily_limit';
  static const _kTodayDate = 'fc_today_date';
  static const _kTodayDone = 'fc_today_done';

  int dailyLimit = 20;
  String todayDate = '';
  int todayDone = 0;

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    dailyLimit = _prefs!.getInt(_kDailyLimit) ?? 20;
    todayDate = _prefs!.getString(_kTodayDate) ?? '';
    todayDone = _prefs!.getInt(_kTodayDone) ?? 0;
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

  int get remainingToday =>
      (dailyLimit - todayDone).clamp(0, dailyLimit);

  double get todayProgress =>
      dailyLimit <= 0 ? 0 : (todayDone / dailyLimit).clamp(0.0, 1.0);
}
