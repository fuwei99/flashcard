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
///
/// 落盘：<公共目录>/Flashcard/settings.json（Agent 可直接改，重启生效），
/// 公共目录不可用时退回 SharedPreferences。
library;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'data_dir.dart';
import 'js_log.dart';
import 'tts_log.dart';

class StudySettings {
  static const _fileName = 'settings.json';

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

  // 调试日志
  static const _kTtsLog = 'fc_tts_log';

  // TTS 引擎（在线 OpenAI 兼容）
  static const _kTtsOpenAiEnabled = 'fc_tts_openai_enabled';
  static const _kTtsOpenAiBaseUrl = 'fc_tts_openai_base_url';
  static const _kTtsOpenAiApiKey = 'fc_tts_openai_api_key';
  static const _kTtsOpenAiModel = 'fc_tts_openai_model';
  static const _kTtsOpenAiVoice = 'fc_tts_openai_voice';
  static const _kTtsOpenAiFormat = 'fc_tts_openai_format';
  static const _kTtsOpenAiSpeed = 'fc_tts_openai_speed';
  static const _kTtsWordCache = 'fc_tts_word_cache';

  // 每日复习上限
  static const _kReviewLimit = 'fc_review_limit';

  /// 每日单词背诵量：背完 = 单词过关 😁
  int wordDailyLimit = 20;

  /// 每日卡牌背诵量：背完 = 卡牌过关 😁
  int cardDailyLimit = 20;

  /// 每日复习上限：到期词一天最多复习这么多，超出的顺延到明天。
  /// 默认 200。复习不吃 [wordDailyLimit] 那档，单独算。
  int reviewDailyLimit = 200;

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

  // ---------- 调试日志 ----------
  /// TTS 日志开关：写 <公共目录>/logs/tts/，默认开
  bool ttsLogEnabled = true;

  // ---------- TTS 引擎（在线 OpenAI 兼容，默认关 = 走系统 TTS） ----------
  /// 在线引擎总开关：单词走它（缓存秒播），长句走它（流式播放）
  bool ttsOpenAiEnabled = false;

  /// OpenAI 兼容接口地址，如 https://aihubmix.com/v1
  String ttsOpenAiBaseUrl = '';

  /// API Key
  String ttsOpenAiApiKey = '';

  /// 模型名
  String ttsOpenAiModel = 'gpt-4o-mini-tts';

  /// 音色
  String ttsOpenAiVoice = 'alloy';

  /// 音频格式（mp3 / wav / opus / aac / flac）
  String ttsOpenAiFormat = 'mp3';

  /// 语速 0.5~2.0
  double ttsOpenAiSpeed = 1.0;

  /// 单词音频缓存开关（默认开：读过的词存 cache/tts/，下次秒播）
  bool ttsWordCacheEnabled = true;

  SharedPreferences? _prefs;

  /// 数据是否落在公共文件（Agent 可读）
  bool get fileBacked => DataDir.available;

  Future<void> init() async {
    await DataDir.root(); // 先解析公共目录
    _prefs = await SharedPreferences.getInstance();

    // 1) 公共文件优先 —— Agent 改过的以它为准
    final doc = DataDir.readJsonSync(_fileName);
    if (doc != null) {
      _applyJson(doc);
      _rolloverIfNewDay();
      _persist();
      return;
    }

    // 2) 退回 prefs（老版本数据）
    // 旧版只有一个 limit / done，首次升级时两边都继承旧值
    final legacyLimit = _prefs!.getInt(_kLegacyLimit);
    wordDailyLimit = _prefs!.getInt(_kWordLimit) ?? legacyLimit ?? 20;
    cardDailyLimit = _prefs!.getInt(_kCardLimit) ?? legacyLimit ?? 20;
    reviewDailyLimit = _prefs!.getInt(_kReviewLimit) ?? 200;

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
    ttsLogEnabled = _prefs!.getBool(_kTtsLog) ?? true;

    ttsOpenAiEnabled = _prefs!.getBool(_kTtsOpenAiEnabled) ?? false;
    ttsOpenAiBaseUrl = _prefs!.getString(_kTtsOpenAiBaseUrl) ?? '';
    ttsOpenAiApiKey = _prefs!.getString(_kTtsOpenAiApiKey) ?? '';
    ttsOpenAiModel = _prefs!.getString(_kTtsOpenAiModel) ?? 'gpt-4o-mini-tts';
    ttsOpenAiVoice = _prefs!.getString(_kTtsOpenAiVoice) ?? 'alloy';
    ttsOpenAiFormat = _prefs!.getString(_kTtsOpenAiFormat) ?? 'mp3';
    ttsOpenAiSpeed = _prefs!.getDouble(_kTtsOpenAiSpeed) ?? 1.0;
    ttsWordCacheEnabled = _prefs!.getBool(_kTtsWordCache) ?? true;

    _rolloverIfNewDay();

    // 3) 首次：把老数据搬到公共文件
    _persist();
  }

