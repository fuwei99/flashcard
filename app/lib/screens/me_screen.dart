/// 我的：设置 + 数据
library;

import 'package:flutter/material.dart';

import '../services/card_store.dart';
import '../services/data_dir.dart';
import '../services/study_settings.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';

class MeScreen extends StatefulWidget {
  final CardStore store;
  final StudySettings settings;

  /// 重新读公共目录里的模板（改完 CSS 点一下即可生效）
  final Future<void> Function()? onReloadTemplates;

  const MeScreen({
    super.key,
    required this.store,
    required this.settings,
    this.onReloadTemplates,
  });

  @override
  State<MeScreen> createState() => MeScreenState();
}

class MeScreenState extends State<MeScreen> {
  Future<void> refresh() async {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        title: const Text('我的',
            style: TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 22)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0x0BFFFFFF),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x14FFFFFF)),
            ),
            child: Row(
              children: [
                const Icon(Icons.local_fire_department,
                    color: Color(0xFFFF8A3D), size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('连续 ${s.currentStreak} 天打卡',
                          style: const TextStyle(
                              color: Color(0xFFF0F4F5),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(
                          '今日 ${s.todayTotal} 张 · 最长 ${s.bestStreak} 天 · 累计 ${s.totalStudyDays} 天',
                          style: const TextStyle(
                              color: Color(0xFF54666C), fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _sectionLabel('设置'),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.insights,
            label: '学习统计',
            value: '连续 ${s.currentStreak} 天',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StatsScreen(settings: widget.settings),
                ),
              );
              refresh();
            },
          ),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.notifications_none,
            label: '背诵提醒',
            value: s.reminderEnabled ? '每天 ${s.reminderTimeLabel}' : '未开启',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(settings: widget.settings),
                ),
              );
              refresh();
            },
          ),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.tune,
            label: '每日背诵量',
            value: '单词 ${s.wordDailyLimit} · 卡牌 ${s.cardDailyLimit}',
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(settings: widget.settings),
                ),
              );
              refresh();
            },
          ),
          const SizedBox(height: 20),
          _sectionLabel('模板'),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.dashboard_customize_outlined,
            label: '重载模板',
            value: '改完 CSS 点这里',
            onTap: () async {
              await widget.onReloadTemplates?.call();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('模板已重新读取'),
                backgroundColor: Color(0xFF1B2629),
                behavior: SnackBarBehavior.floating,
              ));
            },
          ),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.folder_open,
            label: '模板目录',
            value: '公共目录',
            onTap: () {
              showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF1B2629),
                  title: const Text('模板目录',
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                  content: SelectableText(
                      '${DataDir.publicPath}/templates',
                      style: const TextStyle(
                          color: Color(0xFFB7C4C8), fontSize: 12)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('好',
                          style: TextStyle(color: Color(0xFF00C08B))),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          _sectionLabel('关于'),
          const SizedBox(height: 10),
          _entry(
            icon: Icons.info_outline,
            label: 'flashcard',
            value: 'v1.0.0',
            onTap: () {},
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String t) => Text(t,
      style: const TextStyle(
          color: Color(0xFF8C9DA2),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: .5));

  Widget _entry({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF00C08B), size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: Color(0xFFF0F4F5), fontSize: 15)),
            ),
            Text(value,
                style: const TextStyle(
                    color: Color(0xFF54666C), fontSize: 13)),
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right, color: Color(0xFF54666C)),
          ],
        ),
      ),
    );
  }
}
