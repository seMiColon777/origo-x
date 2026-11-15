// Self-hosted book file storage for the optional Origo X cloud shelf.
//
// Books are stored as one file per (user, content hash) pair. Metadata is kept
// in a single JSON index that is rewritten atomically, so the store stays
// dependency-free apart from the crypto package used to verify uploads.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Formats the reader can import again after a download.
const Set<String> allowedBookFormats = {'txt', 'epub'};

/// A rejected book operation. The status code is sent to the API client.
class BookStoreException implements Exception {
  const BookStoreException(this.code, this.statusCode);

  final String code;
  final int statusCode;

  @override
  String toString() => 'BookStoreException($code)';
}

/// One cloud book record. [bookKey] is the content hash of the stored bytes.
class StoredBook {
  const StoredBook({
    required this.bookKey,
    required this.title,
    required this.author,
    required this.format,
    required this.sizeBytes,
    required this.uploadedAt,
    required this.updatedAt,
  });

  factory StoredBook.fromJson(Map<String, dynamic> json) {
    return StoredBook(
      bookKey: (json['bookKey'] as String?)?.trim() ?? '',
      title: (json['title'] as String?)?.trim() ?? '',
      author: (json['author'] as String?)?.trim() ?? '',
      format: (json['format'] as String?)?.trim().toLowerCase() ?? '',
      sizeBytes: _int(json['sizeBytes']) ?? 0,
      uploadedAt: _int(json['uploadedAt']) ?? 0,
      updatedAt: _int(json['updatedAt']) ?? 0,
    );
  }

  final String bookKey;
  final String title;
  final String author;
  final String format;
  final int sizeBytes;
  final int uploadedAt;
  final int updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'bookKey': bookKey,
    'title': title,
    'author': author,
    'format': format,
    'sizeBytes': sizeBytes,
    'uploadedAt': uploadedAt,
    'updatedAt': updatedAt,
  };
}

/// Stores book blobs under `root/<userId>/<hash>.<format>` and their metadata
/// in [indexFile]. Writes are serialized and the index is replaced atomically.
class BookStore {
  BookStore({
    required this.root,
    required this.indexFile,
    required this.maxBookBytes,
    required this.quotaBytes,
  });

  final Directory root;
  final File indexFile;
  final int maxBookBytes;
  final int quotaBytes;

  final Map<String, Map<String, StoredBook>> _users = {};
  Future<void> _writes = Future<void>.value();

  static final RegExp _bookKeyPattern = RegExp(
    r'^(?:[a-f0-9]{32}|[a-f0-9]{64})$',
  );
  static final RegExp _userPattern = RegExp(
    r'^[\p{L}\p{N}._-]{1,100}$',
    unicode: true,
  );

  static bool isValidBookKey(String value) => _bookKeyPattern.hasMatch(value);

  static bool isValidUserId(String value) =>
      _userPattern.hasMatch(value) && value != '.' && value != '..';

