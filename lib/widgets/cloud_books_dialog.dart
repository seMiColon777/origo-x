import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/books/book_dao.dart';
import '../services/sync/cloud_book_service.dart';
import '../services/sync/reading_progress_sync_service.dart';

/// Lists the self-hosted cloud shelf and lets the user upload or download
/// whole book files. Reading positions continue to use the progress service.
class CloudBooksDialog extends StatefulWidget {
  const CloudBooksDialog({
    super.key,
    required this.config,
    required this.onLibraryChanged,
    this.service,
  });

  final ReadingProgressSyncConfig config;
  final VoidCallback onLibraryChanged;
  final CloudBookService? service;

  @override
  State<CloudBooksDialog> createState() => _CloudBooksDialogState();
}

class _CloudBooksDialogState extends State<CloudBooksDialog> {
  final BookDao _bookDao = BookDao();
  late final CloudBookService _service =
      widget.service ?? CloudBookService.instance;

  List<Book> _localBooks = const [];
  CloudShelf _shelf = CloudShelf.empty;
  bool _loading = true;
  String? _busyKey;
  double? _progress;
  String? _error;

  List<CloudBookRecord> get _remoteBooks => _shelf.books;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _chinese => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String chinese, String english) => _chinese ? chinese : english;

  Set<String> get _remoteKeys =>
      _remoteBooks.map((book) => book.bookKey).toSet();

  List<Book> get _uploadCandidates => _localBooks
      .where(
        (book) =>
            (book.contentHash == null || book.contentHash!.isEmpty) ||
            !_remoteKeys.contains(book.contentHash!.toLowerCase()),
      )
      .toList(growable: false);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _bookDao.getAllBooks(),
        _service.listShelf(widget.config),
      ]);
      if (!mounted) return;
      setState(() {
        _localBooks = results[0] as List<Book>;
        _shelf = results[1] as CloudShelf;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeCloudBookError(error, chinese: _chinese));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _upload(Book book) async {
    if (_busyKey != null) return;
    setState(() {
      _busyKey = 'upload:${book.id ?? book.filePath}';
      _progress = 0;
      _error = null;
    });
    try {
      final result = await _service.uploadBook(
        book,
        widget.config,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      await _persistHash(book, result.record.bookKey);
      if (!mounted) return;
      _snack(
        result.created
            ? _text('已上传《${book.title}》', 'Uploaded ${book.title}')
            : _text('云端已有《${book.title}》', '${book.title} is already uploaded'),
      );
      await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = describeCloudBookError(error, chinese: _chinese),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyKey = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _uploadAll() async {
    if (_busyKey != null) return;
    final candidates = _uploadCandidates
        .where(_supportsUpload)
        .toList(growable: false);
    if (candidates.isEmpty) return;
    setState(() {
      _busyKey = 'upload:all';
      _progress = 0;
      _error = null;
    });
    var uploaded = 0;
    try {
      for (var index = 0; index < candidates.length; index++) {
        final book = candidates[index];
        final result = await _service.uploadBook(
          book,
          widget.config,
          onProgress: (value) {
            if (mounted) {
              setState(() => _progress = (index + value) / candidates.length);
            }
          },
        );
        await _persistHash(book, result.record.bookKey);
        uploaded++;
      }
      if (!mounted) return;
      _snack(_text('已上传 $uploaded 本书', 'Uploaded $uploaded books'));
      await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = describeCloudBookError(error, chinese: _chinese),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyKey = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _persistHash(Book book, String bookKey) async {
    final id = book.id;
    if (id == null) return;
    if (book.contentHash?.trim().toLowerCase() == bookKey) return;
    try {
      await _bookDao.updateBookContentHash(id, bookKey);
    } catch (_) {
      // The upload itself succeeded; the next sync retries the hash update.
    }
  }

  bool _supportsUpload(Book book) {
    final format = book.format.trim().toLowerCase();
    return format == 'txt' || format == 'epub';
  }

  Future<void> _download(CloudBookRecord record) async {
    if (_busyKey != null) return;
    setState(() {
      _busyKey = 'download:${record.bookKey}';
      _progress = 0;
      _error = null;
    });
    try {
      final book = await _service.downloadBook(
        record,
        widget.config,
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      if (!mounted) return;
      _snack(_text('已下载《${book.title}》', 'Downloaded ${book.title}'));
      unawaited(ReadingProgressSyncService.instance.syncNow());
      widget.onLibraryChanged();
      await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = describeCloudBookError(error, chinese: _chinese),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyKey = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _delete(CloudBookRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_text('删除云端书籍？', 'Delete cloud book?')),
        content: Text(
          _text(
            '只会删除服务器上的《${record.title}》，不影响本机书库。',
            'This removes ${record.title} from the server only.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_text('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_text('删除', 'Delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busyKey = 'delete:${record.bookKey}';
      _error = null;
    });
    try {
      await _service.deleteBook(record, widget.config);
      if (!mounted) return;
      _snack(_text('已删除《${record.title}》', 'Deleted ${record.title}'));
      await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = describeCloudBookError(error, chinese: _chinese),
        );
      }
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(_text('云端书架', 'Cloud shelf')),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _text(
                '${widget.config.userId} · ${widget.config.serverUrl}',
                '${widget.config.userId} · ${widget.config.serverUrl}',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_shelf.quotaBytes > 0)
              Text(
                _text(
                  '已用 ${_formatBytes(_shelf.usageBytes)} / '
                      '${_formatBytes(_shelf.quotaBytes)}',
                  'Used ${_formatBytes(_shelf.usageBytes)} / '
                      '${_formatBytes(_shelf.quotaBytes)}',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _text(
                  '云端书籍模式会在打开书库时自动上传本机书籍和进度；'
                      '这里可以手动重试、下载或删除云端副本。',
                  'Cloud book mode uploads local books and positions when the '
                      'library opens. Use this dialog to retry, download or '
                      'delete cloud copies.',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (kIsWeb)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _text(
                    '浏览器端可以查看云端书架，但上传和下载需要在桌面或移动端进行。',
                    'You can browse the cloud shelf here, but uploads and '
                        'downloads require the desktop or mobile app.',
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (_busyKey != null) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: _progress),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        _sectionHeader(
                          _text('云端书籍', 'Cloud books'),
                          '${_remoteBooks.length}',
                        ),
                        if (_remoteBooks.isEmpty)
                          _emptyLine(
                            _text('服务器上还没有书籍。', 'No books on the server yet.'),
                          )
                        else
                          for (final record in _remoteBooks)
                            _remoteTile(record),
                        const SizedBox(height: 12),
                        _sectionHeader(
                          _text('本机待上传', 'Local books to upload'),
                          '${_uploadCandidates.length}',
                        ),
                        if (_uploadCandidates.isEmpty)
                          _emptyLine(
                            _text('本机书籍都已上传。', 'Every local book is uploaded.'),
                          )
                        else
                          for (final book in _uploadCandidates)
                            _localTile(book),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _loading || _busyKey != null ? null : _load,
          icon: const Icon(Icons.refresh),
          label: Text(_text('刷新', 'Refresh')),
        ),
        TextButton.icon(
          onPressed:
              _loading ||
                  _busyKey != null ||
                  _uploadCandidates.where(_supportsUpload).isEmpty
              ? null
              : _uploadAll,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: Text(_text('全部上传', 'Upload all')),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_text('关闭', 'Close')),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title, String count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          Text(count, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _emptyLine(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _remoteTile(CloudBookRecord record) {
    final local = _localBooks.any(
      (book) => book.contentHash?.trim().toLowerCase() == record.bookKey,
    );
    final busy =
        _busyKey == 'download:${record.bookKey}' ||
        _busyKey == 'delete:${record.bookKey}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.cloud_outlined),
      title: Text(record.title.isEmpty ? record.bookKey : record.title),
      subtitle: Text(
        '${record.author.isEmpty ? 'Unknown' : record.author} · '
        '${_formatBytes(record.sizeBytes)} · ${record.format.toUpperCase()}'
        '${local ? _text(' · 已在本机', ' · on this device') : ''}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: local
                ? _text('本机已有', 'Already on this device')
                : _text('下载', 'Download'),
            onPressed: local || busy || _busyKey != null || kIsWeb
                ? null
                : () => _download(record),
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: _text('删除云端文件', 'Delete cloud file'),
            onPressed: busy || _busyKey != null ? null : () => _delete(record),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  Widget _localTile(Book book) {
    final busy = _busyKey == 'upload:${book.id ?? book.filePath}';
    final supported = _supportsUpload(book);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.menu_book_outlined),
      title: Text(book.title),
      subtitle: Text('${book.author} · ${book.format.toUpperCase()}'),
      trailing: IconButton(
        tooltip: supported
            ? _text('上传', 'Upload')
            : _text('仅支持 TXT/EPUB', 'TXT/EPUB only'),
        onPressed: supported && !busy && _busyKey == null && !kIsWeb
            ? () => _upload(book)
            : null,
        icon: const Icon(Icons.cloud_upload_outlined),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