  // ---------- 序列化 ----------

  Map<String, dynamic> toJson() => {
        'word_daily_limit': wordDailyLimit,
        'card_daily_limit': cardDailyLimit,
        'review_daily_limit': reviewDailyLimit,
        'today_date': todayDate,
        'today_word_done': todayWordDone,
        'today_card_done': todayCardDone,
        'mode_choice': modeChoice,
        'mode_sentence_cloze': modeSentenceCloze,
        'mode_passage_cloze': modePassageCloze,
        'streak_days': streakDays,
        'best_streak': bestStreak,
        'last_study_date': lastStudyDate,
        'total_study_days': totalStudyDays,
        'total_word_done': totalWordDone,
        'total_card_done': totalCardDone,
        'hist_word': histWord,
        'hist_card': histCard,
        'reminder_enabled': reminderEnabled,
        'reminder_hour': reminderHour,
        'reminder_minute': reminderMinute,
        'tts_log_enabled': ttsLogEnabled,
        'tts_openai_enabled': ttsOpenAiEnabled,
        'tts_openai_base_url': ttsOpenAiBaseUrl,
        'tts_openai_api_key': ttsOpenAiApiKey,
        'tts_openai_model': ttsOpenAiModel,
        'tts_openai_voice': ttsOpenAiVoice,
        'tts_openai_format': ttsOpenAiFormat,
        'tts_openai_speed': ttsOpenAiSpeed,
        'tts_word_cache': ttsWordCacheEnabled,
      };

  void _applyJson(Map<String, dynamic> m) {
    int i(String k, int d) => m[k] is num ? (m[k] as num).toInt() : d;
    bool b(String k, bool d) => m[k] is bool ? m[k] as bool : d;
    String s(String k, String d) => m[k] is String ? m[k] as String : d;
    Map<String, int> h(String k) {
      final v = m[k];
      if (v is! Map) return <String, int>{};
      return v.map((kk, vv) =>
          MapEntry(kk.toString(), vv is num ? vv.toInt() : 0));
    }

    wordDailyLimit = i('word_daily_limit', wordDailyLimit).clamp(1, 999);
    cardDailyLimit = i('card_daily_limit', cardDailyLimit).clamp(1, 999);
    reviewDailyLimit = i('review_daily_limit', reviewDailyLimit).clamp(1, 9999);
    todayDate = s('today_date', todayDate);
    todayWordDone = i('today_word_done', todayWordDone);
    todayCardDone = i('today_card_done', todayCardDone);
    modeChoice = b('mode_choice', modeChoice);
    modeSentenceCloze = b('mode_sentence_cloze', modeSentenceCloze);
    modePassageCloze = b('mode_passage_cloze', modePassageCloze);
    streakDays = i('streak_days', streakDays);
    bestStreak = i('best_streak', bestStreak);
    lastStudyDate = s('last_study_date', lastStudyDate);
    totalStudyDays = i('total_study_days', totalStudyDays);
    totalWordDone = i('total_word_done', totalWordDone);
    totalCardDone = i('total_card_done', totalCardDone);
    histWord = h('hist_word');
    histCard = h('hist_card');
    reminderEnabled = b('reminder_enabled', reminderEnabled);
    reminderHour = i('reminder_hour', reminderHour).clamp(0, 23);
    reminderMinute = i('reminder_minute', reminderMinute).clamp(0, 59);
    ttsLogEnabled = b('tts_log_enabled', ttsLogEnabled);

    ttsOpenAiEnabled = b('tts_openai_enabled', ttsOpenAiEnabled);
    ttsOpenAiBaseUrl = s('tts_openai_base_url', ttsOpenAiBaseUrl);
    ttsOpenAiApiKey = s('tts_openai_api_key', ttsOpenAiApiKey);
    ttsOpenAiModel = s('tts_openai_model', ttsOpenAiModel);
    ttsOpenAiVoice = s('tts_openai_voice', ttsOpenAiVoice);
    ttsOpenAiFormat = s('tts_openai_format', ttsOpenAiFormat);
    final spd = m['tts_openai_speed'];
    ttsOpenAiSpeed = spd is num
        ? spd.toDouble().clamp(0.5, 2.0).toDouble()
        : ttsOpenAiSpeed;
    ttsWordCacheEnabled = b('tts_word_cache', ttsWordCacheEnabled);
  }