  Future<void> load() async {
    if (!await indexFile.exists()) return;
    try {
      final decoded = jsonDecode(await indexFile.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final users = decoded['users'];
      if (users is! Map<String, dynamic>) return;
      for (final userEntry in users.entries) {
        if (!isValidUserId(userEntry.key)) continue;
        final books = userEntry.value;
        if (books is! Map<String, dynamic>) continue;
        final normalized = <String, StoredBook>{};
        for (final bookEntry in books.entries) {
          final key = bookEntry.key;
          final raw = bookEntry.value;
          if (!isValidBookKey(key) || raw is! Map<String, dynamic>) continue;
          final book = StoredBook.fromJson(raw);
          if (book.bookKey.isEmpty ||
              book.format.isEmpty ||
              !allowedBookFormats.contains(book.format)) {
            continue;
          }
          normalized[key] = book;
        }
        _users[userEntry.key] = normalized;
      }
    } catch (error) {
      stderr.writeln('Could not read ${indexFile.path}: $error');
    }
  }

  Future<List<StoredBook>> list(String userId) async {
    final books = _users[userId];
    if (books == null) return const [];
    final records = books.values.toList(growable: false);
    records.sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));
    return records;
  }

  StoredBook? find(String userId, String bookKey) => _users[userId]?[bookKey];

  File fileFor(String userId, StoredBook book) {
    final separator = Platform.pathSeparator;
    return File(
      '${root.path}$separator$userId$separator'
      '${book.bookKey}.${book.format}',
    );
  }

  int usage(String userId) {
    final books = _users[userId];
    if (books == null) return 0;
    return books.values.fold<int>(0, (sum, book) => sum + book.sizeBytes);
  }

  /// Streams [body] to a temporary file while hashing it. The upload is only
  /// committed when the MD5 matches [bookKey], the size fits and the user
  /// stays under quota.
  Future<StoredBook> save({
    required String userId,
    required String bookKey,
    required String title,
    required String author,
    required String format,
    required Stream<List<int>> body,
    int? declaredLength,
  }) async {
    if (!isValidUserId(userId)) {
      throw const BookStoreException('invalid_user_id', 400);
    }
    if (!isValidBookKey(bookKey)) {
      throw const BookStoreException('invalid_book_key', 400);
    }
    if (!allowedBookFormats.contains(format)) {
      throw const BookStoreException('unsupported_format', 400);
    }
    if (declaredLength != null && declaredLength > maxBookBytes) {
      throw const BookStoreException('book_too_large', 413);
    }

    final separator = Platform.pathSeparator;
    final userDirectory = Directory('${root.path}$separator$userId');
    await userDirectory.create(recursive: true);
    final temporary = File(
      '${userDirectory.path}$separator'
      '${bookKey}_${DateTime.now().microsecondsSinceEpoch}.part',
    );

    final sink = temporary.openWrite();
    final digestSink = _SingleDigestSink();
    final digest = md5.startChunkedConversion(digestSink);
    var written = 0;
    try {
      await for (final chunk in body) {
        written += chunk.length;
        if (written > maxBookBytes) {
          throw const BookStoreException('book_too_large', 413);
        }
        digest.add(chunk);
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      digest.close();
    } catch (error) {
      try {
        digest.close();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
      await _deleteQuietly(temporary);
      rethrow;
    }

    if (written == 0) {
      await _deleteQuietly(temporary);
      throw const BookStoreException('empty_book', 400);
    }
    if (digestSink.value.toString() != bookKey) {
      await _deleteQuietly(temporary);
      throw const BookStoreException('hash_mismatch', 400);
    }

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final record = StoredBook(
      bookKey: bookKey,
      title: title,
      author: author,
      format: format,
      sizeBytes: written,
      uploadedAt: now,
      updatedAt: now,
    );

    return _serialize(() async {
      final existing = _users[userId]?[bookKey];
      final used = usage(userId) - (existing?.sizeBytes ?? 0);
      if (used + record.sizeBytes > quotaBytes) {
        await _deleteQuietly(temporary);
        throw const BookStoreException('quota_exceeded', 413);
      }
      final target = fileFor(userId, record);
      await target.parent.create(recursive: true);
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
      (_users[userId] ??= <String, StoredBook>{})[bookKey] = record;
      await _persist();
      return record;
    });
  }

  Future<bool> delete(String userId, String bookKey) {
    return _serialize(() async {
      final existing = _users[userId]?.remove(bookKey);
      if (existing == null) return false;
      await _deleteQuietly(fileFor(userId, existing));
      if (_users[userId]?.isEmpty == true) _users.remove(userId);
      await _persist();
      return true;
    });
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<void> _persist() async {
    await indexFile.parent.create(recursive: true);
    final payload = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'users': _users.map(
        (userId, books) => MapEntry(
          userId,
          books.map((key, book) => MapEntry(key, book.toJson())),
        ),
      ),
    });
    final temporary = File('${indexFile.path}.tmp');
    await temporary.writeAsString(payload, flush: true);
    if (await indexFile.exists()) await indexFile.delete();
    await temporary.rename(indexFile.path);
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
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

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
