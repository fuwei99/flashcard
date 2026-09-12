/// flashcard · 入口
/// 书架 -> 书 -> 章 -> 页 -> 背诵
library;

import 'package:flutter/material.dart';

import 'models/book.dart';
import 'models/deck.dart';
import 'screens/bookshelf_screen.dart';
import 'services/card_store.dart';
import 'services/deck_repository.dart';
import 'services/study_settings.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FlashcardApp());
}

class FlashcardApp extends StatelessWidget {
  const FlashcardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flashcard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF141D1F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00C08B),
          surface: Color(0xFF141D1F),
        ),
      ),
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  final _repo = DeckRepository();
  final _store = CardStore();
  final _settings = StudySettings();

  List<Book>? _books;
  Map<String, CardTemplate>? _templates;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _store.init();
      await _settings.init();
      final books = await _repo.loadAllBooks();
      final templates = await _repo.loadAllTemplates();
      if (!mounted) return;
      setState(() {
        _books = books;
        _templates = templates;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Text('初始化失败：$_error',
              style: const TextStyle(color: Color(0xFFFF5C5C))),
        ),
      );
    }
    if (_books == null || _templates == null) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF00C08B)),
        ),
      );
    }
    return BookShelfScreen(
      books: _books!,
      templates: _templates!,
      store: _store,
      settings: _settings,
    );
  }
}
