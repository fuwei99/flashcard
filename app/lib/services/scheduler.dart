/// flashcard 调度内核 · FSRS-lite (Dart 版)
/// ================================================================
/// 与 core/fsrs.py 一一对应，保证多端调度结果一致。
/// 原生壳收到卡牌脚本的 answer('again'|'hard'|'good') 后调用这里。
library;

import 'dart:math' as math;

/// FSRS-4.5 默认权重
const List<double> kW = [
  0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2290, 0.8975, 0.0310,
  1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246, 1.5870, 0.2272, 2.8755,
];

const double kRequestRetention = 0.90;
/// 最大间隔封顶（天）：没有它，连续答对的稳定性会把到期推到几十年后
const int kMaxInterval = 365;
/// 学习/重学阶段间隔（天）：今天刚学或忘掉的卡，明天必须复习
const int kLearningInterval = 1;
const double _decay = -0.5;
final double _factor = math.pow(0.9, 1 / _decay) - 1;

/// 评分：三档
enum Rating {
  again(1, 'again'),
  hard(2, 'hard'),
  good(3, 'good');

  const Rating(this.value, this.key);
  final int value;
  final String key;

  static Rating fromKey(String key) {
    switch (key.trim().toLowerCase()) {
      case 'again':
      case 'forgot':
      case '忘记':
        return Rating.again;
      case 'hard':
      case 'fuzzy':
      case '模糊':
        return Rating.hard;
      case 'good':
      case 'remember':
      case '记得':
        return Rating.good;
      default:
        throw ArgumentError('非法评分: $key');
    }
  }
}

/// 卡牌调度状态
class CardState {
  double stability;
  double difficulty;
  int reps;
  int lapses;
  DateTime? due;
  DateTime? lastReview;
  String state; // new / learning / review / relearning

  CardState({
    this.stability = 0,
    this.difficulty = 0,
    this.reps = 0,
    this.lapses = 0,
    this.due,
    this.lastReview,
    this.state = 'new',
  });

  bool get isNew => state == 'new';

  Map<String, dynamic> toJson() => {
        'stability': stability,
        'difficulty': difficulty,
        'reps': reps,
        'lapses': lapses,
        'due': due?.toIso8601String(),
        'last_review': lastReview?.toIso8601String(),
        'state': state,
      };

  factory CardState.fromJson(Map<String, dynamic> j) => CardState(
        stability: (j['stability'] as num?)?.toDouble() ?? 0,
        difficulty: (j['difficulty'] as num?)?.toDouble() ?? 0,
        reps: (j['reps'] as num?)?.toInt() ?? 0,
        lapses: (j['lapses'] as num?)?.toInt() ?? 0,
        due: j['due'] != null ? DateTime.tryParse(j['due'] as String) : null,
        lastReview: j['last_review'] != null
            ? DateTime.tryParse(j['last_review'] as String)
            : null,
        state: j['state'] as String? ?? 'new',
      );
}

double _clamp(double x, double lo, double hi) => math.max(lo, math.min(hi, x));

/// 可提取概率 R(t, S)
double forgettingCurve(double elapsedDays, double stability) {
  if (stability <= 0) return 0;
  return math.pow(1 + _factor * elapsedDays / stability, _decay).toDouble();
}

/// 给定保留率反解间隔天数（封顶）
int nextInterval(double stability, [double retention = kRequestRetention]) {
  final ivl =
      stability / _factor * (math.pow(retention, 1 / _decay) - 1);
  return math.max(1, math.min(kMaxInterval, ivl.round()));
}

double _initStability(int r) => math.max(0.1, kW[r - 1]);
double _initDifficulty(int r) => _clamp(kW[4] - (r - 3) * kW[5], 1, 10);

double _nextDifficulty(double d, int r) {
  var nd = d - kW[6] * (r - 3);
  nd = kW[7] * _initDifficulty(3) + (1 - kW[7]) * nd;
  return _clamp(nd, 1, 10);
}

double _stabilityAfterRecall(double d, double s, double r, int rating) {
  final hardPenalty = rating == 2 ? kW[15] : 1.0;
  // 三档制没有 Easy 档，good 是中性，不吃 easy_bonus（否则稳定性爆炸）
  const easyBonus = 1.0;
  final inc = math.exp(kW[8]) *
      (11 - d) *
      math.pow(s, -kW[9]) *
      (math.exp((1 - r) * kW[10]) - 1) *
      hardPenalty *
      easyBonus;
  return math.max(0.1, s * (1 + inc));
}

double _stabilityAfterForget(double d, double s, double r) {
  final sMin = s / math.exp(kW.length > 17 ? kW[17] : 2.0);
  final ns = kW[11] *
      math.pow(d, -kW[12]) *
      (math.pow(s + 1, kW[13]) - 1) *
      math.exp((1 - r) * kW[14]);
  return math.max(0.1, math.min(ns, sMin));
}

/// 核心 API：喂进卡牌状态 + 评分，吐出更新后的状态
CardState review(CardState card, Rating rating, [DateTime? today]) {
  final now = today ?? DateTime.now();
  final t = DateTime(now.year, now.month, now.day);
  final r = rating.value;

  late int ivl;

  if (card.isNew) {
    // 首次学习：无论评分，一律进 learning，明天必须复习
    card.stability = _initStability(r);
    card.difficulty = _initDifficulty(r);
    card.state = 'learning';
    ivl = kLearningInterval;
  } else if (card.state == 'learning' || card.state == 'relearning') {
    final last = card.lastReview ?? t;
    final elapsed = t.difference(DateTime(last.year, last.month, last.day)).inDays;
    final recall = card.stability > 0
        ? forgettingCurve(elapsed.toDouble(), card.stability)
        : 0.0;
    if (rating == Rating.again) {
      card.stability = _stabilityAfterForget(card.difficulty, card.stability, recall);
      card.lapses += 1;
      card.state = 'relearning';
      ivl = kLearningInterval;
    } else {
      card.stability = _stabilityAfterRecall(card.difficulty, card.stability, recall, r);
      card.state = 'review';
      ivl = nextInterval(card.stability);
    }
    card.difficulty = _nextDifficulty(card.difficulty, r);
  } else {
    final last = card.lastReview ?? t;
    final elapsed = t.difference(DateTime(last.year, last.month, last.day)).inDays;
    final recall = forgettingCurve(elapsed.toDouble(), card.stability);
    if (rating == Rating.again) {
      card.stability = _stabilityAfterForget(card.difficulty, card.stability, recall);
      card.lapses += 1;
      card.state = 'relearning';
      ivl = kLearningInterval; // 忘记：明天必须复习
    } else {
      card.stability = _stabilityAfterRecall(card.difficulty, card.stability, recall, r);
      card.state = 'review';
      ivl = nextInterval(card.stability);
    }
    card.difficulty = _nextDifficulty(card.difficulty, r);
  }

  card.reps += 1;
  card.lastReview = t;
  card.due = t.add(Duration(days: ivl));
  return card;
}
