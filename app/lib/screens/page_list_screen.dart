/// 页面列表：每一页 = 一张卡。顶部可选「顺序背诵 / 乱序背诵」
///
/// ## 加入记忆规划（2026-11-14）
/// 墨墨那套是「牌组里自己勾要背的」，以前这 App 只有「整章顺序 / 乱序」
/// 两个粗暴入口，书里所有卡自动进队列。现在书级开关 `enroll_required`
/// 打开后：
///   * 每行右侧一个「已加入 / ＋ 加入」徽标，点一下直接切；
///   * 「选择」进多选模式，可全选 / 反选，底部浮条批量加入 / 移出；
///   * 勾掉只是「不进队列」，SM-2 的 ease / 间隔 / 复习历史一律保留，
///     随时能加回（跟「标熟」是同一类人为判定，不污染调度数据）。
/// 队列判定统一在 [CardStore.inPlan]，这里只管 UI —— 所以顺序 / 乱序 /
/// 首页「开始背诵」三条入口自动一致，不会显示 56 张实际背 10 张。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/deck.dart';
import '../services/card_store.dart';
import '../services/study_plan.dart';
import '../services/study_settings.dart';
import 'card_preview_screen.dart';
import 'review_screen.dart';

const _kGreen = Color(0xFF00C08B);
const _kBg = Color(0xFF141D1F);
const _kTile = Color(0x08FFFFFF);
const _kTileBorder = Color(0x10FFFFFF);
const _kInk = Color(0xFFF0F4F5);
const _kMuted = Color(0xFF8C9DA2);
const _kDim = Color(0xFF54666C);

/// 某一章的页面列表（带自己的 AppBar）
class PageListScreen extends StatelessWidget {
  final String title;
  final List<FlashCard> cards;
  final Book book;
  final CardTemplate? template;
  final CardStore store;
  final StudySettings settings;
  final Passage? passage;

  const PageListScreen({
    super.key,
    required this.title,
    required this.cards,
    required this.book,
    required this.template,
    required this.store,
    required this.settings,
    this.passage,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        elevation: 0,
        iconTheme: const IconThemeData(color: _kMuted),
        title: Text(title,
            style: const TextStyle(
                color: _kInk, fontWeight: FontWeight.w700, fontSize: 18)),
      ),
      body: PageListBody(
        title: title,
        cards: cards,
        book: book,
        template: template,
        store: store,
        settings: settings,
        passage: passage,
      ),
    );
  }
}

/// 可复用的页面列表 body：无章节时直接嵌进 BookDetailScreen
class PageListBody extends StatefulWidget {
  final String title;
  final List<FlashCard> cards;
  final Book book;
  final CardTemplate? template;
  final CardStore store;
  final StudySettings settings;
  final Passage? passage;

  const PageListBody({
    super.key,
    required this.title,
    required this.cards,
    required this.book,
    required this.template,
    required this.store,
    required this.settings,
    this.passage,
  });

  @override
  State<PageListBody> createState() => _PageListBodyState();
}

class _PageListBodyState extends State<PageListBody> {
  /// 多选模式
  bool _picking = false;

  /// 本次勾选的卡 id（只在 _picking 时有意义）
  final Set<String> _picked = <String>{};

  bool get _enroll => widget.book.enrollRequired;
  CardStore get _store => widget.store;

  int get _enrolledCount =>
      widget.cards.where((c) => _store.inPlan(c.id)).length;

  // ------------------------------------------------------------ 规划操作

  void _setOne(String id, bool v) {
    _store.setEnrolled(id, v);
    if (mounted) setState(() {});
  }

  void _setAll(bool v) {
    _store.setEnrolledAll([for (final c in widget.cards) c.id], v);
    if (mounted) setState(() {});
    _toast(v ? '全部加入记忆规划' : '已全部移出记忆规划');
  }

  void _applyPicked(bool v) {
    if (_picked.isEmpty) {
      _toast('先勾几张卡啊，空着手加个屁');
      return;
    }
    _store.setEnrolledAll(_picked.toList(), v);
    final n = _picked.length;
    if (mounted) {
      setState(() {
        _picked.clear();
        _picking = false;
      });
    }
    _toast(v ? '已加入记忆规划 $n 张' : '已移出记忆规划 $n 张');
  }

  void _togglePick(String id) {
    setState(() {
      if (!_picked.remove(id)) _picked.add(id);
    });
  }

  void _selectAll() {
    setState(() {
      _picked
        ..clear()
        ..addAll([for (final c in widget.cards) c.id]);
    });
  }

