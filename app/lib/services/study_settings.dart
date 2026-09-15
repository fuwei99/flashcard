/// 学习设置 + 每日进度
/// ================================================================
/// 管这些事：
///   1. 每日单词背诵量（wordDailyLimit）—— 设置界面改，背完算「单词过关」
///   2. 每日卡牌背诵量（cardDailyLimit）—— 设置界面改，背完算「卡牌过关」
///   3. 今日已背多少（todayWordDone / todayCardDone）—— 背一张 +1，跨天归零
///   4. 三种卡片类型开关：语义选项 / 短句选词 / 语篇选词
library;

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
    _rolloverIfNewDay();
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

  // ---------- 记进度 ----------
  /// 背完一张单词卡，记一笔
  Future<void> markWordDone() async {
    _rolloverIfNewDay();
    todayWordDone++;
    await _prefs?.setInt(_kTodayWordDone, todayWordDone);
  }

  /// 背完一张卡牌，记一笔
  Future<void> markCardDone() async {
    _rolloverIfNewDay();
    todayCardDone++;
    await _prefs?.setInt(_kTodayCardDone, todayCardDone);
  }

  /// 通用记一笔：card=false 记单词（默认），card=true 记卡牌
  Future<void> markDone({bool card = false}) =>
      card ? markCardDone() : markWordDone();

  Future<void> resetToday() async {
    todayWordDone = 0;
    todayCardDone = 0;
    await _prefs?.setInt(_kTodayWordDone, 0);
    await _prefs?.setInt(_kTodayCardDone, 0);
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
}
