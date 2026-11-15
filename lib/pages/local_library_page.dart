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
import '../services/sync/cloud_book_service.dart';
import '../services/sync/reading_progress_sync_service.dart';
import '../widgets/cloud_books_dialog.dart';
import 'reader/native/native_reader_page.dart';

class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({
    super.key,
    this.booksLoader,
    this.onOpenBook,
    this.onImport,
    this.cloudSync,
    this.cloudBookService,
    this.progressSyncService,
  });

  final Future<List<Book>> Function()? booksLoader;
  final Future<void> Function(Book)? onOpenBook;
  final Future<void> Function()? onImport;
  final CloudLibrarySync? cloudSync;
  final CloudBookService? cloudBookService;
  final ReadingProgressSyncService? progressSyncService;

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  final _booksDao = BookDao();
  late Future<List<Book>> _books;
  bool _importing = false;
  bool _syncBusy = false;
  String _query = '';
  ReadingProgressSyncConfig? _syncConfig;
  List<CloudBookRecord> _cloudBooks = const [];
  CloudShelf _cloudShelf = CloudShelf.empty;
  bool _cloudShelfLoaded = false;
  bool _cloudBusy = false;
  CloudLibrarySyncProgress? _cloudProgress;
  DateTime? _cloudSyncedAt;
  String? _cloudError;
  String? _downloadingKey;
  String? _downloadingTitle;
  double? _downloadProgress;

  CloudLibrarySync get _cloudSync =>
      widget.cloudSync ?? CloudLibrarySync.instance;
  CloudBookService get _cloudBooksService =>
      widget.cloudBookService ?? CloudBookService.instance;
  ReadingProgressSyncService get _progressSync =>
      widget.progressSyncService ?? ReadingProgressSyncService.instance;

  @override
  void initState() {
    super.initState();
    _books = _loadBooks();
    // A custom loader is the testable/library-embedding path. Only the real
    // app startup touches the configured sync server.
    if (widget.booksLoader == null || widget.cloudSync != null) {
      unawaited(_initializeSync());
    }
  }

  Future<List<Book>> _loadBooks() =>
      (widget.booksLoader ?? _booksDao.getAllBooks)();

  Future<void> _initializeSync() async {
    try {
      final config = await _cloudSync.loadConfig();
      if (!mounted) return;
      setState(() => _syncConfig = config);
      if (!config.enabled) return;
      if (config.booksReady) {
        await _runCloudSync(announce: false);
        return;
      }
      final result = await _progressSync.syncNow();
      if (mounted && result.pulled > 0) _reload();
    } catch (error) {
      debugPrint('reading progress sync on launch failed: $error');
    }
  }

  bool get _cloudModeEnabled => _syncConfig?.booksReady ?? false;

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
      if (_cloudModeEnabled && !_cloudBusy) {
        unawaited(_runCloudSync(announce: false));
      }
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
    final service = _progressSync;
    final config = _syncConfig ?? await service.loadConfig();
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
      if (!mounted) return;
      setState(() => _syncConfig = saved);
      if (!saved.enabled) {
        setState(() {
          _cloudBooks = const [];
          _cloudShelf = CloudShelf.empty;
          _cloudShelfLoaded = false;
          _cloudSyncedAt = null;
          _cloudError = null;
        });
        _message(_text('已关闭服务端同步', 'Server sync disabled'));
        return;
      }
      if (saved.booksReady) {
        await _runCloudSync(announce: true);
        return;
      }
      setState(() {
        _cloudBooks = const [];
        _cloudShelf = CloudShelf.empty;
        _cloudShelfLoaded = false;
      });
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

  Future<void> _runCloudSync({bool announce = true}) async {
    if (_cloudBusy) return;
    setState(() {
      _cloudBusy = true;
      _cloudError = null;
      _cloudProgress = null;
    });
    try {
      final result = await _cloudSync.syncNow(
        onProgress: (progress) {
          if (mounted) setState(() => _cloudProgress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _cloudShelf = result.shelf;
        _cloudBooks = result.shelf.books;
        _cloudShelfLoaded = result.shelfLoaded;
        _cloudSyncedAt = result.syncedAt ?? _cloudSyncedAt;
        _cloudError = switch (result.status) {
          CloudLibrarySyncStatus.failed => _describeCloudFailure(result),
          CloudLibrarySyncStatus.unsupportedPlatform => result.describe(
            chinese: _chinese,
          ),
          _ => null,
        };
      });
      _reload();
      if (announce) _message(result.describe(chinese: _chinese));
    } catch (error) {
      if (!mounted) return;
      final message = describeCloudBookError(error, chinese: _chinese);
      setState(() => _cloudError = message);
      if (announce) {
        _message(_text('云端同步失败：$message', 'Cloud sync failed: $message'));
      }
    } finally {
      if (mounted) {
        setState(() {
          _cloudBusy = false;
          _cloudProgress = null;
        });
      }
    }
  }

  String _describeCloudFailure(CloudLibrarySyncResult result) {
    if (result.errors.isEmpty) return result.describe(chinese: _chinese);
    return describeCloudBookError(result.errors.first, chinese: _chinese);
  }

  Future<void> _refreshCloudShelf() async {
    final config = _syncConfig;
    if (config == null || !config.booksReady) return;
    try {
      final shelf = await _cloudBooksService.listShelf(config);
      if (!mounted) return;
      setState(() {
        _cloudShelf = shelf;
        _cloudBooks = shelf.books;
        _cloudShelfLoaded = true;
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _cloudError = describeCloudBookError(error, chinese: _chinese),
        );
      }
    }
  }

  Future<void> _uploadBook(Book book) async {
    if (_cloudBusy) return;
    setState(() {
      _cloudBusy = true;
      _cloudError = null;
      _cloudProgress = CloudLibrarySyncProgress(
        phase: CloudLibrarySyncPhase.uploading,
        book: book,
        total: 1,
      );
    });
    try {
      await _cloudSync.uploadBook(
        book,
        onProgress: (value) {
          if (!mounted) return;
          setState(
            () => _cloudProgress = CloudLibrarySyncProgress(
              phase: CloudLibrarySyncPhase.uploading,
              book: book,
              total: 1,
              bookProgress: value,
            ),
          );
        },
      );
      if (!mounted) return;
      _message(_text('已上传《${book.title}》', 'Uploaded ${book.title}'));
      await _refreshCloudShelf();
      _reload();
    } catch (error) {
      if (mounted) {
        final message = describeCloudBookError(error, chinese: _chinese);
        setState(() => _cloudError = message);
        _message(_text('上传失败：$message', 'Upload failed: $message'));
      }
    } finally {
      if (mounted) {
        setState(() {
          _cloudBusy = false;
          _cloudProgress = null;
        });
      }
    }
  }

  Future<void> _downloadCloudBook(CloudBookRecord record) async {
    if (_downloadingKey != null) return;
    final config = _syncConfig;
    if (config == null || !config.booksReady) {
      _message(_text('请先开启云端书籍模式', 'Enable cloud book mode first'));
      return;
    }
    setState(() {
      _downloadingKey = record.bookKey;
      _downloadingTitle = record.title;
      _downloadProgress = 0;
      _cloudError = null;
    });
    try {
      final downloaded = await _cloudBooksService.downloadBook(
        record,
        config,
        onProgress: (value) {
          if (mounted) setState(() => _downloadProgress = value);
        },
      );
      if (!mounted) return;
      // Apply the server position before the reader opens the imported file.
      await _progressSync.syncNow();
      var book = downloaded;
      final id = downloaded.id;
      if (id != null) {
        book = await _booksDao.getBookById(id) ?? downloaded;
      }
      if (!mounted) return;
      _message(_text('已下载《${book.title}》', 'Downloaded ${book.title}'));
      _reload();
      unawaited(_refreshCloudShelf());
      await _open(book);
    } catch (error) {
      if (!mounted) return;
      final message = describeCloudBookError(error, chinese: _chinese);
      setState(() => _cloudError = message);
      _message(_text('下载失败：$message', 'Download failed: $message'));
    } finally {
      if (mounted) {
        setState(() {
          _downloadingKey = null;
          _downloadingTitle = null;
          _downloadProgress = null;
        });
      }
    }
  }

  Future<void> _showCloudBooks() async {
    final service = _progressSync;
    var config = _syncConfig ?? await service.loadConfig();
    if (!mounted) return;
    if (!config.enabled || !config.isReady) {
      _message(_text('请先配置服务端同步', 'Configure server sync first'));
      await _showSyncSettings();
      return;
    }
    if (!config.booksEnabled) {
      _message(
        _text(
          '请先在同步设置中开启“云端书籍模式”',
          'Enable "Cloud book mode" in the sync settings first',
        ),
      );
      await _showSyncSettings();
      config = _syncConfig ?? await service.loadConfig();
      if (!mounted || !config.booksEnabled) return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) =>
          CloudBooksDialog(config: config, onLibraryChanged: _reload),
    );
    _reload();
    if (_cloudModeEnabled) unawaited(_runCloudSync(announce: false));
  }

  void _openEntry(CloudShelfEntry entry) {
    final book = entry.local;
    if (book != null) {
      unawaited(_open(book));
      return;
    }
    final record = entry.cloud;
    if (record != null) unawaited(_downloadCloudBook(record));
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String? get _cloudProgressLabel {
    final downloading = _downloadingTitle;
    if (downloading != null) {
      final percent = ((_downloadProgress ?? 0) * 100).round();
      return _text(
        '正在下载《$downloading》 $percent%',
        'Downloading $downloading $percent%',
      );
    }
    final progress = _cloudProgress;
    if (progress == null) return null;
    switch (progress.phase) {
      case CloudLibrarySyncPhase.listing:
        return _text('正在读取云端书架…', 'Reading the cloud shelf…');
      case CloudLibrarySyncPhase.uploading:
        final book = progress.book;
        if (book == null) return _text('正在上传…', 'Uploading…');
        final total = progress.total <= 0 ? 1 : progress.total;
        final current =
            progress.completed + (progress.bookProgress < 1 ? 1 : 0);
        return _text(
          '正在上传《${book.title}》 $current/$total',
          'Uploading ${book.title} $current/$total',
        );
    }
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _cloudModeEnabled
              ? _text('云端书库', 'Cloud library')
              : _text('本地书库', 'Local library'),
        ),
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
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
          if (_cloudModeEnabled) _buildCloudBanner(theme),
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
                final localBooks = snapshot.data!
                    .where(
                      (book) => '${book.title} ${book.author}'
                          .toLowerCase()
                          .contains(_query),
                    )
                    .toList(growable: false);
                final cloudBooks = _cloudBooks
                    .where(
                      (record) => '${record.title} ${record.author}'
                          .toLowerCase()
                          .contains(_query),
                    )
                    .toList(growable: false);
                final entries = _cloudModeEnabled && _cloudShelfLoaded
                    ? mergeCloudShelf(
                        localBooks: localBooks,
                        cloudBooks: cloudBooks,
                      )
                    : <CloudShelfEntry>[
                        for (final book in localBooks)
                          CloudShelfEntry(local: book),
                      ];
                if (entries.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _cloudModeEnabled
                            ? _text(
                                '书库为空。导入 TXT/EPUB，或从云端书架下载。',
                                'The library is empty. Import a book or '
                                    'download one from the cloud shelf.',
                              )
                            : _text(
                                '导入自己的 TXT 或 EPUB，开始阅读。',
                                'Import your own TXT or EPUB to start reading.',
                              ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 100),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) => _buildEntry(entries[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCloudBanner(ThemeData theme) {
    final progressLabel = _cloudProgressLabel;
    final cloudCount = _cloudBooks.length;
    final usage = _cloudShelf.quotaBytes > 0
        ? ' · ${_formatBytes(_cloudShelf.usageBytes)} / '
              '${_formatBytes(_cloudShelf.quotaBytes)}'
        : '';
    final lastSync = _cloudSyncedAt == null
        ? ''
        : ' · ${_formatClock(_cloudSyncedAt!)}';
    final active = _cloudBusy || _downloadingKey != null;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_sync_outlined,
                size: 20,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _text('云端书籍模式', 'Cloud book mode'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    Text(
                      progressLabel ??
                          _text(
                            '云端 $cloudCount 本$usage$lastSync',
                            'Cloud: $cloudCount$usage$lastSync',
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
              if (active)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: _text('立即同步', 'Sync now'),
                  onPressed: () => _runCloudSync(),
                  icon: const Icon(Icons.refresh),
                  color: theme.colorScheme.onSecondaryContainer,
                ),
            ],
          ),
          if (_cloudError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 8),
              child: Text(
                _cloudError!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (progressLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: LinearProgressIndicator(
                value: _downloadingKey != null
                    ? _downloadProgress
                    : _cloudProgress?.bookProgress,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEntry(CloudShelfEntry entry) {
    final book = entry.local;
    if (book == null) return _buildCloudOnlyEntry(entry.cloud!);
    return _buildLocalEntry(book, entry.cloud);
  }

  Widget _buildLocalEntry(Book book, CloudBookRecord? cloud) {
    final cover = book.coverImagePath;
    final subtitle = <String>[
      book.author,
      '${(book.progress * 100).round()}%',
      if (_cloudModeEnabled)
        cloud == null
            ? _text('待上传', 'Not uploaded')
            : _text('云端已同步', 'In cloud'),
    ].join(' · ');
    return ListTile(
      leading: !kIsWeb && cover != null && File(cover).existsSync()
          ? Image.file(
              File(cover),
              width: 44,
              height: 60,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Icon(Icons.menu_book),
            )
          : const Icon(Icons.menu_book),
      title: Text(book.title),
      subtitle: Text(subtitle),
      onTap: () => _openEntry(CloudShelfEntry(local: book, cloud: cloud)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_cloudModeEnabled && cloud == null)
            IconButton(
              tooltip: _text('上传到云端', 'Upload to cloud'),
              onPressed: _cloudBusy ? null : () => _uploadBook(book),
              icon: const Icon(Icons.cloud_upload_outlined),
            ),
          IconButton(
            tooltip: _text('移除', 'Remove'),
            onPressed: () => _remove(book),
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
    );
  }

  Widget _buildCloudOnlyEntry(CloudBookRecord record) {
    final downloading = _downloadingKey == record.bookKey;
    final author = record.author.trim().isEmpty ? 'Unknown' : record.author;
    final subtitle = <String>[
      author,
      _formatBytes(record.sizeBytes),
      record.format.toUpperCase(),
      _text('云端', 'Cloud'),
    ].join(' · ');
    return ListTile(
      leading: const Icon(Icons.cloud_outlined),
      title: Text(record.title.isEmpty ? record.bookKey : record.title),
      subtitle: Text(subtitle),
      onTap: downloading ? null : () => _downloadCloudBook(record),
      trailing: downloading
          ? SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                value: _downloadProgress,
                strokeWidth: 2,
              ),
            )
          : IconButton(
              tooltip: _text('下载', 'Download'),
              onPressed: () => _downloadCloudBook(record),
              icon: const Icon(Icons.download_outlined),
            ),
    );
  }

  String _formatClock(DateTime value) {
    final local = value.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
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
                title: Text(_text('云端书籍模式', 'Cloud book mode')),
                subtitle: Text(
                  _text(
                    '把本机 TXT/EPUB 和阅读进度自动同步到服务器，'
                        '书库会列出云端书籍并按需下载。关闭时只同步阅读位置。',
                    'Automatically sync local TXT/EPUB files and reading '
                        'positions to your server. The library lists cloud '
                        'books and downloads them on demand. When off, only '
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
                    '同一个用户 ID 的设备共享阅读进度和云端书籍',
                    'Devices with the same user ID share positions and books',
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
                  '默认只交换阅读位置。开启“云端书籍模式”后，本机 TXT/EPUB '
                      '会自动上传到你的服务器，书库会同时显示云端书籍；'
                      '笔记和阅读统计始终留在本机。',
                  'Only reading positions are exchanged by default. With '
                      '"Cloud book mode" on, local TXT/EPUB files are uploaded '
                      'to your own server automatically and the library also '
                      'lists cloud books; notes and statistics stay on this '
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
