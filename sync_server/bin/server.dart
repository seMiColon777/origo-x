// Self-hosted sync server for Origo X.
//
// Run with:
//   dart run sync_server/bin/server.dart
//
// Configuration (environment variables):
//   HOST                  Bind address, default 0.0.0.0
//   PORT                  Bind port, default 8787
//   SYNC_DATA_FILE        Progress JSON file, default sync_server/data/progress.json
//   SYNC_BOOKS_DIR        Book blob directory, default <data dir>/books
//   SYNC_BOOKS_INDEX      Book metadata index, default <data dir>/books.json
//   SYNC_MAX_BOOK_MB      Maximum size of one uploaded book, default 500
//   SYNC_USER_QUOTA_MB    Per-user book quota, default 5120 (5 GiB)
//   SYNC_USERS            Optional per-user tokens: "alice:token1,bob:token2"
//   SYNC_TOKEN            Optional shared token when SYNC_USERS is unset
//
// API:
//   GET    /health
//   GET    /v1/users/{userId}/progress
//   PUT    /v1/users/{userId}/progress/{bookKey}
//   GET    /v1/users/{userId}/books
//   GET    /v1/users/{userId}/books/{bookKey}
//   PUT    /v1/users/{userId}/books/{bookKey}
//   DELETE /v1/users/{userId}/books/{bookKey}
//
// The server is dependency-free apart from package:crypto and stores data in
// local JSON documents. Put it behind your own TLS reverse proxy before
// exposing it to the internet and choose strong tokens.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'book_store.dart';

const int _maxBodyBytes = 1024 * 1024;
const int _defaultPort = 8787;

Future<void> main(List<String> arguments) async {
  final environment = Platform.environment;
  final host = _nonEmpty(environment['HOST']) ?? '0.0.0.0';
  final port = int.tryParse(environment['PORT']?.trim() ?? '') ?? _defaultPort;
  final dataPath =
      _nonEmpty(environment['SYNC_DATA_FILE']) ??
      'sync_server/data/progress.json';
  final dataFile = File(dataPath);
  final dataDirectory = dataFile.parent;
  final separator = Platform.pathSeparator;
  final booksDirectory = Directory(
    _nonEmpty(environment['SYNC_BOOKS_DIR']) ??
        '${dataDirectory.path}${separator}books',
  );
  final booksIndex = File(
    _nonEmpty(environment['SYNC_BOOKS_INDEX']) ??
        '${dataDirectory.path}${separator}books.json',
  );
  final credentials = SyncCredentials.fromEnvironment(environment);

  final progressStore = ProgressStore(dataFile);
  final bookStore = BookStore(
    root: booksDirectory,
    indexFile: booksIndex,
    maxBookBytes: _megabytes(environment['SYNC_MAX_BOOK_MB'], 500),
    quotaBytes: _megabytes(environment['SYNC_USER_QUOTA_MB'], 5120),
  );
  await Future.wait([progressStore.load(), bookStore.load()]);

  final server = await HttpServer.bind(host, port);
  stdout.writeln(
    'Origo X sync listening on http://$host:$port '
    '(progress: ${progressStore.file.path}; books: ${booksDirectory.path}; '
    'user tokens: ${credentials.userTokens.length})',
  );

  final router = _SyncServer(
    progress: progressStore,
    books: bookStore,
    credentials: credentials,
  );
  await for (final request in server) {
    unawaited(router.handle(request));
  }
}

class SyncCredentials {
  const SyncCredentials({required this.userTokens, this.sharedToken});

  factory SyncCredentials.fromEnvironment(Map<String, String> environment) {
    final raw = environment['SYNC_USERS']?.trim() ?? '';
    final users = <String, String>{};
    if (raw.isNotEmpty) {
      for (final entry in raw.split(',')) {
        final pair = entry.trim();
        if (pair.isEmpty) continue;
        final separator = pair.indexOf(':');
        if (separator <= 0 || separator == pair.length - 1) continue;
        final user = pair.substring(0, separator).trim();
        final token = pair.substring(separator + 1).trim();
        if (user.isEmpty || token.isEmpty) continue;
        users[user] = token;
      }
    }
    final shared = _nonEmpty(environment['SYNC_TOKEN']);
    return SyncCredentials(
      userTokens: Map<String, String>.unmodifiable(users),
      sharedToken: users.isEmpty ? shared : null,
    );
  }

  final Map<String, String> userTokens;
  final String? sharedToken;

