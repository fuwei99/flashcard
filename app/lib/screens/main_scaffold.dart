/// 主壳：底部 4 Tab（首页 / 单词 / Card / 我的）
library;

import 'package:flutter/material.dart';

import '../models/deck.dart';
import '../services/card_store.dart';
import '../services/deck_repository.dart';
import '../services/study_settings.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'me_screen.dart';

class MainScaffold extends StatefulWidget {
  final DeckRepository repo;
  final Map<String, CardTemplate> templates;
  final CardStore store;
  final StudySettings settings;

  /// 重新读公共目录里的模板（改完 CSS 点一下即可生效）
  final Future<void> Function()? onReloadTemplates;

  const MainScaffold({
    super.key,
    required this.repo,
    required this.templates,
    required this.store,
    required this.settings,
    this.onReloadTemplates,
  });

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _index = 0;

  final _homeKey = GlobalKey<HomeScreenState>();
  final _wordKey = GlobalKey<LibraryScreenState>();
  final _cardKey = GlobalKey<LibraryScreenState>();
  final _meKey = GlobalKey<MeScreenState>();

  void _select(int i) {
    setState(() => _index = i);
    // 切回来时刷新数据，保证复习完的进度立刻反映
    switch (i) {
      case 0:
        _homeKey.currentState?.refresh();
        break;
      case 1:
        _wordKey.currentState?.refresh();
        break;
      case 2:
        _cardKey.currentState?.refresh();
        break;
      case 3:
        _meKey.currentState?.refresh();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141D1F),
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(
            key: _homeKey,
            repo: widget.repo,
            templates: widget.templates,
            store: widget.store,
            settings: widget.settings,
          ),
          LibraryScreen(
            key: _wordKey,
            kind: LibraryKind.word,
            repo: widget.repo,
            templates: widget.templates,
            store: widget.store,
            settings: widget.settings,
          ),
          LibraryScreen(
            key: _cardKey,
            kind: LibraryKind.card,
            repo: widget.repo,
            templates: widget.templates,
            store: widget.store,
            settings: widget.settings,
          ),
          MeScreen(
            key: _meKey,
            store: widget.store,
            settings: widget.settings,
            onReloadTemplates: widget.onReloadTemplates,
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: _select,
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFF0F1719),
        selectedItemColor: const Color(0xFF00C08B),
        unselectedItemColor: const Color(0xFF54666C),
        showUnselectedLabels: true,
        items: const [
          BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home),
              label: '首页'),
          BottomNavigationBarItem(
              icon: Icon(Icons.menu_book_outlined),
              activeIcon: Icon(Icons.menu_book),
              label: '单词'),
          BottomNavigationBarItem(
              icon: Icon(Icons.style_outlined),
              activeIcon: Icon(Icons.style),
              label: 'Card'),
          BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: '我的'),
        ],
      ),
    );
  }
}
