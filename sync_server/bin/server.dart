// Self-hosted reading-progress sync server for Origo X.
//
// Run with:
//   dart run sync_server/bin/server.dart
//
// Configuration (environment variables):
//   HOST             Bind address, default 0.0.0.0
//   PORT             Bind port, default 8787
//   SYNC_DATA_FILE   JSON storage file, default sync_server/data/progress.json
//   SYNC_TOKEN       Optional bearer token required for all /v1 endpoints
//
// API:
//   GET  /health
//   GET  /v1/users/{userId}/progress
//   PUT  /v1/users/{userId}/progress/{bookKey}
//
// The server is intentionally dependency-free and stores data in a single
// JSON document. For a multi-user deployment put it behind your own TLS
// reverse proxy and choose a strong SYNC_TOKEN.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int _maxBodyBytes = 1024 * 1024;
const int _defaultPort = 8787;

Future<void> main(List<String> arguments) async {
  final host = Platform.environment['HOST']?.trim().isNotEmpty == true
      ? Platform.environment['HOST']!.trim()
      : '0.0.0.0';
  final port =
      int.tryParse(Platform.environment['PORT']?.trim() ?? '') ?? _defaultPort;
  final dataPath =
      Platform.environment['SYNC_DATA_FILE']?.trim().isNotEmpty == true
      ? Platform.environment['SYNC_DATA_FILE']!.trim()
      : 'sync_server/data/progress.json';
  final token = Platform.environment['SYNC_TOKEN']?.trim();

  final store = ProgressStore(File(dataPath));
  await store.load();

  final server = await HttpServer.bind(host, port);
  stdout.writeln(
    'Origo X progress sync listening on http://$host:$port '
    '(data: ${store.file.path})',
  );

  final router = _SyncServer(store: store, token: token);
  await for (final request in server) {
    unawaited(router.handle(request));
  }
}

class _SyncServer {
  _SyncServer({required this.store, this.token});

  final ProgressStore store;
  final String? token;

  Future<void> handle(HttpRequest request) async {
    _applyCors(request.response);
    try {
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      final path = request.uri.path;
      if (request.method == 'GET' && path == '/health') {
        await _json(request.response, HttpStatus.ok, {
          'ok': true,
          'serverTime': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
        return;
      }

      final segments = request.uri.pathSegments;
      final isProgressRoute =
          segments.length >= 4 &&
          segments[0] == 'v1' &&
          segments[1] == 'users' &&
          segments[3] == 'progress';
      if (!isProgressRoute) {
        await _json(request.response, HttpStatus.notFound, {
          'error': 'not_found',
        });
        return;
      }
      if (!_authorized(request)) {
        await _json(request.response, HttpStatus.unauthorized, {
          'error': 'unauthorized',
        });
        return;
      }

      final userId = segments[2].trim();
      if (!_validIdentifier(userId)) {
        await _json(request.response, HttpStatus.badRequest, {
          'error': 'invalid_user_id',
        });
        return;
      }

      if (segments.length == 4 && request.method == 'GET') {
        final records = await store.recordsFor(userId);
        await _json(request.response, HttpStatus.ok, {
          'records': records,
          'serverTime': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
        return;
      }

      if (segments.length == 5 && request.method == 'PUT') {
        final bookKey = segments[4].trim();
        if (!_validIdentifier(bookKey)) {
          await _json(request.response, HttpStatus.badRequest, {
            'error': 'invalid_book_key',
          });
          return;
        }
        await _putProgress(request, userId, bookKey);
        return;
      }

      await _json(request.response, HttpStatus.methodNotAllowed, {
        'error': 'method_not_allowed',
      });
    } catch (error) {
      try {
        await _json(request.response, HttpStatus.internalServerError, {
          'error': 'internal_error',
        });
      } catch (_) {
        // The response may already be closed when an error escapes a handler.
      }
      stderr.writeln('sync request failed: $error');
    }
  }

  Future<void> _putProgress(
    HttpRequest request,
    String userId,
    String bookKey,
  ) async {
    final String raw;
    try {
      raw = await _readBody(request);
    } on FormatException {
      await _json(request.response, HttpStatus.requestEntityTooLarge, {
        'error': 'body_too_large',
      });
      return;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': 'invalid_json',
      });
      return;
    }

    final incoming = _normalizeRecord(decoded, bookKey);
    if (incoming == null) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': 'invalid_record',
      });
      return;
    }

