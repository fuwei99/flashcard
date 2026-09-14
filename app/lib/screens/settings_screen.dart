/// 设置界面：每日背诵量
library;

import 'package:flutter/material.dart';

import '../services/study_settings.dart';

class SettingsScreen extends StatefulWidget {
  final StudySettings settings;

  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late int _limit;

  @override
  void initState() {
    super.initState();
    _limit = widget.settings.dailyLimit;
  }

  Future<void> _save() async {
    await widget.settings.setDailyLimit(_limit);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141D1F),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF8C9DA2)),
        title: const Text('设置',
            style: TextStyle(
                color: Color(0xFFF0F4F5),
                fontWeight: FontWeight.w700,
                fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionLabel('每日背诵量'),
          const SizedBox(height: 10),
          _limitCard(),
          const SizedBox(height: 24),
          _sectionLabel('卡片类型'),
          const SizedBox(height: 10),
          _modeCard(),
          const SizedBox(height: 24),
          _sectionLabel('今日'),
          const SizedBox(height: 10),
          _todayCard(),
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

  Widget _limitCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('每天背多少个卡片',
                  style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 15)),
              Text('$_limit',
                  style: const TextStyle(
                      color: Color(0xFF00C08B),
                      fontSize: 30,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 6),
          Slider(
            value: _limit.toDouble(),
            min: 5,
            max: 200,
            divisions: 39,
            activeColor: const Color(0xFF00C08B),
            inactiveColor: const Color(0x22FFFFFF),
            onChanged: (v) => setState(() => _limit = v.round()),
            onChangeEnd: (_) => _save(),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [10, 20, 30, 50, 80, 100]
                .map((n) => _presetChip(n))
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _presetChip(int n) {
    final sel = _limit == n;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        setState(() => _limit = n);
        _save();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: sel ? const Color(0x1F00C08B) : const Color(0x0BFFFFFF),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: sel ? const Color(0xFF00C08B) : const Color(0x14FFFFFF)),
        ),
        child: Text('$n',
            style: TextStyle(
                color: sel ? const Color(0xFF00C08B) : const Color(0xFF8C9DA2),
                fontSize: 13,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _modeCard() {
    final s = widget.settings;
    Future<void> flip(Future<void> Function(bool) set, bool v) async {
      await set(v);
      if (mounted) setState(() {});
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        children: [
          _modeSwitch(
            title: '语义选项',
            subtitle: '英→中，看单词选释义',
            value: s.modeChoice,
            onChanged: (v) => flip(s.setModeChoice, v),
          ),
          const Divider(height: 1, color: Color(0x0FFFFFFF)),
          _modeSwitch(
            title: '短句选词',
            subtitle: '真题例句挖空选词',
            value: s.modeSentenceCloze,
            onChanged: (v) => flip(s.setModeSentenceCloze, v),
          ),
          const Divider(height: 1, color: Color(0x0FFFFFFF)),
          _modeSwitch(
            title: '语篇选词',
            subtitle: '章首文章整篇填词（多邻国式）',
            value: s.modePassageCloze,
            onChanged: (v) => flip(s.setModePassageCloze, v),
          ),
        ],
      ),
    );
  }

  Widget _modeSwitch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      activeColor: const Color(0xFF00C08B),
      activeTrackColor: const Color(0x3300C08B),
      value: value,
      onChanged: onChanged,
      title: Text(title,
          style: const TextStyle(
              color: Color(0xFFF0F4F5),
              fontSize: 15,
              fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: Color(0xFF54666C), fontSize: 12)),
    );
  }

  Widget _todayCard() {
    final s = widget.settings;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0x0BFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x14FFFFFF)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('今日已背',
                  style: TextStyle(color: Color(0xFFF0F4F5), fontSize: 15)),
              Text('${s.todayDone} / ${s.dailyLimit}',
                  style: const TextStyle(
                      color: Color(0xFF00C08B),
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFF5C5C),
                side: const BorderSide(color: Color(0x33FF5C5C)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                await s.resetToday();
                if (!mounted) return;
                setState(() {});
              },
              child: const Text('重置今日进度'),
            ),
          ),
        ],
      ),
    );
  }
}
