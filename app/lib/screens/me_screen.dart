/// 我的：设置 + 数据
library;

import 'package:flutter/material.dart';

import '../services/card_store.dart';
import '../services/study_settings.dart';
import 'settings_screen.dart';

class MeScreen extends StatefulWidget {
  final CardStore store;
  final StudySettings settings;

  const MeScreen({super.key, required this.store, required this.settings});

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
                    color: Color(0xFF00C08B), size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('今日已背',
                          style: TextStyle(
                              color: Color(0xFF54666C), fontSize: 12)),
                      const SizedBox(height: 3),
                      Text('单词 ${s.todayWordDone}/${s.wordDailyLimit} · 卡牌 ${s.todayCardDone}/${s.cardDailyLimit}',
                          style: const TextStyle(
                              color: Color(0xFFF0F4F5),
                              fontSize: 18,
                              fontWeight: FontWeight.w700)),
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
