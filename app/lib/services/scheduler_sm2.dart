/// flashcard 调度内核 · SM-2 variant（Dart 版）
/// ================================================================
/// 这是**第二套**调度引擎，服务于 srs_basic 引擎的书（知识点卡）。
/// 与 [scheduler.dart] 的 FSRS-lite 并存，互不干涉、互不换算。
///
/// ## 为什么要有两套，而不是「换个参数」
///
/// 因为两类卡记的**不是同一种东西**：
///
/// | | FSRS-lite（language） | SM-2（srs_basic） |
/// |---|---|---|
/// | 记忆单元 | 一个**词**（word） | 一**张卡**（card） |
/// | 目标 | 在阅读/听力里**认出来** | 把整句话 / 整个概念**复述出来** |
/// | 度量 | 连续量：可提取概率 R(t,S) | 离散量：ELO 式难度 + 学习步 |
/// | 评分 | 3 档（忘记/模糊/记得） | 4 档（重来/困难/良好/简单） |
/// | 时间粒度 | **天**（due 截断到日） | **分钟**（学习步 1 分 / 10 分） |
/// | 到期 | 明天再见 / 间隔越来越长 | 当轮就要再过一遍 |
///
/// 「R(t,S)」对「带传动的弹性滑动是什么」这种卡是没有语义的 ——
/// 你不是「忘了 8%」，你是「背得出来 / 背不出来 / 背漏了一句」。
/// 反过来，SM-2 的「学习步」对单词也没意义：一个词没必要 1 分钟后再看一次。
///
/// ## 时间粒度的坑（这是两套引擎不能硬合并的真正原因）
///
/// FSRS-lite 的 `due` 一律被 `DateTime(y,m,d)` 截断到「日」——
/// 因为词的复习节奏本来就是按天的。srs_basic 不行：
/// 学习步是 **1 分钟 / 10 分钟**，截断到日等于把整条学习步链塌成「明天见」，
/// 新卡一进来就被推到今天结束。所以 [Sm2State.due] 是**完整 DateTime**，
/// 从不做日截断。
///
/// ## 参数
///
/// 默认值是 Anki 的出厂设置（learning steps 1m/10m、ease 2.5、min ease 1.3 …）。
/// 书可以在 manifest 的 `srs` 段里覆盖，见 [Sm2Params.fromJson]。
library;

import 'dart:math' as math;

/// 评分：四档（比 words 那套多一个 easy）
enum Sm2Rating {
  again(1, 'again'),
  hard(2, 'hard'),
  good(3, 'good'),
  easy(4, 'easy');

  const Sm2Rating(this.value, this.key);
  final int value;
  final String key;

  /// 宽容解析：只接受明确写出来的四档，**绝不兜底成 good**。
  /// （历史教训见 scheduler.dart 里 FSRS 那条 —— 脏评分兜底会把卡
  /// 无声地往后推，且不可逆。）
  static Sm2Rating fromKey(String key) {
    switch (key.trim().toLowerCase()) {
      case 'again':
      case 'forgot':
      case '重来':
      case '忘记':
        return Sm2Rating.again;
      case 'hard':
      case '困难':
      case '模糊':
        return Sm2Rating.hard;
      case 'good':
      case '良好':
      case '记得':
        return Sm2Rating.good;
      case 'easy':
      case '简单':
        return Sm2Rating.easy;
      default:
        throw ArgumentError('非法评分: $key');
    }
  }

