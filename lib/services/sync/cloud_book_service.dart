// Opt-in cloud shelf for the self-hosted Origo X sync server.
//
// The service uploads and downloads book files only when the user enables
// "云端书籍模式". Reading positions stay in ReadingProgressSyncService; this
// class never uploads notes, bookmarks or statistics.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/book.dart';
import '../books/book_dao.dart';
import '../books/book_import_models.dart';
import '../books/book_import_service.dart';
import 'reading_progress_sync_service.dart';

class CloudBookRecord {
  const CloudBookRecord({
    required this.bookKey,
    required this.title,
    required this.author,
    required this.format,
    required this.sizeBytes,
    required this.uploadedAt,
    required this.updatedAt,
  });

  factory CloudBookRecord.fromJson(Map<String, dynamic> json) {
    return CloudBookRecord(
      bookKey: (json['bookKey'] as String?)?.trim() ?? '',
      title: (json['title'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim() ?? '',
      format: (json['format'] as String?)?.trim().toLowerCase() ?? '',
      sizeBytes: _asInt(json['sizeBytes']) ?? 0,
      uploadedAt: _asInt(json['uploadedAt']) ?? 0,
      updatedAt: _asInt(json['updatedAt']) ?? 0,
    );
  }

  final String bookKey;
  final String title;
  final String author;
  final String format;
  final int sizeBytes;
  final int uploadedAt;
  final int updatedAt;

  bool get isEmpty => bookKey.isEmpty;
}

class CloudBookUpload {
  const CloudBookUpload({required this.record, required this.created});

  final CloudBookRecord record;
  final bool created;
}

/// One snapshot of the server-side shelf, including its storage usage.
class CloudShelf {
  const CloudShelf({
    required this.books,
    this.usageBytes = 0,
    this.quotaBytes = 0,
  });

  static const CloudShelf empty = CloudShelf(books: []);

  final List<CloudBookRecord> books;
  final int usageBytes;
  final int quotaBytes;

  bool get isEmpty => books.isEmpty;

  Set<String> get keys => books.map((book) => book.bookKey).toSet();
}

class CloudBookException implements Exception {
  const CloudBookException(this.code, {this.statusCode, this.message});

  final String code;
  final int? statusCode;
  final String? message;

  @override
  String toString() {
    final status = statusCode == null ? '' : ', HTTP $statusCode';
    return 'CloudBookException($code$status)';
  }
}

class CloudBookService {
  CloudBookService({
    http.Client? client,
    this.importer,
    Future<Directory> Function()? temporaryDirectory,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _client = client ?? http.Client(),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static final CloudBookService instance = CloudBookService();

  static final RegExp _md5Pattern = RegExp(r'^[a-f0-9]{32}$');

  final http.Client _client;
  final BookImportService? importer;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration requestTimeout;

  Future<List<CloudBookRecord>> listBooks(
    ReadingProgressSyncConfig config,
  ) async => (await listShelf(config)).books;

  Future<CloudShelf> listShelf(ReadingProgressSyncConfig config) async {
    _ensureBooksReady(config);
    final response = await _client
        .get(_endpoint(config, _booksPath(config)), headers: _headers(config))
        .timeout(requestTimeout);
    final body = _decodeBody(response);
    if (response.statusCode != 200) {
      throw _errorFrom(response.statusCode, body);
    }
    final raw = body?['books'];
    final books = raw is List
        ? raw
              .whereType<Map<String, dynamic>>()
              .map(CloudBookRecord.fromJson)
              .where((record) => !record.isEmpty)
              .toList(growable: false)
        : const <CloudBookRecord>[];
    return CloudShelf(
      books: books,
      usageBytes:
          _asInt(body?['usageBytes']) ??
          books.fold<int>(0, (sum, book) => sum + book.sizeBytes),
      quotaBytes: _asInt(body?['quotaBytes']) ?? 0,
    );
  }

  /// The server keys a book by the MD5 of its bytes. Imports already store that
  /// hash; legacy rows are hashed on demand.
  Future<String> resolveBookKey(Book book) async {
    final stored = book.contentHash?.trim().toLowerCase();
    if (stored != null && _md5Pattern.hasMatch(stored)) return stored;
    final file = File(book.filePath);
    if (!await file.exists()) {
      throw const CloudBookException('missing_file');
    }
    return _fileMd5(file);
  }

  Future<CloudBookUpload> uploadBook(
    Book book,
    ReadingProgressSyncConfig config, {
    void Function(double progress)? onProgress,
  }) async {
    _ensureBooksReady(config);
    if (kIsWeb) throw const CloudBookException('unsupported_platform');

    final format = _normalizeFormat(book.format);
    final file = File(book.filePath);
    if (!await file.exists()) {
      throw const CloudBookException('missing_file');
    }
    final size = await file.length();
    if (size <= 0) throw const CloudBookException('empty_book');

    final title = book.title.trim().isEmpty ? 'Untitled' : book.title.trim();
    final author = book.author.trim().isEmpty ? 'Unknown' : book.author.trim();
    final storedKey = book.contentHash?.trim().toLowerCase() ?? '';
    final reusedKey = _md5Pattern.hasMatch(storedKey);

    var bookKey = reusedKey
        ? storedKey
        : await _fileMd5(
            file,
            onProgress: (progress) => onProgress?.call(progress * 0.15),
          );
    if (reusedKey) onProgress?.call(0.15);

    try {
      return await _putFile(
        file: file,
        size: size,
        bookKey: bookKey,
        title: title,
        author: author,
        format: format,
        config: config,
        onProgress: onProgress,
      );
    } on CloudBookException catch (error) {
      // A stale cached hash means the local file changed. Recompute it once so
      // the shelf key always matches the bytes actually stored on the server.
      if (error.code != 'hash_mismatch' || !reusedKey) rethrow;
      bookKey = await _fileMd5(
        file,
        onProgress: (progress) => onProgress?.call(progress * 0.15),
      );
      return _putFile(
        file: file,
        size: size,
        bookKey: bookKey,
        title: title,
        author: author,
        format: format,
        config: config,
        onProgress: onProgress,
      );
    }
  }

  Future<CloudBookUpload> _putFile({
    required File file,
    required int size,
    required String bookKey,
    required String title,
    required String author,
    required String format,
    required ReadingProgressSyncConfig config,
    void Function(double progress)? onProgress,
  }) async {
    final uri = _endpoint(config, '${_booksPath(config)}/$bookKey').replace(
      queryParameters: {'title': title, 'author': author, 'format': format},
    );

    final request = http.StreamedRequest('PUT', uri)
      ..headers.addAll(_headers(config))
      ..headers['Content-Type'] = 'application/octet-stream'
      ..contentLength = size;
    final responseFuture = _client.send(request);
    try {
      var sent = 0;
      await request.sink.addStream(
        file.openRead().map((chunk) {
          sent += chunk.length;
          onProgress?.call(0.15 + 0.8 * (sent / size));
          return chunk;
        }),
      );
      await request.sink.close();
    } catch (error) {
      try {
        await request.sink.close();
      } catch (_) {}
      try {
        await responseFuture;
      } catch (_) {}
      throw CloudBookException('upload_failed', message: error.toString());
    }

    final response = await responseFuture.timeout(requestTimeout);
    final body = await _decodeStreamed(response);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _errorFrom(response.statusCode, body);
    }
    final raw = body?['book'];
    if (raw is! Map<String, dynamic>) {
      throw const CloudBookException('invalid_response');
    }
    onProgress?.call(1);
    return CloudBookUpload(
      record: CloudBookRecord.fromJson(raw),
      created: response.statusCode == 201,
    );
  }

  Future<Book> downloadBook(
    CloudBookRecord record,
    ReadingProgressSyncConfig config, {
    void Function(double progress)? onProgress,
  }) async {
    _ensureBooksReady(config);
    if (kIsWeb) throw const CloudBookException('unsupported_platform');
    if (record.bookKey.isEmpty) {
      throw const CloudBookException('invalid_record');
    }
    final format = _normalizeFormat(record.format);
    final request = http.Request(
      'GET',
      _endpoint(config, '${_booksPath(config)}/${record.bookKey}'),
    )..headers.addAll(_headers(config));
    final response = await _client.send(request).timeout(requestTimeout);
    if (response.statusCode != 200) {
      final body = await _decodeStreamed(response);
      throw _errorFrom(response.statusCode, body);
    }

    final directory = await _temporaryDirectory();
    await directory.create(recursive: true);
    final temporary = File(
      p.join(
        directory.path,
        'cloud_${record.bookKey}_'
        '${DateTime.now().microsecondsSinceEpoch}.$format',
      ),
    );
    final sink = temporary.openWrite();
    final digestSink = _SingleDigestSink();
    final digest = md5.startChunkedConversion(digestSink);
    final expectedSize = response.contentLength ?? record.sizeBytes;
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        digest.add(chunk);
        sink.add(chunk);
        if (expectedSize > 0) {
          onProgress?.call(0.7 * received / expectedSize);
        }
      }
      await sink.flush();
      await sink.close();
      digest.close();
      if (digestSink.value.toString() != record.bookKey) {
        throw const CloudBookException('hash_mismatch');
      }

      final importer = this.importer ?? BookImportService();
      final result = await importer.importFile(
        BookImportSource(
          id:
              'cloud:${record.bookKey}:'
              '${DateTime.now().microsecondsSinceEpoch}',
          kind: BookImportSourceKind.serverDownload,
          ownership: BookImportOwnership.externalCopy,
          displayName:
              '${record.title.isEmpty ? 'book' : record.title}.$format',
          extension: format,
          locator: 'cloud:${record.bookKey}',
          localPath: temporary.path,
          sizeBytes: received,
        ),
        onProgress: (_, progress, _) =>
            onProgress?.call(0.7 + 0.3 * progress.clamp(0.0, 1.0)),
      );
      onProgress?.call(1);
      return result.book;
    } finally {
      try {
        await sink.close();
      } catch (_) {}
      try {
        if (await temporary.exists()) await temporary.delete();
      } catch (_) {}
    }
  }

  Future<void> deleteBook(
    CloudBookRecord record,
    ReadingProgressSyncConfig config,
  ) async {
    _ensureBooksReady(config);
    final response = await _client
        .delete(
          _endpoint(config, '${_booksPath(config)}/${record.bookKey}'),
          headers: _headers(config),
        )
        .timeout(requestTimeout);
    if (response.statusCode == 204 ||
        response.statusCode == 200 ||
        response.statusCode == 404) {
      return;
    }
    throw _errorFrom(response.statusCode, _decodeBody(response));
  }

  void dispose() {
    _client.close();
  }

  String _booksPath(ReadingProgressSyncConfig config) =>
      '/v1/users/${Uri.encodeComponent(config.userId.trim())}/books';

  void _ensureBooksReady(ReadingProgressSyncConfig config) {
    if (!config.enabled || !config.booksEnabled) {
      throw const CloudBookException('books_disabled');
    }
    if (config.serverUrl.trim().isEmpty || config.userId.trim().isEmpty) {
      throw const CloudBookException('not_configured');
    }
  }

  Map<String, String> _headers(ReadingProgressSyncConfig config) {
    return <String, String>{
      'Accept': 'application/json',
      if (config.token.trim().isNotEmpty)
        'Authorization': 'Bearer ${config.token.trim()}',
    };
  }

  Uri _endpoint(ReadingProgressSyncConfig config, String path) {
    final base = Uri.parse(_normalizeServerUrl(config.serverUrl));
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$basePath$path');
  }

  String _normalizeServerUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  String _normalizeFormat(String format) {
    final normalized = format.trim().toLowerCase();
    if (normalized != 'txt' && normalized != 'epub') {
      throw const CloudBookException('unsupported_format');
    }
    return normalized;
  }

  Future<String> _fileMd5(
    File file, {
    void Function(double progress)? onProgress,
  }) async {
    final total = await file.length();
    final sink = _SingleDigestSink();
    final digest = md5.startChunkedConversion(sink);
    var read = 0;
    await for (final chunk in file.openRead()) {
      digest.add(chunk);
      read += chunk.length;
      if (total > 0) onProgress?.call(read / total);
    }
    digest.close();
    return sink.value.toString();
  }

  Map<String, dynamic>? _decodeBody(http.Response response) {
    if (response.bodyBytes.isEmpty) return null;
    try {
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _decodeStreamed(
    http.StreamedResponse response,
  ) async {
    final bytes = await response.stream.toBytes();
    if (bytes.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  CloudBookException _errorFrom(int statusCode, Map<String, dynamic>? body) {
    final code = (body?['error'] as String?)?.trim();
    return CloudBookException(
      code == null || code.isEmpty ? 'http_$statusCode' : code,
      statusCode: statusCode,
    );
  }
}

enum CloudLibrarySyncStatus {
  success,
  disabled,
  notConfigured,
  unsupportedPlatform,
  failed,
}

enum CloudLibrarySyncPhase { listing, uploading }

class CloudLibrarySyncProgress {
  const CloudLibrarySyncProgress({
    required this.phase,
    this.book,
    this.completed = 0,
    this.total = 0,
    this.bookProgress = 0,
  });

  final CloudLibrarySyncPhase phase;
  final Book? book;
  final int completed;
  final int total;
  final double bookProgress;
}

class CloudLibrarySyncResult {
  const CloudLibrarySyncResult({
    required this.status,
    this.shelf = CloudShelf.empty,
    this.shelfLoaded = false,
    this.uploaded = 0,
    this.skipped = 0,
    this.failed = 0,
    this.progressResult,
    this.errors = const [],
    this.syncedAt,
  });

  final CloudLibrarySyncStatus status;
  final CloudShelf shelf;
  final bool shelfLoaded;
  final int uploaded;
  final int skipped;
  final int failed;
  final ReadingProgressSyncResult? progressResult;
  final List<Object> errors;
  final DateTime? syncedAt;

  bool get isSuccess => status == CloudLibrarySyncStatus.success;

  String describe({required bool chinese}) {
    switch (status) {
      case CloudLibrarySyncStatus.disabled:
        return chinese ? '云端书籍模式已关闭' : 'Cloud book mode is off';
      case CloudLibrarySyncStatus.notConfigured:
        return chinese ? '请先填写服务器地址和用户 ID' : 'Set a server URL and user ID';
      case CloudLibrarySyncStatus.unsupportedPlatform:
        return chinese
            ? '浏览器端暂不支持书籍文件同步'
            : 'Book file sync is not available in the browser';
      case CloudLibrarySyncStatus.failed:
        final failedText = errors.isEmpty
            ? ''
            : (chinese
                  ? '（${errors.length} 项失败）'
                  : ' (${errors.length} failed)');
        return chinese
            ? '云端同步未完成$failedText'
            : 'Cloud sync did not finish$failedText';
      case CloudLibrarySyncStatus.success:
        final progress = progressResult;
        final progressText = progress == null
            ? ''
            : (chinese
                  ? '，进度上传 ${progress.pushed} 本、更新 ${progress.pulled} 本'
                  : ', ${progress.pushed} positions uploaded, '
                        '${progress.pulled} updated');
        return chinese
            ? '云端同步完成：上传 $uploaded 本，云端共 ${shelf.books.length} 本$progressText'
            : 'Cloud sync complete: $uploaded uploaded, '
                  '${shelf.books.length} in the cloud$progressText';
    }
  }
}

/// Orchestrates the "cloud book mode" of the library: pull/push reading
/// positions, list the server shelf, and upload every local TXT/EPUB that is
/// missing from it.
///
/// Downloads stay user-triggered so a device only stores the books it opens.
class CloudLibrarySync {
  CloudLibrarySync({
    BookDao? bookDao,
    CloudBookService? bookService,
    ReadingProgressSyncService? progressService,
  }) : _bookDao = bookDao ?? BookDao(),
       _bookService = bookService ?? CloudBookService.instance,
       _progressService =
           progressService ?? ReadingProgressSyncService.instance;

  static final CloudLibrarySync instance = CloudLibrarySync();

  final BookDao _bookDao;
  final CloudBookService _bookService;
  final ReadingProgressSyncService _progressService;

  Future<CloudLibrarySyncResult>? _running;

  Future<ReadingProgressSyncConfig> loadConfig() =>
      _progressService.loadConfig();

  /// Synchronizes positions and uploads missing book files. Concurrent calls
  /// share the running operation.
  Future<CloudLibrarySyncResult> syncNow({
    void Function(CloudLibrarySyncProgress progress)? onProgress,
  }) {
    final running = _running;
    if (running != null) return running;
    final future = _runSync(onProgress);
    _running = future.whenComplete(() {
      _running = null;
    });
    return _running!;
  }

  /// Uploads one book, persisting the computed content hash for legacy rows.
  Future<CloudBookUpload> uploadBook(
    Book book, {
    void Function(double progress)? onProgress,
  }) async {
    final config = await loadConfig();
    if (!config.enabled || !config.booksEnabled) {
      throw const CloudBookException('books_disabled');
    }
    if (config.serverUrl.trim().isEmpty || config.userId.trim().isEmpty) {
      throw const CloudBookException('not_configured');
    }
    if (kIsWeb) throw const CloudBookException('unsupported_platform');
    final upload = await _bookService.uploadBook(
      book,
      config,
      onProgress: onProgress,
    );
    await _persistHash(book, upload.record.bookKey);
    return upload;
  }

  Future<CloudLibrarySyncResult> _runSync(
    void Function(CloudLibrarySyncProgress progress)? onProgress,
  ) async {
    final config = await loadConfig();
    if (!config.enabled) {
      return const CloudLibrarySyncResult(
        status: CloudLibrarySyncStatus.disabled,
      );
    }
    if (!config.booksReady) {
      return const CloudLibrarySyncResult(
        status: CloudLibrarySyncStatus.notConfigured,
      );
    }
    if (kIsWeb) {
      return const CloudLibrarySyncResult(
        status: CloudLibrarySyncStatus.unsupportedPlatform,
      );
    }

    onProgress?.call(
      const CloudLibrarySyncProgress(phase: CloudLibrarySyncPhase.listing),
    );
    CloudShelf shelf;
    try {
      shelf = await _bookService.listShelf(config);
    } catch (error) {
      return CloudLibrarySyncResult(
        status: CloudLibrarySyncStatus.failed,
        errors: [error],
        syncedAt: DateTime.now().toUtc(),
      );
    }

    final progressResult = await _progressService.syncNow();
    final errors = <Object>[
      if (progressResult.status == ReadingProgressSyncStatus.failed)
        CloudBookException(
          'progress_sync_failed',
          message: progressResult.error,
        ),
    ];

    List<Book> localBooks;
    try {
      localBooks = await _bookDao.getAllBooks();
    } catch (error) {
      return CloudLibrarySyncResult(
        status: CloudLibrarySyncStatus.failed,
        shelf: shelf,
        shelfLoaded: true,
        progressResult: progressResult,
        errors: [...errors, error],
        syncedAt: DateTime.now().toUtc(),
      );
    }

    final cloudKeys = shelf.keys;
    final candidates = <Book>[];
    for (final book in localBooks) {
      if (!_canUpload(book)) continue;
      final key = book.contentHash?.trim().toLowerCase() ?? '';
      if (key.isNotEmpty && cloudKeys.contains(key)) continue;
      candidates.add(book);
    }

    var uploaded = 0;
    var skipped = 0;
    var failed = 0;
    final uploadedRecords = <CloudBookRecord>[];
    for (var index = 0; index < candidates.length; index++) {
      final book = candidates[index];
      onProgress?.call(
        CloudLibrarySyncProgress(
          phase: CloudLibrarySyncPhase.uploading,
          book: book,
          completed: index,
          total: candidates.length,
        ),
      );
      try {
        final upload = await _bookService.uploadBook(
          book,
          config,
          onProgress: (value) {
            onProgress?.call(
              CloudLibrarySyncProgress(
                phase: CloudLibrarySyncPhase.uploading,
                book: book,
                completed: index,
                total: candidates.length,
                bookProgress: value,
              ),
            );
          },
        );
        uploaded++;
        uploadedRecords.add(upload.record);
        await _persistHash(book, upload.record.bookKey);
      } on CloudBookException catch (error) {
        if (_isSkippable(error.code)) {
          skipped++;
        } else {
          failed++;
          errors.add(error);
        }
      } catch (error) {
        failed++;
        errors.add(error);
      }
      onProgress?.call(
        CloudLibrarySyncProgress(
          phase: CloudLibrarySyncPhase.uploading,
          book: book,
          completed: index + 1,
          total: candidates.length,
          bookProgress: 1,
        ),
      );
    }

    var finalShelf = shelf;
    if (uploaded > 0) {
      try {
        finalShelf = await _bookService.listShelf(config);
      } catch (_) {
        finalShelf = CloudShelf(
          books: [...shelf.books, ...uploadedRecords],
          usageBytes:
              shelf.usageBytes +
              uploadedRecords.fold<int>(0, (sum, book) => sum + book.sizeBytes),
          quotaBytes: shelf.quotaBytes,
        );
      }
    }

    return CloudLibrarySyncResult(
      status:
          failed > 0 ||
              progressResult.status == ReadingProgressSyncStatus.failed
          ? CloudLibrarySyncStatus.failed
          : CloudLibrarySyncStatus.success,
      shelf: finalShelf,
      shelfLoaded: true,
      uploaded: uploaded,
      skipped: skipped,
      failed: failed,
      progressResult: progressResult,
      errors: errors,
      syncedAt: DateTime.now().toUtc(),
    );
  }

  bool _canUpload(Book book) {
    final format = book.format.trim().toLowerCase();
    if (format != 'txt' && format != 'epub') return false;
    final path = book.filePath.trim();
    return path.isNotEmpty && !path.startsWith('web-book://');
  }

  bool _isSkippable(String code) =>
      code == 'missing_file' ||
      code == 'empty_book' ||
      code == 'unsupported_format';

  Future<void> _persistHash(Book book, String bookKey) async {
    final id = book.id;
    if (id == null) return;
    if (book.contentHash?.trim().toLowerCase() == bookKey) return;
    try {
      await _bookDao.updateBookContentHash(id, bookKey);
    } catch (error) {
      debugPrint('Could not persist cloud book hash for $id: $error');
    }
  }
}

/// One row of the merged local/cloud shelf.
class CloudShelfEntry {
  const CloudShelfEntry({this.local, this.cloud})
    : assert(local != null || cloud != null);

  final Book? local;
  final CloudBookRecord? cloud;

  bool get isCloudOnly => local == null;
  bool get isInCloud => cloud != null;
  String get title => local?.title ?? cloud?.title ?? '';
  String get author => local?.author ?? cloud?.author ?? '';
}

/// Merges local books with the cloud shelf. A local row wins, and cloud-only
/// books are appended newest first. Books without a hash fall back to a unique
/// title/author/format match so an already-uploaded legacy row is not listed
/// twice.
List<CloudShelfEntry> mergeCloudShelf({
  required List<Book> localBooks,
  required List<CloudBookRecord> cloudBooks,
}) {
  final byKey = <String, CloudBookRecord>{
    for (final record in cloudBooks) record.bookKey: record,
  };
  final used = <String>{};
  final entries = <CloudShelfEntry>[];
  for (final book in localBooks) {
    final key = book.contentHash?.trim().toLowerCase() ?? '';
    CloudBookRecord? match;
    if (key.isNotEmpty) {
      match = byKey[key];
    } else {
      final candidates = cloudBooks
          .where(
            (record) =>
                !used.contains(record.bookKey) &&
                record.title.trim().toLowerCase() ==
                    book.title.trim().toLowerCase() &&
                record.author.trim().toLowerCase() ==
                    book.author.trim().toLowerCase() &&
                record.format.trim().toLowerCase() ==
                    book.format.trim().toLowerCase(),
          )
          .toList(growable: false);
      if (candidates.length == 1) match = candidates.single;
    }
    if (match != null) used.add(match.bookKey);
    entries.add(CloudShelfEntry(local: book, cloud: match));
  }
  final cloudOnly =
      cloudBooks.where((record) => !used.contains(record.bookKey)).toList()
        ..sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));
  entries.addAll(cloudOnly.map((record) => CloudShelfEntry(cloud: record)));
  return entries;
}

String describeCloudBookError(Object error, {required bool chinese}) {
  if (error is CloudBookException) {
    final status = error.statusCode == null
        ? ''
        : ' (HTTP ${error.statusCode})';
    switch (error.code) {
      case 'books_disabled':
        return chinese
            ? '请先在同步设置中开启“云端书籍模式”'
            : 'Enable "Cloud book mode" in the sync settings first';
      case 'not_configured':
        return chinese ? '请先填写服务器地址和用户 ID' : 'Set a server URL and user ID';
      case 'unsupported_platform':
        return chinese
            ? 'Web 端暂不支持书籍文件同步'
            : 'Book file sync is not available in the browser';
      case 'missing_file':
        return chinese ? '本机书籍文件不存在' : 'The local book file is missing';
      case 'empty_book':
        return chinese ? '书籍文件为空' : 'The book file is empty';
      case 'unsupported_format':
        return chinese ? '仅支持 TXT 和 EPUB' : 'Only TXT and EPUB are supported';
      case 'hash_mismatch':
        return chinese ? '文件校验失败，请重试' : 'File verification failed, retry';
      case 'quota_exceeded':
        return chinese ? '服务器空间不足' : 'The server quota is full';
      case 'unauthorized':
        return chinese ? '访问令牌不正确' : 'The access token is not accepted';
      case 'book_not_found':
        return chinese ? '云端没有这本书' : 'The cloud book no longer exists';
      case 'book_too_large':
        return chinese ? '书籍文件超过服务器限制' : 'The book exceeds the server limit';
      case 'progress_sync_failed':
        return chinese
            ? '阅读进度同步失败：${error.message ?? '网络错误'}'
            : 'Position sync failed: ${error.message ?? 'network error'}';
      case 'upload_failed':
        return chinese ? '上传中断，请检查网络' : 'Upload interrupted, check the network';
      default:
        return '${error.code}$status';
    }
  }
  return error.toString();
}

class _SingleDigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
