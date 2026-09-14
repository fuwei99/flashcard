/// 会话状态机（轮内状态）
/// ================================================================
/// 只管「这一轮」的事：队列、阶段、轮次、通过与否。
/// 绝不碰持久层 —— 卡片的长期调度（FSRS）由屏幕在「毕业」时写。
///
/// 流程：
///   learn  轮（第一遍，read 模式）
///     记得        -> 直接毕业
///     模糊 / 忘记  -> 进重测池
///   重测轮（循环，直到池内每张卡 choice + cloze 都过）
///     阶段 A：池里 choice 还没过的卡，一次考完
///     阶段 B：池里 cloze  还没过的卡，一次考完
///     还有卡没过 -> round++，回阶段 A
///     全过       -> 毕业
///   两阶段分开的原因：不让同一张卡的 choice / cloze 挨着考 ——
///   刚做完「英→中选义」，紧接着「例句挖空选词」，上一题选项里刚见过那个词，
///   等于送答案。先让所有卡过完 choice，再让所有卡过 cloze。
///
///   done
///
/// 重要变更（2026-09-15，BUG-010 配套）：
///   重测轮改为「逐卡即时毕业」—— 一张卡 choice + cloze 双过就立刻移入
///   graduated 并滚出重测池，由屏幕层立即落盘。绝不让已过关的卡陪着
///   硬骨头坐牢（原实现是整池全过才批量毕业，中途强杀 = 已掌握卡全部丢进度）。
library;

import 'deck.dart';
import '../services/scheduler.dart';

enum SessionPhase { learn, choice, cloze, done }

enum StudyMode {
  read('read'),
  choice('choice'),
  cloze('cloze'),
  spell('spell');

  const StudyMode(this.key);
  final String key;

  static StudyMode fromKey(String k) => StudyMode.values
      .firstWhere((m) => m.key == k, orElse: () => StudyMode.read);
}

/// 队列里的一个步骤：某张卡 + 某个考法 + 第几轮
class StudyStep {
  final FlashCard card;
  final StudyMode mode;
  final int round;
  const StudyStep(this.card, this.mode, this.round);
}

class StudySession {
  final List<StudyStep> _queue = [];
  final List<FlashCard> _retestPool = [];

  /// 已毕业的卡 id（本轮内）
  final Set<String> graduated = {};

  /// 重测阶段里每张卡的考法通过记录：cardId -> {mode keys}
  final Map<String, Set<String>> _passedModes = {};

  /// 本轮「挣扎程度」：0 = 一次过，1 = 费了点劲，2 = 硬骨头。
  /// 毕业时映射成 FSRS 评分 —— 别再无脑写 good 了。
  final Map<String, int> _effort = {};

  /// 这张卡答错的次数
  final Map<String, int> _wrongCount = {};

  SessionPhase phase = SessionPhase.learn;
  int round = 1;
  int _roundTotal = 0;

  /// 重测阶段一张卡必须全过的考法
  static const Set<String> retestModes = {'choice', 'cloze'};

  StudySession(List<FlashCard> cards) {
    _queue.addAll(cards.map((c) => StudyStep(c, StudyMode.read, 1)));
    _roundTotal = _queue.length;
    if (cards.isEmpty) phase = SessionPhase.done;
  }

  StudyStep? get current => _queue.isEmpty ? null : _queue.first;
  bool get finished => phase == SessionPhase.done;
  int get left => _queue.length;
  int get roundTotal => _roundTotal;
  int get doneInRound => _roundTotal - _queue.length;
  int get retestPoolSize => _retestPool.length;

  /// 抬高一张卡的挣扎程度（只增不减）
  void _bump(String cardId, int e) {
    if (e > (_effort[cardId] ?? 0)) _effort[cardId] = e;
  }

  /// 这张卡毕业时该写什么 FSRS 评分
  ///   0 一次过   -> good   轻松，稳定性正常涨
  ///   1 费了点劲 -> hard   增长量打 2.3 折
  ///   2 硬骨头   -> again  稳定性下调，明天必须再见
  Rating ratingFor(String cardId) {
    switch (_effort[cardId] ?? 0) {
      case 0:
        return Rating.good;
      case 1:
        return Rating.hard;
      default:
        return Rating.again;
    }
  }

  bool _allPassed(String id) =>
      (_passedModes[id] ?? const <String>{}).containsAll(retestModes);

  /// 学习轮：提交一次自评
  void submitLearn(Rating r) {
    if (_queue.isEmpty) return;
    final step = _queue.removeAt(0);
    if (r == Rating.good) {
      graduated.add(step.card.id);
    } else {
      _retestPool.add(step.card);
      _bump(step.card.id, r == Rating.again ? 2 : 1);
    }
    _advance();
  }

  /// 重测轮：提交一个考法的对错。
  /// 答错 -> 不记通过，后面轮次继续考，**直到两个考法都过**。
  /// 答对且该卡 choice + cloze 双过 -> **立即毕业**并滚出重测池，
  /// 屏幕层随即落盘 —— 不再等整池清空（防强杀丢进度）。
  void submitRetest(StudyMode mode, bool ok) {
    if (_queue.isEmpty) return;
    final step = _queue.removeAt(0);
    if (ok) {
      (_passedModes[step.card.id] ??= <String>{}).add(mode.key);
      if (_allPassed(step.card.id)) {
        _retestPool.remove(step.card);
        graduated.add(step.card.id);
      }
    } else {
      final n = (_wrongCount[step.card.id] ?? 0) + 1;
      _wrongCount[step.card.id] = n;
      _bump(step.card.id, n >= 2 ? 2 : 1);
    }
    _advance();
  }

  void _advance() {
    if (_queue.isNotEmpty) return;

    if (phase == SessionPhase.learn) {
      if (_retestPool.isEmpty) {
        phase = SessionPhase.done;
        return;
      }
      round = 2;
      _startChoice();
      return;
    }

    if (phase == SessionPhase.choice) {
      _startCloze();
      return;
    }

    if (phase == SessionPhase.cloze) {
      // 池里还有没双过的卡吗？没有就是全毕业。
      if (_retestPool.isEmpty) {
        phase = SessionPhase.done;
        return;
      }
      round++;
      _startChoice();
    }
  }

  /// 阶段 A：池里 choice 还没过的卡，一次考完
  void _startChoice() {
    phase = SessionPhase.choice;
    _queue.clear();
    for (final c in _retestPool) {
      if (graduated.contains(c.id)) continue;
      if ((_passedModes[c.id] ?? const <String>{})
          .contains(StudyMode.choice.key)) {
        continue;
      }
      _queue.add(StudyStep(c, StudyMode.choice, round));
    }
    _roundTotal = _queue.length;
    if (_queue.isEmpty) _advance();
  }

  /// 阶段 B：池里 cloze 还没过的卡，一次考完
  void _startCloze() {
    phase = SessionPhase.cloze;
    _queue.clear();
    for (final c in _retestPool) {
      if (graduated.contains(c.id)) continue;
      if ((_passedModes[c.id] ?? const <String>{})
          .contains(StudyMode.cloze.key)) {
        continue;
      }
      _queue.add(StudyStep(c, StudyMode.cloze, round));
    }
    _roundTotal = _queue.length;
    if (_queue.isEmpty) _advance();
  }
}
