import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../services/books/book_dao.dart';
import '../services/books/book_import_models.dart';
import '../services/books/book_import_service.dart';
import '../services/core/theme_notifier.dart';
import '../services/reading/reading_stats_dao.dart';
import '../services/sync/reading_progress_sync_service.dart';
import '../widgets/cloud_books_dialog.dart';
import 'reader/native/native_reader_page.dart';

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    this.booksLoader,
    this.onOpenBook,
    this.onImport,
  });

  final Future<List<Book>> Function()? booksLoader;
  final Future<void> Function(Book)? onOpenBook;
  final Future<void> Function()? onImport;

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  final _booksDao = BookDao();
  late Future<List<Book>> _books;
  bool _importing = false;
  bool _syncBusy = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _books = _loadBooks();
    // A custom loader is the testable/library-embedding path. Only the real
    // app startup touches the configured sync server.
    if (widget.booksLoader == null) {
      unawaited(_syncOnLaunch());
    }
  }

  Future<List<Book>> _loadBooks() =>
      (widget.booksLoader ?? _booksDao.getAllBooks)();

  Future<void> _syncOnLaunch() async {
    try {
      final result = await ReadingProgressSyncService.instance.syncNow();
      if (mounted && result.pulled > 0) _reload();
    } catch (error) {
      debugPrint('reading progress sync on launch failed: $error');
    }
  }

  void _reload() {
    if (mounted) {
      final books = _loadBooks();
      setState(() {
        _books = books;
      });
    }
  }

  bool get _chinese => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String chinese, String english) => _chinese ? chinese : english;

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _import() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      if (widget.onImport != null) {
        await widget.onImport!();
      } else {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['txt', 'epub'],
          allowMultiple: true,
          withData: kIsWeb,
        );
        if (result == null) return;
        final importer = BookImportService();
        var imported = 0;
        for (final file in result.files) {
          final source = BookImportSource(
            id: 'picker:${file.name}:${DateTime.now().microsecondsSinceEpoch}',
            kind: BookImportSourceKind.filePicker,
            ownership: BookImportOwnership.externalCopy,
            displayName: file.name,
            extension: file.extension ?? '',
            locator: file.path ?? file.name,
            localPath: file.path,
            sizeBytes: file.size,
            bytes: file.bytes,
          );
          await importer.importFile(source);
          imported++;
        }
        _message(_text('已处理 $imported 本书', 'Processed $imported books'));
      }
      _reload();
    } catch (error) {
      _message(_text('导入失败：$error', 'Import failed: $error'));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _open(Book book) async {
    if (widget.onOpenBook != null) {
      await widget.onOpenBook!(book);
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => NativeReaderPage(book: book)),
      );
    }
    _reload();
  }

  Future<void> _showStats() async {
    try {
      final stats = await ReadingStatsDao().getSummaryStats();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_text('本地阅读统计', 'Local reading statistics')),
          content: Text(
            _text(
              '今日 ${(stats['today'] ?? 0) ~/ 60} 分钟\n本周 ${(stats['week'] ?? 0) ~/ 60} 分钟\n累计 ${(stats['total'] ?? 0) ~/ 60} 分钟',
              'Today: ${(stats['today'] ?? 0) ~/ 60} minutes\nThis week: ${(stats['week'] ?? 0) ~/ 60} minutes\nTotal: ${(stats['total'] ?? 0) ~/ 60} minutes',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_text('关闭', 'Close')),
            ),
          ],
        ),
      );
    } catch (error) {
      _message(_text('无法读取统计：$error', 'Could not load statistics: $error'));
    }
  }

  Future<void> _showSyncSettings() async {
    if (_syncBusy) return;
    final service = ReadingProgressSyncService.instance;
    final config = await service.loadConfig();
    if (!mounted) return;
    final updated = await showDialog<ReadingProgressSyncConfig>(
      context: context,
      builder: (_) =>
          _SyncSettingsDialog(initialConfig: config, service: service),
    );
    if (updated == null || !mounted) return;
    try {
      final saved = await service.saveConfig(
        enabled: updated.enabled,
        booksEnabled: updated.booksEnabled,
        serverUrl: updated.serverUrl,
        userId: updated.userId,
        token: updated.token,
        deviceName: updated.deviceName,
      );
      if (!saved.enabled) {
        _message(_text('已关闭服务端同步', 'Server sync disabled'));
        return;
      }
      setState(() => _syncBusy = true);
      final result = await service.syncNow();
      _message(result.describe(chinese: _chinese));
      if (result.pulled > 0) _reload();
    } catch (error) {
      _message(_text('同步失败：$error', 'Sync failed: $error'));
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  Future<void> _showCloudBooks() async {
    final service = ReadingProgressSyncService.instance;
    var config = await service.loadConfig();
    if (!mounted) return;
    if (!config.enabled || !config.isReady) {
      _message(_text('请先配置服务端同步', 'Configure server sync first'));
      await _showSyncSettings();
      return;
    }
    if (!config.booksEnabled) {
      _message(
        _text(
          '请先在同步设置中开启“同步书籍文件”',
          'Enable "Sync book files" in the sync settings first',
        ),
      );
      await _showSyncSettings();
      config = await service.loadConfig();
      if (!mounted || !config.booksEnabled) return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) =>
          CloudBooksDialog(config: config, onLibraryChanged: _reload),
    );
    _reload();
  }

  Future<void> _remove(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_text('从书库移除？', 'Remove from library?')),
        content: Text(book.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_text('取消', 'Cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_text('移除', 'Remove')),
          ),
        ],
      ),
    );
    if (confirmed == true && book.id != null) {
      try {
        await _booksDao.deleteBook(book.id!);
        _reload();
      } catch (error) {
        _message(_text('移除失败：$error', 'Removal failed: $error'));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_text('本地书库', 'Local library')),
      actions: [
        IconButton(
          tooltip: _text('云端书架', 'Cloud shelf'),
          onPressed: _showCloudBooks,
          icon: const Icon(Icons.cloud_outlined),
        ),
        IconButton(
          tooltip: _text('服务端同步设置', 'Server sync settings'),
          onPressed: _syncBusy ? null : _showSyncSettings,
          icon: _syncBusy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_sync_outlined),
        ),
        IconButton(
          tooltip: _text('阅读统计', 'Reading statistics'),
          onPressed: _showStats,
          icon: const Icon(Icons.bar_chart),
        ),
        IconButton(
          tooltip: _text('切换主题', 'Toggle theme'),
          onPressed: () => context.read<ThemeNotifier>().toggleTheme(
            Theme.of(context).brightness != Brightness.dark,
          ),
          icon: const Icon(Icons.brightness_6_outlined),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _importing ? null : _import,
      icon: _importing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.add),
      label: Text(_text('导入 TXT / EPUB', 'Import TXT / EPUB')),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: _text('搜索书名或作者', 'Search title or author'),
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) =>
                setState(() => _query = value.trim().toLowerCase()),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Book>>(
            future: _books,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_text('书库加载失败', 'Could not load library')),
                      TextButton(
                        onPressed: _reload,
                        child: Text(_text('重试', 'Retry')),
                      ),
                    ],
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final books = snapshot.data!
                  .where(
                    (book) => '${book.title} ${book.author}'
                        .toLowerCase()
                        .contains(_query),
                  )
                  .toList();
              if (books.isEmpty) {
                return Center(
                  child: Text(
                    _text(
                      '导入自己的 TXT 或 EPUB，开始阅读。',
                      'Import your own TXT or EPUB to start reading.',
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.only(bottom: 100),
                itemCount: books.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final book = books[index];
                  final cover = book.coverImagePath;
                  return ListTile(
                    leading:
                        !kIsWeb && cover != null && File(cover).existsSync()
                        ? Image.file(
                            File(cover),
                            width: 44,
                            height: 60,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.menu_book),
                          )
                        : const Icon(Icons.menu_book),
                    title: Text(book.title),
                    subtitle: Text(
                      '${book.author} · ${(book.progress * 100).round()}%',
                    ),
                    onTap: () => _open(book),
                    trailing: IconButton(
                      tooltip: _text('移除', 'Remove'),
                      onPressed: () => _remove(book),
                      icon: const Icon(Icons.more_horiz),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}

class _SyncSettingsDialog extends StatefulWidget {
  const _SyncSettingsDialog({
    required this.initialConfig,
    required this.service,
  });

  final ReadingProgressSyncConfig initialConfig;
  final ReadingProgressSyncService service;

  @override
  State<_SyncSettingsDialog> createState() => _SyncSettingsDialogState();
}

class _SyncSettingsDialogState extends State<_SyncSettingsDialog> {
  late final TextEditingController _serverController;
  late final TextEditingController _userIdController;
  late final TextEditingController _tokenController;
  late final TextEditingController _deviceController;
  late bool _enabled;
  late bool _booksEnabled;
  bool _testing = false;
  bool _testSucceeded = false;
  String? _testMessage;

  @override
  void initState() {
    super.initState();
    _enabled = widget.initialConfig.enabled;
    _booksEnabled = widget.initialConfig.booksEnabled;
    _serverController = TextEditingController(
      text: widget.initialConfig.serverUrl,
    );
    _userIdController = TextEditingController(
      text: widget.initialConfig.userId,
    );
    _tokenController = TextEditingController(text: widget.initialConfig.token);
    _deviceController = TextEditingController(
      text: widget.initialConfig.deviceName,
    );
  }

  @override
  void dispose() {
    _serverController.dispose();
    _userIdController.dispose();
    _tokenController.dispose();
    _deviceController.dispose();
    super.dispose();
  }

  bool get _chinese => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String chinese, String english) => _chinese ? chinese : english;

  ReadingProgressSyncConfig _currentConfig() {
    return widget.initialConfig.copyWith(
      enabled: _enabled,
      booksEnabled: _enabled && _booksEnabled,
      serverUrl: _serverController.text.trim(),
      userId: _userIdController.text.trim(),
      token: _tokenController.text.trim(),
      deviceName: _deviceController.text.trim(),
    );
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    final error = await widget.service.testConnection(_currentConfig());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testSucceeded = error == null;
      _testMessage = error == null
          ? _text('服务器连接正常', 'Server reachable')
          : _text('连接失败：$error', 'Connection failed: $error');
    });
  }

  void _save() {
    final url = _serverController.text.trim();
    final userId = _userIdController.text.trim();
    if (_enabled && (url.isEmpty || userId.isEmpty)) {
      setState(() {
        _testSucceeded = false;
        _testMessage = _text(
          '启用同步时必须填写服务器地址和用户 ID',
          'A server URL and user ID are required when sync is enabled',
        );
      });
      return;
    }
    Navigator.pop(context, _currentConfig());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_text('服务端同步', 'Server sync')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _enabled,
                onChanged: (value) => setState(() {
                  _enabled = value;
                  if (!value) _booksEnabled = false;
                }),
                title: Text(_text('启用服务端同步', 'Enable server sync')),
                subtitle: Text(
                  _text(
                    '在多台设备之间同步阅读位置',
                    'Keep reading positions in sync across devices',
                  ),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _enabled && _booksEnabled,
                onChanged: _enabled
                    ? (value) => setState(() => _booksEnabled = value)
                    : null,
                title: Text(_text('同步书籍文件', 'Sync book files')),
                subtitle: Text(
                  _text(
                    '把 TXT/EPUB 上传到你自己的服务器，其他设备可直接下载。'
                        '关闭时只同步阅读位置。',
                    'Upload TXT/EPUB files to your own server so other '
                        'devices can download them. When off, only reading '
                        'positions are exchanged.',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _serverController,
                enabled: _enabled,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: _text('服务器地址', 'Server URL'),
                  hintText: 'http://192.168.1.10:8787',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _userIdController,
                enabled: _enabled,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: _text('用户 ID', 'User ID'),
                  helperText: _text(
                    '同一个用户 ID 的设备共享阅读进度',
                    'Devices with the same user ID share progress',
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tokenController,
                enabled: _enabled,
                obscureText: true,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: _text('访问令牌（可选）', 'Access token (optional)'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _deviceController,
                enabled: _enabled,
                decoration: InputDecoration(
                  labelText: _text('设备名称', 'Device name'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _text(
                  '默认只交换阅读位置。开启“同步书籍文件”后，书籍本体才会'
                      '上传到你的服务器；笔记和阅读统计始终留在本机。',
                  'Only reading positions are exchanged by default. Book '
                      'files are uploaded to your own server after you enable '
                      '"Sync book files"; notes and statistics stay on this '
                      'device.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_testMessage != null) ...[
                const SizedBox(height: 12),
                Text(
                  _testMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _testSucceeded
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _enabled && !_testing ? _testConnection : null,
          child: Text(
            _testing
                ? _text('测试中…', 'Testing…')
                : _text('测试连接', 'Test connection'),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_text('取消', 'Cancel')),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(_text('保存并同步', 'Save and sync')),
        ),
      ],
    );
  }
}