  /// 落盘：公共文件 + prefs 备份
  void _persist() {
    DataDir.writeJsonSync(_fileName, toJson());
    _prefs?.setInt(_kWordLimit, wordDailyLimit);
    _prefs?.setInt(_kCardLimit, cardDailyLimit);
    _prefs?.setInt(_kReviewLimit, reviewDailyLimit);
    _prefs?.setString(_kTodayDate, todayDate);
    _prefs?.setInt(_kTodayWordDone, todayWordDone);
    _prefs?.setInt(_kTodayCardDone, todayCardDone);
    _prefs?.setBool(_kModeChoice, modeChoice);
    _prefs?.setBool(_kModeSentenceCloze, modeSentenceCloze);
    _prefs?.setBool(_kModePassageCloze, modePassageCloze);
    _prefs?.setInt(_kStreak, streakDays);
    _prefs?.setInt(_kBestStreak, bestStreak);
    _prefs?.setString(_kLastStudyDate, lastStudyDate);
    _prefs?.setInt(_kTotalDays, totalStudyDays);
    _prefs?.setInt(_kTotalWord, totalWordDone);
    _prefs?.setInt(_kTotalCard, totalCardDone);
    _prefs?.setString(_kHistWord, json.encode(histWord));
    _prefs?.setString(_kHistCard, json.encode(histCard));
    _prefs?.setBool(_kRemindOn, reminderEnabled);
    _prefs?.setInt(_kRemindHour, reminderHour);
    _prefs?.setInt(_kRemindMin, reminderMinute);
    _prefs?.setBool(_kTtsLog, ttsLogEnabled);
    // 日志开关同步给静态 logger（TTS / 切卡共用这一个开关）
    TtsLog.enabled = ttsLogEnabled;
    SwitchLog.enabled = ttsLogEnabled;
    JsLog.enabled = ttsLogEnabled;

    _prefs?.setBool(_kTtsOpenAiEnabled, ttsOpenAiEnabled);
    _prefs?.setString(_kTtsOpenAiBaseUrl, ttsOpenAiBaseUrl);
    _prefs?.setString(_kTtsOpenAiApiKey, ttsOpenAiApiKey);
    _prefs?.setString(_kTtsOpenAiModel, ttsOpenAiModel);
    _prefs?.setString(_kTtsOpenAiVoice, ttsOpenAiVoice);
    _prefs?.setString(_kTtsOpenAiFormat, ttsOpenAiFormat);
    _prefs?.setDouble(_kTtsOpenAiSpeed, ttsOpenAiSpeed);
    _prefs?.setBool(_kTtsWordCache, ttsWordCacheEnabled);
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
      _persist();
    }
  }

  static String dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---------- 每日量 ----------
  Future<void> setWordDailyLimit(int n) async {
    wordDailyLimit = n.clamp(1, 999);
    _persist();
  }

  Future<void> setCardDailyLimit(int n) async {
    cardDailyLimit = n.clamp(1, 999);
    _persist();
  }

  /// 每日复习上限：填多少就是多少，超出的顺延明天
  Future<void> setReviewDailyLimit(int n) async {
    reviewDailyLimit = n.clamp(1, 9999);
    _persist();
  }

  // ---------- 三种卡片类型开关 ----------
  Future<void> setModeChoice(bool v) async {
    modeChoice = v;
    _persist();
  }

  Future<void> setModeSentenceCloze(bool v) async {
    modeSentenceCloze = v;
    _persist();
  }

  Future<void> setModePassageCloze(bool v) async {
    modePassageCloze = v;
    _persist();
  }

  /// 至少保留一种考法，否则「忘记/模糊」的卡无处可考
  bool get anyRetestEnabled => modeChoice || modeSentenceCloze;

  // ---------- 提醒 ----------
  Future<void> setReminder({bool? enabled, int? hour, int? minute}) async {
    if (enabled != null) reminderEnabled = enabled;
    if (hour != null) reminderHour = hour.clamp(0, 23);
    if (minute != null) reminderMinute = minute.clamp(0, 59);
    _persist();
  }

  // ---------- 调试日志 ----------
  Future<void> setTtsLogEnabled(bool v) async {
    ttsLogEnabled = v;
    TtsLog.enabled = v;
    SwitchLog.enabled = v;
    JsLog.enabled = v;
    _persist();
  }

  // ---------- TTS 引擎 ----------
  Future<void> setTtsOpenAiEnabled(bool v) async {
    ttsOpenAiEnabled = v;
    _persist();
  }

  Future<void> setTtsWordCacheEnabled(bool v) async {
    ttsWordCacheEnabled = v;
    _persist();
  }

  Future<void> setTtsOpenAi({
    bool? enabled,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? voice,
    String? format,
    double? speed,
  }) async {
    if (enabled != null) ttsOpenAiEnabled = enabled;
    if (baseUrl != null) ttsOpenAiBaseUrl = baseUrl;
    if (apiKey != null) ttsOpenAiApiKey = apiKey;
    if (model != null && model.trim().isNotEmpty) ttsOpenAiModel = model.trim();
    if (voice != null && voice.trim().isNotEmpty) ttsOpenAiVoice = voice.trim();
    if (format != null && format.trim().isNotEmpty) ttsOpenAiFormat = format.trim();
    if (speed != null) ttsOpenAiSpeed = speed.clamp(0.5, 2.0).toDouble();
    _persist();
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
    _persist();
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
    _persist();
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
    _persist();
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
    _persist();
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
