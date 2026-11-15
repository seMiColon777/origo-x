// Opt-in cloud shelf for the self-hosted Origo X sync server.
//
// The service uploads and downloads book files only when the user enables
// "同步书籍文件". Reading positions stay in ReadingProgressSyncService; this
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

  final http.Client _client;
  final BookImportService? importer;
  final Future<Directory> Function() _temporaryDirectory;
  final Duration requestTimeout;

  Future<List<CloudBookRecord>> listBooks(
    ReadingProgressSyncConfig config,
  ) async {
    _ensureBooksReady(config);
    final response = await _client
        .get(_endpoint(config, _booksPath(config)), headers: _headers(config))
        .timeout(requestTimeout);
    final body = _decodeBody(response);
    if (response.statusCode != 200) {
      throw _errorFrom(response.statusCode, body);
    }
    final raw = body?['books'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(CloudBookRecord.fromJson)
        .where((record) => !record.isEmpty)
        .toList(growable: false);
  }

  Future<CloudBookUpload> uploadBook(
    Book book,
    ReadingProgressSyncConfig config, {
    void Function(double progress)? onProgress,
  }) async {
    _ensureBooksReady(config);
    if (kIsWeb) throw const CloudBookException('unsupported_platform');

    final file = File(book.filePath);
    if (!await file.exists()) {
      throw const CloudBookException('missing_file');
    }
    final size = await file.length();
    if (size <= 0) throw const CloudBookException('empty_book');

    final format = _normalizeFormat(book.format);
    final hash = await _fileMd5(
      file,
      onProgress: (progress) => onProgress?.call(progress * 0.15),
    );
    final title = book.title.trim().isEmpty ? 'Untitled' : book.title.trim();
    final author = book.author.trim().isEmpty ? 'Unknown' : book.author.trim();
    final uri = _endpoint(config, '${_booksPath(config)}/$hash').replace(
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
