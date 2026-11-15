import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'book.dart';

/// The stable identity used by the progress sync service.
///
/// A content hash is shared by every device that imported the same file. When
/// an older import has no hash yet, a deterministic metadata digest is used so
/// the same book still maps to the same server record.
String readingProgressBookKey(Book book) {
  final contentHash = book.contentHash?.trim();
  if (contentHash != null && contentHash.isNotEmpty) {
    return 'hash:$contentHash';
  }
  final digest = sha256.convert(
    utf8.encode('${book.title}\u0000${book.author}\u0000${book.format}'),
  );
  return 'meta:$digest';
}

/// One portable reading-position record exchanged with the sync server.
///
/// [updatedAt] is assigned by the server. The client never writes it directly;
/// it sends [baseUpdatedAt] so the server can reject concurrent overwrites.
class ReadingProgressRecord {
  const ReadingProgressRecord({
    required this.bookKey,
    required this.title,
    required this.author,
    required this.format,
    required this.currentPage,
    required this.totalPages,
    required this.chapterIndex,
    required this.updatedAt,
    this.contentHash,
    this.readingProgress,
    this.canonicalLocator,
    this.deviceId,
    this.deviceName,
  });

  final String bookKey;
  final String title;
  final String author;
  final String format;
  final String? contentHash;
  final int currentPage;
  final int totalPages;
  final double? readingProgress;
  final String? canonicalLocator;
  final int chapterIndex;
  final int updatedAt;
  final String? deviceId;
  final String? deviceName;

  factory ReadingProgressRecord.fromBook(
    Book book, {
    required String bookKey,
    String? deviceId,
    String? deviceName,
  }) {
    return ReadingProgressRecord(
      bookKey: bookKey,
      title: book.title,
      author: book.author,
      format: book.format,
      contentHash: book.contentHash,
      currentPage: book.currentPage,
      totalPages: book.totalPages,
      readingProgress: book.progress,
      canonicalLocator: book.lastCanonicalLocator,
      chapterIndex: book.currentPage,
      updatedAt: 0,
      deviceId: deviceId,
      deviceName: deviceName,
    );
  }

  factory ReadingProgressRecord.fromJson(Map<String, dynamic> json) {
    return ReadingProgressRecord(
      bookKey: (json['bookKey'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      author: (json['author'] as String?) ?? '',
      format: (json['format'] as String?) ?? '',
      contentHash: json['contentHash'] as String?,
      currentPage: _asInt(json['currentPage']) ?? 0,
      totalPages: _asInt(json['totalPages']) ?? 1,
      readingProgress: _asDouble(json['readingProgress']),
      canonicalLocator: json['canonicalLocator'] as String?,
      chapterIndex: _asInt(json['chapterIndex']) ?? 0,
      updatedAt: _asInt(json['updatedAt']) ?? 0,
      deviceId: json['deviceId'] as String?,
      deviceName: json['deviceName'] as String?,
    );
  }

  /// Body sent to the server. [updatedAt] is intentionally excluded because
  /// the server owns it.
  Map<String, dynamic> toPushJson({int? baseUpdatedAt}) {
    return <String, dynamic>{
      'bookKey': bookKey,
      'title': title,
      'author': author,
      'format': format,
      'contentHash': contentHash,
      'currentPage': currentPage,
      'totalPages': totalPages,
      'readingProgress': readingProgress,
      'canonicalLocator': canonicalLocator,
      'chapterIndex': chapterIndex,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'baseUpdatedAt': baseUpdatedAt,
    };
  }

  ReadingProgressRecord copyWith({
    int? updatedAt,
    String? deviceId,
    String? deviceName,
  }) {
    return ReadingProgressRecord(
      bookKey: bookKey,
      title: title,
      author: author,
      format: format,
      contentHash: contentHash,
      currentPage: currentPage,
      totalPages: totalPages,
      readingProgress: readingProgress,
      canonicalLocator: canonicalLocator,
      chapterIndex: chapterIndex,
      updatedAt: updatedAt ?? this.updatedAt,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
    );
  }

  /// True when this record does not describe a real reading position.
  bool get isEmpty => bookKey.isEmpty || title.isEmpty;
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}