  static bool isLegal(String key) {
    try {
      fromKey(key);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// 调度参数（一本卡组一套；默认 = Anki 出厂值）
class Sm2Params {
  /// 学习步（分钟）：新卡进 learn，走完这串才毕业
  final List<int> learningSteps;

  /// 重学步（分钟）：答错的复习卡回 relearn，走完回 review
  final List<int> relearningSteps;

  /// 学习步走完后的毕业间隔（天）
  final int graduatingInterval;

  /// 新卡直接点「简单」的毕业间隔（天）
  final int easyInterval;

  /// 初始熟练度因子
  final double startingEase;

  /// 熟练度下限（再难也不低于它，防止间隔塌成 0）
  final double minEase;

  /// 「简单」的间隔加成
  final double easyBonus;

  /// 「困难」的间隔系数（相对原间隔）
  final double hardFactor;

  /// 总间隔缩放（全局调紧 / 调松，1.0 = 原样）
  final double intervalModifier;

  /// 间隔上限（天）：概念卡寿命长，封到 100 年等于不封
  final int maxInterval;

  /// 答错后保留原间隔的比例。0 = Anki 默认（回学习步重来），
  /// 0.5 = 保留一半（对「大题要点卡」这种不该一次清零的更友好）
  final double lapseMultiplier;

  const Sm2Params({
    this.learningSteps = const [1, 10],
    this.relearningSteps = const [10],
    this.graduatingInterval = 1,
    this.easyInterval = 4,
    this.startingEase = 2.5,
    this.minEase = 1.3,
    this.easyBonus = 1.3,
    this.hardFactor = 1.2,
    this.intervalModifier = 1.0,
    this.maxInterval = 36500,
    this.lapseMultiplier = 0.0,
  });

  factory Sm2Params.fromJson(Map<String, dynamic> j) {
    List<int> steps(String k, List<int> dflt) {
      final raw = j[k];
      if (raw is! List) return dflt;
      final out = [
        for (final e in raw)
          if (e is num) e.toInt() else int.tryParse('$e') ?? 0,
      ].where((n) => n > 0).toList();
      return out.isEmpty ? dflt : out;
    }

    double num2(String k, double dflt) {
      final v = j[k];
      if (v is num) return v.toDouble();
      return double.tryParse('${v ?? ''}') ?? dflt;
    }

    int int2(String k, int dflt) {
      final v = j[k];
      if (v is num) return v.toInt();
      return int.tryParse('${v ?? ''}') ?? dflt;
    }

    return Sm2Params(
      learningSteps: steps('learning_steps', const [1, 10]),
      relearningSteps: steps('relearning_steps', const [10]),
      graduatingInterval: int2('graduating_interval', 1),
      easyInterval: int2('easy_interval', 4),
      startingEase: num2('starting_ease', 2.5),
      minEase: num2('min_ease', 1.3),
      easyBonus: num2('easy_bonus', 1.3),
      hardFactor: num2('hard_factor', 1.2),
      intervalModifier: num2('interval_modifier', 1.0),
      maxInterval: int2('max_interval', 36500),
      lapseMultiplier: num2('lapse_multiplier', 0.0),
    );
  }

  Map<String, dynamic> toJson() => {
        'learning_steps': learningSteps,
        'relearning_steps': relearningSteps,
        'graduating_interval': graduatingInterval,
        'easy_interval': easyInterval,
        'starting_ease': startingEase,
        'min_ease': minEase,
        'easy_bonus': easyBonus,
        'hard_factor': hardFactor,
        'interval_modifier': intervalModifier,
        'max_interval': maxInterval,
        'lapse_multiplier': lapseMultiplier,
      };
}

/// 一张知识点卡的调度状态。
///
/// 注意 [due] 是**带时刻**的（学习步要精确到分钟），
/// 这跟 FSRS 那边按日截断的 `CardState.due` 是刻意不同的。
class Sm2State {
  /// new / learn / review / relearn
  String phase;

  /// 当前学习步下标（learn / relearn 阶段有效）
  int step;

  /// 熟练度因子（ELO 味）
  double ease;

  /// 当前间隔（天）；learn 阶段为 0
  int interval;

  /// 下次到期时刻（学习步是分钟级，所以不做日截断）
  DateTime? due;

  int reps;
  int lapses;
  DateTime? lastReview;

  Sm2State({
    this.phase = 'new',
    this.step = 0,
    this.ease = 2.5,
    this.interval = 0,
    this.due,
    this.reps = 0,
    this.lapses = 0,
    this.lastReview,
  });

  bool get isNew => phase == 'new';

  /// 学过（进过任何一个非 new 阶段）—— 章节进度条 / 队列分支用它
  bool get isLearned => phase != 'new';

  /// 是不是「毕业卡」（进了 review，间隔按天走）
  bool get isReview => phase == 'review';

  Sm2State copy() => Sm2State(
        phase: phase,
        step: step,
        ease: ease,
        interval: interval,
        due: due,
        reps: reps,
        lapses: lapses,
        lastReview: lastReview,
      );

  Map<String, dynamic> toJson() => {
        'phase': phase,
        'step': step,
        'ease': double.parse(ease.toStringAsFixed(4)),
        'interval': interval,
        'due': due?.toIso8601String(),
        'reps': reps,
        'lapses': lapses,
        'last_review': lastReview?.toIso8601String(),
      };

  factory Sm2State.fromJson(Map<String, dynamic> j) => Sm2State(
        phase: (j['phase'] ?? 'new').toString(),
        step: (j['step'] as num?)?.toInt() ?? 0,
        ease: (j['ease'] as num?)?.toDouble() ?? 2.5,
        interval: (j['interval'] as num?)?.toInt() ?? 0,
        due: j['due'] != null ? DateTime.tryParse(j['due'].toString()) : null,
        reps: (j['reps'] as num?)?.toInt() ?? 0,
        lapses: (j['lapses'] as num?)?.toInt() ?? 0,
        lastReview: j['last_review'] != null
            ? DateTime.tryParse(j['last_review'].toString())
            : null,
      );
}

double _clamp(double x, double lo, double hi) => math.max(lo, math.min(hi, x));
int _clampi(int x, int lo, int hi) => math.max(lo, math.min(hi, x));

/// 到没到复习时间。
/// 跟 FSRS 那边「按日比较」不同：这里比的是**时刻**（学习步是分钟级）。
bool sm2IsDue(Sm2State st, [DateTime? now]) {
  if (st.isNew) return false;
  final d = st.due;
  if (d == null) return true;
  return !d.isAfter(now ?? DateTime.now());
}

/// 核心：喂进状态 + 四档评分，吐出更新后的状态（纯函数，不改入参）
Sm2State sm2Review(
  Sm2State card,
  Sm2Rating rating, [
  DateTime? now,
  Sm2Params params = const Sm2Params(),
]) {
  final t = now ?? DateTime.now();
  final next = card.copy();
  next.lastReview = t;
  next.reps += 1;

  switch (next.phase) {
    case 'new':
      next.ease = params.startingEase;
      _enterFromNew(next, rating, t, params);
      break;
    case 'learn':
    case 'relearn':
      final steps = next.phase == 'learn'
          ? params.learningSteps
          : params.relearningSteps;
      _stepThrough(next, rating, t, params, steps);
      break;
    case 'review':
      _reviewStep(next, rating, t, params);
      break;
    default:
      // 未知 phase（手改文件 / 老数据）当新卡处理，别把现场写坏
      next.phase = 'new';
      next.ease = params.startingEase;
      _enterFromNew(next, rating, t, params);
  }
  return next;
}

/// 新卡第一次评分
void _enterFromNew(
    Sm2State st, Sm2Rating r, DateTime t, Sm2Params p) {
  switch (r) {
    case Sm2Rating.easy:
      _graduate(st, p.easyInterval, t, p);
      break;
    case Sm2Rating.good:
      // 只有一个学习步 → 直接毕业；否则进第 2 步
      if (p.learningSteps.length <= 1) {
        _graduate(st, p.graduatingInterval, t, p);
      } else {
        st.phase = 'learn';
        st.step = 1;
        st.due = t.add(Duration(minutes: p.learningSteps[1]));
      }
      break;
    case Sm2Rating.hard:
      // 学习步里 hard = 停在当前步，按这一步的间隔再来一次
      // （不额外乘系数：学习步本身就是「很快再见」，再拖就没意义了）
      st.phase = 'learn';
      st.step = 0;
      st.due = t.add(Duration(minutes: p.learningSteps[0]));
      break;
    case Sm2Rating.again:
      st.phase = 'learn';
      st.step = 0;
      st.due = t.add(Duration(minutes: p.learningSteps[0]));
      break;
  }
}

/// 学习步推进（learn / relearn 共用）
void _stepThrough(Sm2State st, Sm2Rating r, DateTime t, Sm2Params p,
    List<int> steps) {
  final last = st.step.clamp(0, steps.length - 1);
  switch (r) {
    case Sm2Rating.again:
      st.step = 0;
      st.due = t.add(Duration(minutes: steps[0]));
      break;
    case Sm2Rating.hard:
      // 停在当前步，按这一步的间隔再来一次（10 分钟的步 → 还是 10 分钟）
      st.step = last;
      st.due = t.add(Duration(minutes: steps[last]));
      break;
    case Sm2Rating.good:
      final nxt = last + 1;
      if (nxt >= steps.length) {
        _graduate(st, st.interval > 0 ? st.interval : p.graduatingInterval,
            t, p);
      } else {
        st.step = nxt;
        st.due = t.add(Duration(minutes: steps[nxt]));
      }
      break;
    case Sm2Rating.easy:
      _graduate(st, p.easyInterval, t, p);
      break;
  }
}

/// 从学习/重学阶段毕业 → review
void _graduate(Sm2State st, int days, DateTime t, Sm2Params p) {
  st.phase = 'review';
  st.step = 0;
  st.interval = _clampi(
      (days * p.intervalModifier).round(), 1, p.maxInterval);
  st.due = t.add(Duration(days: st.interval));
}

/// 复习阶段的四档
void _reviewStep(Sm2State st, Sm2Rating r, DateTime t, Sm2Params p) {
  final ivl = st.interval <= 0 ? 1 : st.interval;

  switch (r) {
    case Sm2Rating.again:
      st.lapses += 1;
      st.ease = _clamp(st.ease - 0.20, p.minEase, 5.0);
      st.phase = 'relearn';
      st.step = 0;
      st.interval = _clampi((ivl * p.lapseMultiplier).round(), 1, p.maxInterval);
      st.due = t.add(Duration(minutes: p.relearningSteps[0]));
      break;
    case Sm2Rating.hard:
      st.ease = _clamp(st.ease - 0.15, p.minEase, 5.0);
      st.interval = _clampi(
        math.max(ivl + 1, (ivl * p.hardFactor * p.intervalModifier).round()),
        1,
        p.maxInterval,
      );
      st.due = t.add(Duration(days: st.interval));
      break;
    case Sm2Rating.good:
      st.interval = _clampi(
          (ivl * st.ease * p.intervalModifier).round(), 1, p.maxInterval);
      st.due = t.add(Duration(days: st.interval));
      break;
    case Sm2Rating.easy:
      st.ease = _clamp(st.ease + 0.15, p.minEase, 5.0);
      st.interval = _clampi(
          (ivl * st.ease * p.easyBonus * p.intervalModifier).round(),
          1,
          p.maxInterval);
      st.due = t.add(Duration(days: st.interval));
      break;
  }
}

/// 把「距现在多久」写成按钮上的小字：「10 分」「3 天」「2 个月」
String sm2FormatGap(Duration d) {
  final m = d.inMinutes;
  if (m < 1) return '1 分内';
  if (m < 60) return '$m 分';
  final h = d.inHours;
  if (h < 24) return '$h 小时';
  final days = d.inDays;
  if (days < 30) return '$days 天';
  if (days < 365) {
    final mo = days / 30.0;
    return '${mo < 10 ? mo.toStringAsFixed(1) : mo.round()} 个月';
  }
  final y = days / 365.0;
  return '${y < 10 ? y.toStringAsFixed(1) : y.round()} 年';
}

/// 四档各自的「下次间隔」预览 —— 模板把它画在按钮上（Anki 那个小字）。
/// 纯函数：拿副本跑一遍 [sm2Review]，不落盘、不改真状态。
Map<String, String> sm2Preview(
  Sm2State card, [
  DateTime? now,
  Sm2Params params = const Sm2Params(),
]) {
  final t = now ?? DateTime.now();
  final out = <String, String>{};
  for (final r in Sm2Rating.values) {
    final n = sm2Review(card, r, t, params);
    final due = n.due;
    out[r.key] =
        due == null ? '-' : sm2FormatGap(due.difference(t));
  }
  return out;
}

/// 队列：到期 → 新卡（顺序照抄壳里 FSRS 那套的口径）
List<String> sm2Queue(
  List<String> allIds,
  Sm2State Function(String) stateOf,
  bool Function(String) isKnown, [
  DateTime? now,
]) {
  final t = now ?? DateTime.now();
  final due = <String>[];
  final fresh = <String>[];
  for (final id in allIds) {
    if (isKnown(id)) continue; // 标熟 = 永久出队（KV 与引擎无关，两套共用）
    final st = stateOf(id);
    if (st.isNew) {
      fresh.add(id);
    } else if (sm2IsDue(st, t)) {
      due.add(id);
    }
  }
  due.sort((a, b) {
    final da = stateOf(a).due;
    final db = stateOf(b).due;
    if (da == null && db == null) return 0;
    if (da == null) return -1;
    if (db == null) return 1;
    return da.compareTo(db);
  });
  return [...due, ...fresh];
}
