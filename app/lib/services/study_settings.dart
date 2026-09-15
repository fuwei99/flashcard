/// 学习设置 + 每日进度 + 连续打卡 + 统计 + 提醒
/// ================================================================
///   1. 每日单词/卡牌背诵量（wordDailyLimit / cardDailyLimit）
///   2. 今日已背多少（todayWordDone / todayCardDone）—— 背一张 +1，跨天归零
///   3. 三种卡片类型开关：语义选项 / 短句选词 / 语篇选词
///   4. 连续打卡：streakDays / bestStreak / lastStudyDate / totalStudyDays
///   5. 统计：累计已背 + 按天历史（近 120 天，画柱状图用）
///   6. 背诵提醒：reminderEnabled / reminderHour / reminderMinute
///
/// 打卡口径：当天只要背了 ≥1 张就算「打卡」，连续天数按自然日累加。
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class StudySettings {
  static const _kWordLimit = 'fc_word_daily_limit';
  static const _kCardLimit = 'fc_card_daily_limit';
  static const _kTodayDate = 'fc_today_date';
  static const _kTodayWordDone = 'fc_today_word_done';
  static const _kTodayCardDone = 'fc_today_card_done';

  // 0.3.x 之前的旧键（当时只有一个「每日背诵量」）—— 仅用于一次性迁移
  static const _kLegacyLimit = 'fc_daily_limit';
  static const _kLegacyDone = 'fc_today_done';

  static const _kModeChoice = 'fc_mode_choice';
  static const _kModeSentenceCloze = 'fc_mode_sentence_cloze';
  static const _kModePassageCloze = 'fc_mode_passage_cloze';

  // 连续打卡
  static const _kStreak = 'fc_streak';
  static const _kBestStreak = 'fc_best_streak';
  static const _kLastStudyDate = 'fc_last_study_date';
  static const _kTotalDays = 'fc_total_days';

  // 统计
  static const _kTotalWord = 'fc_total_word_done';
  static const _kTotalCard = 'fc_total_card_done';
  static const _kHistWord = 'fc_hist_word';
  static const _kHistCard = 'fc_hist_card';

  // 提醒
  static const _kRemindOn = 'fc_remind_on';
  static const _kRemindHour = 'fc_remind_hour';
  static const _kRemindMin = 'fc_remind_min';

  /// 每日单词背诵量：背完 = 单词过关 😁
  int wordDailyLimit = 20;

  /// 每日卡牌背诵量：背完 = 卡牌过关 😁
  int cardDailyLimit = 20;

  String todayDate = '';
  int todayWordDone = 0;
  int todayCardDone = 0;

  /// 语义选项（英→中选义）
  bool modeChoice = true;

  /// 短句选词（真题例句挖空）
  bool modeSentenceCloze = true;

  /// 语篇选词（章首文章整篇填词）
  bool modePassageCloze = true;

  // ---------- 连续打卡 ----------
  int streakDays = 0;
  int bestStreak = 0;
  String lastStudyDate = '';
  int totalStudyDays = 0;

  // ---------- 统计 ----------
  int totalWordDone = 0;
  int totalCardDone = 0;
  Map<String, int> histWord = {};
  Map<String, int> histCard = {};

  // ---------- 背诵提醒（默认 22:50） ----------
  bool reminderEnabled = false;
  int reminderHour = 22;
  int reminderMinute = 50;

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();

    // 旧版只有一个 limit / done，首次升级时两边都继承旧值
    final legacyLimit = _prefs!.getInt(_kLegacyLimit);
    wordDailyLimit = _prefs!.getInt(_kWordLimit) ?? legacyLimit ?? 20;
    cardDailyLimit = _prefs!.getInt(_kCardLimit) ?? legacyLimit ?? 20;

    todayDate = _prefs!.getString(_kTodayDate) ?? '';
    todayWordDone =
        _prefs!.getInt(_kTodayWordDone) ?? _prefs!.getInt(_kLegacyDone) ?? 0;
    todayCardDone = _prefs!.getInt(_kTodayCardDone) ?? 0;

    modeChoice = _prefs!.getBool(_kModeChoice) ?? true;
    modeSentenceCloze = _prefs!.getBool(_kModeSentenceCloze) ?? true;
    modePassageCloze = _prefs!.getBool(_kModePassageCloze) ?? true;

    streakDays = _prefs!.getInt(_kStreak) ?? 0;
    bestStreak = _prefs!.getInt(_kBestStreak) ?? 0;
    lastStudyDate = _prefs!.getString(_kLastStudyDate) ?? '';
    totalStudyDays = _prefs!.getInt(_kTotalDays) ?? 0;

    totalWordDone = _prefs!.getInt(_kTotalWord) ?? 0;
    totalCardDone = _prefs!.getInt(_kTotalCard) ?? 0;
    histWord = _decodeHist(_prefs!.getString(_kHistWord));
    histCard = _decodeHist(_prefs!.getString(_kHistCard));

    reminderEnabled = _prefs!.getBool(_kRemindOn) ?? false;
    reminderHour = _prefs!.getInt(_kRemindHour) ?? 22;
    reminderMinute = _prefs!.getInt(_kRemindMin) ?? 50;

    _rolloverIfNewDay();
  }

  static Map<String, int> _decodeHist(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final m = json.decode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// 跨天自动把今日进度清零
  void _rolloverIfNewDay() {
    final d = dateStr(DateTime.now());
    if (todayDate != d) {
      todayDate = d;
      todayWordDone = 0;
      todayCardDone = 0;
      _prefs?.setString(_kTodayDate, d);
      _prefs?.setInt(_kTodayWordDone, 0);
      _prefs?.setInt(_kTodayCardDone, 0);
    }
  }

  static String dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---------- 每日量 ----------
  Future<void> setWordDailyLimit(int n) async {
    wordDailyLimit = n.clamp(1, 999);
    await _prefs?.setInt(_kWordLimit, wordDailyLimit);
  }

  Future<void> setCardDailyLimit(int n) async {
    cardDailyLimit = n.clamp(1, 999);
    await _prefs?.setInt(_kCardLimit, cardDailyLimit);
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

  // ---------- 提醒 ----------
  Future<void> setReminder({bool? enabled, int? hour, int? minute}) async {
    if (enabled != null) {
      reminderEnabled = enabled;
      await _prefs?.setBool(_kRemindOn, enabled);
    }
    if (hour != null) {
      reminderHour = hour.clamp(0, 23);
      await _prefs?.setInt(_kRemindHour, reminderHour);
    }
    if (minute != null) {
      reminderMinute = minute.clamp(0, 59);
      await _prefs?.setInt(_kRemindMin, reminderMinute);
    }
  }

  String get reminderTimeLabel =>
      '${reminderHour.toString().padLeft(2, '0')}:${reminderMinute.toString().padLeft(2, '0')}';

  // ---------- 记进度 ----------
  /// 背完一张单词卡，记一笔
  Future<void> markWordDone() async {
    _rolloverIfNewDay();
    todayWordDone++;
    totalWordDone++;
    final d = dateStr(DateTime.now());
    histWord[d] = (histWord[d] ?? 0) + 1;
    _trimHistory();
    _touchStudyDay();
    await _prefs?.setInt(_kTodayWordDone, todayWordDone);
    await _prefs?.setInt(_kTotalWord, totalWordDone);
    await _prefs?.setString(_kHistWord, json.encode(histWord));
  }

  /// 背完一张卡牌，记一笔
  Future<void> markCardDone() async {
    _rolloverIfNewDay();
    todayCardDone++;
    totalCardDone++;
    final d = dateStr(DateTime.now());
    histCard[d] = (histCard[d] ?? 0) + 1;
    _trimHistory();
    _touchStudyDay();
    await _prefs?.setInt(_kTodayCardDone, todayCardDone);
    await _prefs?.setInt(_kTotalCard, totalCardDone);
    await _prefs?.setString(_kHistCard, json.encode(histCard));
  }

  /// 通用记一笔：card=false 记单词（默认），card=true 记卡牌
  Future<void> markDone({bool card = false}) =>
      card ? markCardDone() : markWordDone();

  /// 当天首次学习 -> 打卡：连续 +1（隔天 >1 天则从 1 重来）
  void _touchStudyDay() {
    final today = dateStr(DateTime.now());
    if (lastStudyDate == today) return;
    final yesterday =
        dateStr(DateTime.now().subtract(const Duration(days: 1)));
    streakDays = (lastStudyDate == yesterday) ? streakDays + 1 : 1;
    lastStudyDate = today;
    totalStudyDays++;
    if (streakDays > bestStreak) bestStreak = streakDays;
    _prefs?.setInt(_kStreak, streakDays);
    _prefs?.setInt(_kBestStreak, bestStreak);
    _prefs?.setString(_kLastStudyDate, lastStudyDate);
    _prefs?.setInt(_kTotalDays, totalStudyDays);
  }

  void _trimHistory() {
    if (histWord.length > 130) {
      final keys = histWord.keys.toList()..sort();
      for (final k in keys.take(histWord.length - 120)) {
        histWord.remove(k);
      }
    }
    if (histCard.length > 130) {
      final keys = histCard.keys.toList()..sort();
      for (final k in keys.take(histCard.length - 120)) {
        histCard.remove(k);
      }
    }
  }

  Future<void> resetToday() async {
    todayWordDone = 0;
    todayCardDone = 0;
    await _prefs?.setInt(_kTodayWordDone, 0);
    await _prefs?.setInt(_kTodayCardDone, 0);
  }

  /// 清零全部统计（打卡 / 累计 / 历史），设置里「重置学习统计」用
  Future<void> resetStats() async {
    streakDays = 0;
    bestStreak = 0;
    lastStudyDate = '';
    totalStudyDays = 0;
    totalWordDone = 0;
    totalCardDone = 0;
    histWord = {};
    histCard = {};
    await _prefs?.setInt(_kStreak, 0);
    await _prefs?.setInt(_kBestStreak, 0);
    await _prefs?.setString(_kLastStudyDate, '');
    await _prefs?.setInt(_kTotalDays, 0);
    await _prefs?.setInt(_kTotalWord, 0);
    await _prefs?.setInt(_kTotalCard, 0);
    await _prefs?.setString(_kHistWord, '{}');
    await _prefs?.setString(_kHistCard, '{}');
  }

  // ---------- 单词进度 ----------
  int get wordRemaining =>
      (wordDailyLimit - todayWordDone).clamp(0, wordDailyLimit);
  double get wordProgress => wordDailyLimit <= 0
      ? 0
      : (todayWordDone / wordDailyLimit).clamp(0.0, 1.0);

  /// 今日单词量达成 = 过关
  bool get wordPassed => todayWordDone >= wordDailyLimit;

  // ---------- 卡牌进度 ----------
  int get cardRemaining =>
      (cardDailyLimit - todayCardDone).clamp(0, cardDailyLimit);
  double get cardProgress => cardDailyLimit <= 0
      ? 0
      : (todayCardDone / cardDailyLimit).clamp(0.0, 1.0);

  /// 今日卡牌量达成 = 过关
  bool get cardPassed => todayCardDone >= cardDailyLimit;

  /// 今天是否已打卡
  bool get checkedInToday => lastStudyDate == dateStr(DateTime.now());

  /// 今天要显示的连续天数：昨天/今天有学习才延续，否则断签显示 0
  int get currentStreak {
    final today = dateStr(DateTime.now());
    final yesterday =
        dateStr(DateTime.now().subtract(const Duration(days: 1)));
    if (lastStudyDate == today || lastStudyDate == yesterday) return streakDays;
    return 0;
  }

  /// 今日总已背（单词 + 卡牌）
  int get todayTotal => todayWordDone + todayCardDone;

  /// 近 n 天历史（从早到晚），画柱状图用
  List<Map<String, dynamic>> recentDays(int n) {
    final out = <Map<String, dynamic>>[];
    final now = DateTime.now();
    for (var i = n - 1; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      final k = dateStr(d);
      out.add({
        'date': k,
        'label': '${d.month}/${d.day}',
        'word': histWord[k] ?? 0,
        'card': histCard[k] ?? 0,
      });
    }
    return out;
  }
}
