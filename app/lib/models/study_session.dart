/// 会话状态机（轮内状态）
/// ================================================================
/// 只管「这一轮」的事：队列、阶段、轮次、通过与否。
/// 绝不碰持久层 —— 卡片的长期调度（FSRS）由屏幕在「毕业」时写。
///
/// 流程：
///   learn 轮（第一遍）
///     记得        -> 直接毕业
///     模糊 / 忘记  -> 进重测池
///   retest 轮（重测池）
///     每张考两个 mode：choice（英→中选义）+ cloze（例句挖空选英词）
///     两个都过 -> 毕业
///     任一没过 -> 留池，下一轮重来
///   done：池空
library;

import 'deck.dart';
import '../services/scheduler.dart';

enum SessionPhase { learn, retest, done }

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

  /// 每张卡本轮的考法通过记录：cardId -> {mode keys}
  final Map<String, Set<String>> _passedModes = {};

  SessionPhase phase = SessionPhase.learn;
  int round = 1;
  int _roundTotal = 0;

  /// 重测轮一张卡必须全过的考法
  static const Set<String> retestModes = {'choice', 'cloze'};

  StudySession(List<FlashCard> cards) {
    _queue.addAll(cards.map((c) => StudyStep(c, StudyMode.read, 1)));
    _roundTotal = _queue.length;
  }

  StudyStep? get current => _queue.isEmpty ? null : _queue.first;
  bool get finished => _queue.isEmpty && _retestPool.isEmpty;
  int get left => _queue.length;
  int get roundTotal => _roundTotal;
  int get doneInRound => _roundTotal - _queue.length;
  int get retestPoolSize => _retestPool.length;

  /// 学习轮：提交一次自评
  void submitLearn(Rating r) {
    if (_queue.isEmpty) return;
    final step = _queue.removeAt(0);
    if (r == Rating.good) {
      graduated.add(step.card.id);
    } else {
      _retestPool.add(step.card);
    }
    _advance();
  }

  /// 重测轮：提交一个考法的对错
  void submitRetest(StudyMode mode, bool ok) {
    if (_queue.isEmpty) return;
    final step = _queue.removeAt(0);
    if (ok) {
      (_passedModes[step.card.id] ??= {}).add(mode.key);
    }

    // 这张卡本轮还有后续步骤吗？
    final more = _queue.any((s) => s.card.id == step.card.id);
    if (!more) {
      final got = _passedModes[step.card.id] ?? const <String>{};
      if (got.containsAll(retestModes)) {
        graduated.add(step.card.id);
      }
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
      _startRetest();
      return;
    }

    if (phase == SessionPhase.retest) {
      _retestPool.removeWhere((c) => graduated.contains(c.id));
      if (_retestPool.isEmpty) {
        phase = SessionPhase.done;
        return;
      }
      round++;
      _startRetest();
    }
  }

  void _startRetest() {
    phase = SessionPhase.retest;
    _passedModes.clear();
    _queue.clear();
    for (final c in _retestPool) {
      _queue.add(StudyStep(c, StudyMode.choice, round));
      _queue.add(StudyStep(c, StudyMode.cloze, round));
    }
    _roundTotal = _queue.length;
  }
}