  void _invertPick() {
    setState(() {
      final all = {for (final c in widget.cards) c.id};
      final next = all.difference(_picked);
      _picked
        ..clear()
        ..addAll(next);
    });
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(s),
      backgroundColor: const Color(0xFF1B2629),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 1400),
    ));
  }

  // ------------------------------------------------------------ 开背

  /// 开一轮背诵。
  ///
  /// 有没背过的 → 直接背那些。
  /// 全背完了 → 弹窗问「还要再背一次吗」；确认后**整章重背**：
  ///   不清空任何历史，只是把每张卡再过一遍 —— 每张毕业时照常走
  ///   `review()`，遗忘曲线顺延、`markDone()` 计入今日已复习。
  void _startReview(BuildContext context, bool shuffle) {
    final template = widget.template;
    if (template == null) return;

    final cards = widget.cards;
    // 移出规划的卡一律不进这一轮（顺序 / 乱序两个入口都对齐）
    final inPlan = cards.where((c) => _store.inPlan(c.id)).toList();
    if (inPlan.isEmpty) {
      _toast('一张都没加入记忆规划，先勾几张再背');
      return;
    }

    final fresh = inPlan
        .where((c) => !_store.isLearned(c.id) && !_store.isKnown(c.id))
        .toList();
    if (fresh.isNotEmpty) {
      _pushReview(context, inPlan, fresh, shuffle);
      return;
    }

    // 已背完。标熟的仍然排除 —— 那是「永久出队」，重背也不该把它拉回来
    final redo = inPlan.where((c) => !_store.isKnown(c.id)).toList();
    if (redo.isEmpty) {
      _toast('这章的卡都标熟了，没有可背的');
      return;
    }

    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B2629),
        title: const Text('你已经背完了',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text(
            '还要再背一次吗？\n\n再背一次不会清空进度，会把本章当作一次复习：'
            '每张卡的遗忘曲线照常更新，并计入今日已复习。',
            style:
                TextStyle(color: Color(0xFFB7C4C8), fontSize: 13, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('那算了', style: TextStyle(color: _kMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('再背一次', style: TextStyle(color: _kGreen)),
          ),
        ],
      ),
    ).then((again) {
      if (again != true || !context.mounted) return;
      _pushReview(context, inPlan, redo, shuffle);
    });
  }

  void _pushReview(BuildContext context, List<FlashCard> inPlan,
      List<FlashCard> list, bool shuffle) {
    final template = widget.template!;
    if (shuffle) list.shuffle(math.Random());

    // srs_basic（知识点卡）由 workflow.js 自己拉队列 —— 壳只需要把这一章
    // **全部在规划内的卡**给它当候选池（不能只给未学的：到期的是已学卡，
    // 拿不到它们 workflow 就卡死在"无卡可挂"）。
    final isCard = template.engine == 'srs_basic';
    final unitCards = isCard ? inPlan : list;
    final book = widget.book;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          title: widget.title,
          units: [
            StudyPlanner.singleUnit(
              passage: isCard ? null : widget.passage,
              cards: unitCards,
              passageCards: inPlan,
              passageIndex: book.passageIndex,
              blankLemmas: isCard
                  ? const <String>{}
                  : StudyPlanner.blankLemmasFor(list, widget.passage),
              readFirst: !isCard,
            ),
          ],
          template: template,
          fieldsOrder: book.fieldsOrder,
          // 干扰池 = 整本书（不再只限本章）：一个词的章节也出得了题。
          // 惰性求值：`book.allCards` 会展开每一章的 cards，直接传值等于
          // 「打开一章就把整本书读进内存」，把 Chapter 的懒加载拆掉。
          distractorPool: () => book.allCards,
          bookId: book.bookId,
          store: _store,
          settings: widget.settings,
          isCard: isCard,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            _startBar(context),
            if (_enroll) _planBar(),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.fromLTRB(16, 4, 16, _picking ? 92 : 24),
                itemCount: widget.cards.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _pageTile(context, i),
              ),
            ),
          ],
        ),
        if (_picking && _enroll) _pickBar(),
      ],
    );
  }

  Widget _startBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _startBtn(
              icon: Icons.format_list_numbered,
              label: '顺序背诵',
              onTap: () => _startReview(context, false),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _startBtn(
              icon: Icons.shuffle,
              label: '乱序背诵',
              onTap: () => _startReview(context, true),
            ),
          ),
        ],
      ),
    );
  }

  Widget _startBtn(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: const Color(0x1F00C08B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0x3300C08B)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: _kGreen, size: 18),
            const SizedBox(width: 7),
            Text(label,
                style: const TextStyle(
                    color: _kGreen, fontSize: 14, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  /// 「加入记忆规划」条：常态显示已加入数 + 选择按钮；选择态显示全选/反选/取消
  Widget _planBar() {
    final n = _enrolledCount;
    final total = widget.cards.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kTileBorder),
        ),
        child: Row(
          children: [
            const Icon(Icons.playlist_add_check, color: _kGreen, size: 17),
            const SizedBox(width: 7),
            Text('已加入 $n / $total',
                style: const TextStyle(
                    color: _kInk, fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (_picking) ...[
              _miniBtn('全选', _selectAll),
              const SizedBox(width: 6),
              _miniBtn('反选', _invertPick),
              const SizedBox(width: 6),
              _miniBtn('取消', () => setState(() {
                    _picking = false;
                    _picked.clear();
                  })),
            ] else ...[
              _miniBtn('全选', () => _setAll(true)),
              const SizedBox(width: 6),
              _miniBtn('清空', () => _setAll(false)),
              const SizedBox(width: 6),
              _miniBtn('选择', () => setState(() {
                    _picking = true;
                    _picked.clear();
                  }), filled: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _miniBtn(String label, VoidCallback onTap, {bool filled = false}) {
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: filled ? const Color(0x2600C08B) : const Color(0x0AFFFFFF),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
              color: filled ? const Color(0x6600C08B) : _kTileBorder),
        ),
        child: Text(label,
            style: TextStyle(
                color: filled ? _kGreen : _kMuted,
                fontSize: 11.5,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  /// 底部批量操作浮条
  Widget _pickBar() {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF1B2629),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x3300C08B)),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 6))
            ],
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text('已选 ${_picked.length}',
                    style: const TextStyle(
                        color: _kInk, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              Expanded(
                flex: 2,
                child: _actionBtn('移出规划', Icons.remove_circle_outline,
                    () => _applyPicked(false), filled: false),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: _actionBtn('加入记忆规划', Icons.playlist_add_check,
                    () => _applyPicked(true), filled: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionBtn(String label, IconData icon, VoidCallback onTap,
      {required bool filled}) {
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: onTap,
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: filled ? _kGreen : const Color(0x0AFFFFFF),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
              color: filled ? _kGreen : const Color(0x22FFFFFF)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: filled ? _kBg : _kMuted),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: filled ? _kBg : _kMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  /// 词表一行：点开 -> 单卡预览（词义页）
  Widget _pageTile(BuildContext context, int i) {
    final card = widget.cards[i];
    final isCard = widget.template?.engine == 'srs_basic';
    final learned =
        isCard ? _store.isLearnedSm2(card.id) : _store.isLearned(card.id);
    final phonetic = isCard
        ? card.displaySubtitle
        : (card.fields['phonetic_us'] ?? card.fields['phonetic_uk'] ?? '')
            .toString();
    final pos = isCard ? '' : card.posLabel;
    final meaning = isCard ? card.displaySummary : card.meaningFull;
    final title = isCard ? card.displayTitle : card.word;
    final tpl = widget.template;
    final inPlan = _store.inPlan(card.id);
    final picked = _picked.contains(card.id);

    final onTap = () {
      if (_picking) {
        _togglePick(card.id);
        return;
      }
      if (tpl == null) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CardPreviewScreen(
            card: card,
            template: tpl,
            fieldsOrder: widget.book.fieldsOrder,
            store: _store,
            settings: widget.settings,
          ),
        ),
      ).then((_) {
        if (mounted) setState(() {});
      });
    };

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: _enroll && !_picking
          ? () => setState(() {
                _picking = true;
                _picked.clear();
                _picked.add(card.id);
              })
          : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: picked ? const Color(0x1400C08B) : _kTile,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: picked ? const Color(0x5500C08B) : _kTileBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 选择态：勾选框；常态：序号
            SizedBox(
              width: 26,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _picking
                    ? Icon(
                        picked
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: picked ? _kGreen : _kDim,
                        size: 19,
                      )
                    : Text('${i + 1}',
                        style: const TextStyle(
                            color: _kDim,
                            fontSize: 12,
                            fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ),
            Expanded(
              child: Opacity(
                opacity: (_enroll && !inPlan && !_picking) ? 0.45 : 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Flexible(
                          child: Text(title,
                              style: const TextStyle(
                                  color: _kInk,
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (pos.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0x1F00C08B),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(pos,
                                style: const TextStyle(
                                    color: _kGreen, fontSize: 10.5)),
                          ),
                        ],
                      ],
                    ),
                    if (phonetic.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(phonetic,
                          style:
                              const TextStyle(color: _kDim, fontSize: 12)),
                    ],
                    if (meaning.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(meaning,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: _kMuted, fontSize: 12.5, height: 1.35)),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 规划开关（选择态隐藏，整行就是勾选区）
            if (_enroll && !_picking)
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _setOne(card.id, !inPlan),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: inPlan
                        ? const Color(0x1F00C08B)
                        : const Color(0x0AFFFFFF),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: inPlan
                            ? const Color(0x5500C08B)
                            : _kTileBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                          inPlan
                              ? Icons.check_circle
                              : Icons.add_circle_outline,
                          size: 13,
                          color: inPlan ? _kGreen : _kDim),
                      const SizedBox(width: 4),
                      Text(inPlan ? '已加入' : '加入',
                          style: TextStyle(
                              color: inPlan ? _kGreen : _kDim,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              )
            else if (!_picking) ...[
              // 老书：保留原来的三种状态徽标
              if (_store.isKnown(card.id))
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0x1F00C08B),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text('熟',
                      style: TextStyle(
                          color: _kGreen,
                          fontSize: 11,
                          fontWeight: FontWeight.w700)),
                )
              else if (learned)
                const Icon(Icons.check_circle, color: _kGreen, size: 18)
              else
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: const Color(0x33FFFFFF), width: 1.5),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