  bool allows(String userId, String? authorization) {
    final expected = userTokens.isNotEmpty ? userTokens[userId] : sharedToken;
    if (expected == null) return userTokens.isEmpty;
    final presented = _bearerToken(authorization);
    if (presented == null) return false;
    return _constantTimeEquals(expected, presented);
  }
}

class _SyncServer {
  _SyncServer({
    required this.progress,
    required this.books,
    required this.credentials,
  });

  final ProgressStore progress;
  final BookStore books;
  final SyncCredentials credentials;

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
          'features': ['progress', 'books'],
          'serverTime': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
        return;
      }

      final segments = request.uri.pathSegments;
      final isUserRoute =
          segments.length >= 4 && segments[0] == 'v1' && segments[1] == 'users';
      final isProgressRoute = isUserRoute && segments[3] == 'progress';
      final isBooksRoute = isUserRoute && segments[3] == 'books';
      if (!isProgressRoute && !isBooksRoute) {
        await _json(request.response, HttpStatus.notFound, {
          'error': 'not_found',
        });
        return;
      }

      final userId = segments[2].trim();
      if (!_authorized(request, userId)) {
        await _json(request.response, HttpStatus.unauthorized, {
          'error': 'unauthorized',
        });
        return;
      }

      if (isBooksRoute) {
        await _handleBooks(request, userId, segments);
        return;
      }

      if (!_validIdentifier(userId)) {
        await _json(request.response, HttpStatus.badRequest, {
          'error': 'invalid_user_id',
        });
        return;
      }

      if (segments.length == 4 && request.method == 'GET') {
        final records = await progress.recordsFor(userId);
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

  Future<void> _handleBooks(
    HttpRequest request,
    String userId,
    List<String> segments,
  ) async {
    if (!BookStore.isValidUserId(userId)) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': 'invalid_user_id',
      });
      return;
    }

    if (segments.length == 4 && request.method == 'GET') {
      final records = await books.list(userId);
      await _json(request.response, HttpStatus.ok, {
        'books': records.map((record) => record.toJson()).toList(),
        'usageBytes': books.usage(userId),
        'quotaBytes': books.quotaBytes,
        'serverTime': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
      return;
    }

    if (segments.length != 5) {
      await _json(request.response, HttpStatus.methodNotAllowed, {
        'error': 'method_not_allowed',
      });
      return;
    }

    final bookKey = segments[4].trim().toLowerCase();
    if (!BookStore.isValidBookKey(bookKey)) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': 'invalid_book_key',
      });
      return;
    }

    switch (request.method) {
      case 'PUT':
        await _putBook(request, userId, bookKey);
      case 'GET':
      case 'HEAD':
        await _downloadBook(request, userId, bookKey);
      case 'DELETE':
        await _deleteBook(request, userId, bookKey);
      default:
        await _json(request.response, HttpStatus.methodNotAllowed, {
          'error': 'method_not_allowed',
        });
    }
  }

  Future<void> _putBook(
    HttpRequest request,
    String userId,
    String bookKey,
  ) async {
    final parameters = request.uri.queryParameters;
    final format = (parameters['format'] ?? '').trim().toLowerCase();
    if (!allowedBookFormats.contains(format)) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': 'unsupported_format',
      });
      return;
    }
    final title = _clampText(parameters['title'], 'Untitled');
    final author = _clampText(parameters['author'], 'Unknown');
    final declaredLength = request.headers.contentLength;

    try {
      final record = await books.save(
        userId: userId,
        bookKey: bookKey,
        title: title,
        author: author,
        format: format,
        body: request,
        declaredLength: declaredLength >= 0 ? declaredLength : null,
      );
      await _json(request.response, HttpStatus.created, {
        'book': record.toJson(),
        'usageBytes': books.usage(userId),
        'quotaBytes': books.quotaBytes,
        'serverTime': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
    } on BookStoreException catch (error) {
      await _json(request.response, error.statusCode, {'error': error.code});
    }
  }

  Future<void> _downloadBook(
    HttpRequest request,
    String userId,
    String bookKey,
  ) async {
    final record = books.find(userId, bookKey);
    if (record == null) {
      await _json(request.response, HttpStatus.notFound, {
        'error': 'book_not_found',
      });
      return;
    }
    final file = books.fileFor(userId, record);
    if (!await file.exists()) {
      await _json(request.response, HttpStatus.notFound, {
        'error': 'book_file_missing',
      });
      return;
    }

    final size = await file.length();
    final response = request.response;
    response.headers
      ..set('Content-Type', _contentType(record.format))
      ..set('Accept-Ranges', 'bytes')
      ..set('ETag', '"${record.bookKey}-$size"')
      ..set(
        'Content-Disposition',
        _contentDisposition(record.title, record.format),
      );

    final ifNoneMatch = request.headers.value(HttpHeaders.ifNoneMatchHeader);
    if (ifNoneMatch != null &&
        ifNoneMatch.trim() == '"${record.bookKey}-$size"') {
      response.statusCode = HttpStatus.notModified;
      await response.close();
      return;
    }

    if (request.method == 'HEAD' || size == 0) {
      response.contentLength = size;
      await response.close();
      return;
    }

    final range = _parseRange(
      request.headers.value(HttpHeaders.rangeHeader),
      size,
    );
    if (range == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
      response.contentLength = 0;
      await response.close();
      return;
    }

    if (range.start == 0 && range.end == size - 1) {
      response.contentLength = size;
    } else {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes ${range.start}-${range.end}/$size',
      );
      response.contentLength = range.end - range.start + 1;
    }

    if (size == 0) {
      await response.close();
      return;
    }
    await response.addStream(file.openRead(range.start, range.end + 1));
    await response.close();
  }

  Future<void> _deleteBook(
    HttpRequest request,
    String userId,
    String bookKey,
  ) async {
    final removed = await books.delete(userId, bookKey);
    if (!removed) {
      await _json(request.response, HttpStatus.notFound, {
        'error': 'book_not_found',
      });
      return;
    }
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
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
    final result = await progress.put(
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

  bool _authorized(HttpRequest request, String userId) {
    return credentials.allows(
      userId,
      request.headers.value(HttpHeaders.authorizationHeader),
    );
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
      ..set('Access-Control-Allow-Methods', 'GET, PUT, DELETE, HEAD, OPTIONS')
      ..set(
        'Access-Control-Allow-Headers',
        'Content-Type, Authorization, Range',
      )
      ..set(
        'Access-Control-Expose-Headers',
        'Content-Length, Content-Range, ETag, Content-Disposition',
      )
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

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

int _megabytes(String? raw, int fallback) {
  final value = int.tryParse(raw?.trim() ?? '');
  if (value == null || value <= 0) return fallback * 1024 * 1024;
  return value * 1024 * 1024;
}

String _clampText(String? value, String fallback) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return fallback;
  return text.length > 300 ? text.substring(0, 300) : text;
}

({int start, int end})? _parseRange(String? header, int size) {
  if (header == null || header.trim().isEmpty) {
    return (start: 0, end: size - 1);
  }
  final value = header.trim();
  if (!value.startsWith('bytes=')) return null;
  final spec = value.substring('bytes='.length).trim();
  if (spec.contains(',')) return null;
  final dash = spec.indexOf('-');
  if (dash < 0) return null;
  final startText = spec.substring(0, dash).trim();
  final endText = spec.substring(dash + 1).trim();

  if (startText.isEmpty) {
    final suffix = int.tryParse(endText);
    if (suffix == null || suffix <= 0) return null;
    if (size == 0) return null;
    return (start: suffix >= size ? 0 : size - suffix, end: size - 1);
  }

  final start = int.tryParse(startText);
  if (start == null || start < 0 || start >= size) return null;
  final parsedEnd = endText.isEmpty ? size - 1 : int.tryParse(endText);
  if (parsedEnd == null || parsedEnd < start) return null;
  return (start: start, end: parsedEnd >= size ? size - 1 : parsedEnd);
}

String _contentType(String format) {
  return switch (format) {
    'epub' => 'application/epub+zip',
    'txt' => 'text/plain; charset=utf-8',
    _ => 'application/octet-stream',
  };
}

String _contentDisposition(String title, String format) {
  final fallback = title.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_').trim();
  final safeFallback = fallback.isEmpty ? 'book' : fallback;
  final encoded = Uri.encodeComponent('$title.$format');
  return 'attachment; filename="$safeFallback.$format"; '
      "filename*=UTF-8''$encoded";
}

String? _bearerToken(String? header) {
  if (header == null) return null;
  const prefix = 'Bearer ';
  if (!header.startsWith(prefix)) return null;
  final token = header.substring(prefix.length).trim();
  return token.isEmpty ? null : token;
}

bool _constantTimeEquals(String expected, String presented) {
  if (expected.length != presented.length) return false;
  var difference = 0;
  for (var index = 0; index < expected.length; index++) {
    difference |= expected.codeUnitAt(index) ^ presented.codeUnitAt(index);
  }
  return difference == 0;
}