    final baseUpdatedAt = decoded['baseUpdatedAt'];
    final result = await store.put(
      userId: userId,
      bookKey: bookKey,
      record: incoming,
      baseUpdatedAt: baseUpdatedAt is int
          ? baseUpdatedAt
          : (baseUpdatedAt is num ? baseUpdatedAt.toInt() : null),
    );
    if (result.conflict != null) {
      await _json(request.response, HttpStatus.conflict, {
        'error': 'conflict',
        'record': result.conflict,
      });
      return;
    }
    await _json(request.response, HttpStatus.ok, {
      'record': result.record,
      'serverTime': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
  }

  Map<String, dynamic>? _normalizeRecord(
    Map<String, dynamic> input,
    String bookKey,
  ) {
    final title = _string(input['title']);
    final author = _string(input['author']);
    final format = _string(input['format']);
    if (title == null || author == null || format == null) return null;

    final contentHash = _string(input['contentHash']);
    final canonicalLocator = _string(input['canonicalLocator']);
    final deviceId = _string(input['deviceId']);
    final deviceName = _string(input['deviceName']);
    final totalPages = _int(input['totalPages']) ?? 1;
    final currentPage = _int(input['currentPage']) ?? 0;
    final chapterIndex = _int(input['chapterIndex']) ?? currentPage;
    final progress = _double(input['readingProgress']);

    return <String, dynamic>{
      'bookKey': bookKey,
      'title': title.length > 300 ? title.substring(0, 300) : title,
      'author': author.length > 300 ? author.substring(0, 300) : author,
      'format': format.length > 32 ? format.substring(0, 32) : format,
      'contentHash': contentHash,
      'currentPage': currentPage < 0 ? 0 : currentPage,
      'totalPages': totalPages < 1 ? 1 : totalPages,
      'readingProgress': progress?.clamp(0.0, 1.0).toDouble(),
      'canonicalLocator': canonicalLocator,
      'chapterIndex': chapterIndex < 0 ? 0 : chapterIndex,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'updatedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    };
  }

  bool _authorized(HttpRequest request) {
    final expected = token;
    if (expected == null || expected.isEmpty) return true;
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (header == null) return false;
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return false;
    return header.substring(prefix.length).trim() == expected;
  }

  bool _validIdentifier(String value) =>
      value.isNotEmpty && value.length <= 200 && !value.contains('/');

  Future<String> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > _maxBodyBytes) {
        throw const FormatException('request body too large');
      }
    }
    return utf8.decode(builder.takeBytes());
  }

  void _applyCors(HttpResponse response) {
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, PUT, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type, Authorization')
      ..set('Access-Control-Max-Age', '86400');
  }

  Future<void> _json(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> body,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  double? _double(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }
}

class PutResult {
  const PutResult._({this.record, this.conflict});

  factory PutResult.accepted(Map<String, dynamic> record) =>
      PutResult._(record: record);
  factory PutResult.conflicted(Map<String, dynamic> record) =>
      PutResult._(conflict: record);

  final Map<String, dynamic>? record;
  final Map<String, dynamic>? conflict;
}

/// Serializes writes to one JSON document and keeps the file atomically
/// replaceable. Reads are served from the in-memory map.
class ProgressStore {
  ProgressStore(this.file);

  final File file;
  final Map<String, Map<String, Map<String, dynamic>>> _users = {};
  Future<void> _writes = Future<void>.value();

  Future<void> load() async {
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final users = decoded['users'];
      if (users is! Map<String, dynamic>) return;
      for (final userEntry in users.entries) {
        final books = userEntry.value;
        if (books is! Map<String, dynamic>) continue;
        final normalized = <String, Map<String, dynamic>>{};
        for (final bookEntry in books.entries) {
          final record = bookEntry.value;
          if (record is Map<String, dynamic>) {
            normalized[bookEntry.key] = record;
          }
        }
        _users[userEntry.key] = normalized;
      }
    } catch (error) {
      stderr.writeln('Could not read ${file.path}: $error');
    }
  }

  Future<List<Map<String, dynamic>>> recordsFor(String userId) async {
    final books = _users[userId];
    if (books == null) return const [];
    final records = books.values.map(Map<String, dynamic>.from).toList();
    records.sort(
      (a, b) =>
          (b['updatedAt'] as int? ?? 0).compareTo(a['updatedAt'] as int? ?? 0),
    );
    return records;
  }

  Future<PutResult> put({
    required String userId,
    required String bookKey,
    required Map<String, dynamic> record,
    required int? baseUpdatedAt,
  }) {
    final result = _writes.then((_) async {
      final books = _users.putIfAbsent(userId, () => {});
      final existing = books[bookKey];
      if (existing != null && existing['updatedAt'] != baseUpdatedAt) {
        return PutResult.conflicted(Map<String, dynamic>.from(existing));
      }
      if (existing == null && baseUpdatedAt != null) {
        return PutResult.conflicted(<String, dynamic>{});
      }
      books[bookKey] = record;
      await _persist();
      return PutResult.accepted(Map<String, dynamic>.from(record));
    });
    _writes = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<void> _persist() async {
    await file.parent.create(recursive: true);
    final payload = const JsonEncoder.withIndent(
      '  ',
    ).convert({'version': 1, 'users': _users});
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
