/// 学习统计：连续打卡 + 累计 + 近 7 / 30 天柱状图
library;

import 'package:flutter/material.dart';

import '../services/study_settings.dart';

class StatsScreen extends StatefulWidget {
  final StudySettings settings;
  const StatsScreen({super.key, required this.settings});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  int _range = 7;

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8C9DA2)),
        title: const Text('学习统计',
            style: TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _heroCard(s),
          const SizedBox(height: 16),
          _chartCard(s),
          const SizedBox(height: 16),
          _totalsCard(s),
          const SizedBox(height: 24),
          _dangerCard(s),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: child,
      );

  Widget _heroCard(StudySettings s) {
    return _card(
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: const Color(0x1FFF8A3D),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.local_fire_department,
                color: Color(0xFFFF8A3D), size: 30),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text('${s.currentStreak}',
                        style: const TextStyle(
                            color: Color(0xFFF0F4F5),
                            fontSize: 30,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(width: 5),
                    const Text('天连续打卡',
                        style: TextStyle(
                            color: Color(0xFF8C9DA2), fontSize: 14)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                    '最长 ${s.bestStreak} 天 · 累计学习 ${s.totalStudyDays} 天'
                    '${s.checkedInToday ? ' · 今日已打卡' : ''}',
                    style: const TextStyle(
                        color: Color(0xFF54666C), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chartCard(StudySettings s) {
    final days = s.recentDays(_range);
    var maxV = 1;
    for (final d in days) {
      final v = (d['word'] as int) + (d['card'] as int);
      if (v > maxV) maxV = v;
    }
    final barW = _range > 10 ? 2.0 : 4.0;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('背诵量',
                  style: TextStyle(
                      color: Color(0xFFF0F4F5),
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              _rangeChip('近 7 天', 7),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _rangeChip('近 7 天', 7),
              const SizedBox(width: 8),
              _rangeChip('近 30 天', 30),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 110,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: days.map((d) {
                final total = (d['word'] as int) + (d['card'] as int);
                final h = total == 0 ? 3.0 : (total / maxV) * 78.0;
                return Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (_range <= 7 && total > 0)
                        Text('$total',
                            style: const TextStyle(
                                color: Color(0xFF8C9DA2), fontSize: 10)),
                      const SizedBox(height: 3),
                      Container(
                        height: h,
                        margin: EdgeInsets.symmetric(horizontal: barW),
                        decoration: BoxDecoration(
                          color: total == 0
                              ? const Color(0x14FFFFFF)
                              : const Color(0xFF00C08B),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (_range <= 7)
                        Text(d['label'] as String,
                            style: const TextStyle(
                                color: Color(0xFF54666C), fontSize: 10))
                      else
                        const SizedBox(height: 12),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rangeChip(String label, int v) {
    final sel = _range == v;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => setState(() => _range = v),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: sel ? const Color(0x1F00C08B) : const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: sel ? const Color(0xFF00C08B) : const Color(0x14FFFFFF)),
        ),
        child: Text(label,
            style: TextStyle(
                color:
                    sel ? const Color(0xFF00C08B) : const Color(0xFF8C9DA2),
                fontSize: 12,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _totalsCard(StudySettings s) {
    return _card(
      child: Column(
        children: [
          _row('累计已背', '${s.totalWordDone + s.totalCardDone} 张'),
          const Divider(height: 18, color: Color(0x0FFFFFFF)),
          _row('其中 · 单词', '${s.totalWordDone} 张'),
          const Divider(height: 18, color: Color(0x0FFFFFFF)),
          _row('其中 · 卡牌', '${s.totalCardDone} 张'),
          const Divider(height: 18, color: Color(0x0FFFFFFF)),
          _row('累计学习天数', '${s.totalStudyDays} 天'),
          const Divider(height: 18, color: Color(0x0FFFFFFF)),
          _row('最长连续打卡', '${s.bestStreak} 天'),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k,
              style: const TextStyle(color: Color(0xFF8C9DA2), fontSize: 14)),
          Text(v,
              style: const TextStyle(
                  color: Color(0xFFF0F4F5),
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ],
      );

  Widget _dangerCard(StudySettings s) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFFF5C5C),
          side: const BorderSide(color: Color(0x33FF5C5C)),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1B2629),
              title: const Text('重置学习统计？',
                  style: TextStyle(color: Color(0xFFF0F4F5))),
              content: const Text('连续打卡、累计已背、历史记录都会清零，卡片进度不受影响。',
                  style: TextStyle(color: Color(0xFF8C9DA2))),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消')),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('重置',
                        style: TextStyle(color: Color(0xFFFF5C5C)))),
              ],
            ),
          );
          if (ok != true) return;
          await s.resetStats();
          if (mounted) setState(() {});
        },
        child: const Text('重置学习统计'),
      ),
    );
  }
}
