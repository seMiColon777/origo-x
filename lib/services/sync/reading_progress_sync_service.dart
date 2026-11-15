import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/book.dart';
import '../../models/reading_progress_sync.dart';
import '../books/book_dao.dart';

/// User-editable connection settings for the optional sync server.
class ReadingProgressSyncConfig {
  const ReadingProgressSyncConfig({
    required this.enabled,
    required this.serverUrl,
    required this.userId,
    required this.token,
    required this.deviceId,
    required this.deviceName,
  });

  final bool enabled;
  final String serverUrl;
  final String userId;
  final String token;
  final String deviceId;
  final String deviceName;

  bool get isReady =>
      enabled &&
      serverUrl.trim().isNotEmpty &&
      userId.trim().isNotEmpty &&
      deviceId.trim().isNotEmpty;

  ReadingProgressSyncConfig copyWith({
    bool? enabled,
    String? serverUrl,
    String? userId,
    String? token,
    String? deviceId,
    String? deviceName,
  }) {
    return ReadingProgressSyncConfig(
      enabled: enabled ?? this.enabled,
      serverUrl: serverUrl ?? this.serverUrl,
      userId: userId ?? this.userId,
      token: token ?? this.token,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
    );
  }
}

enum ReadingProgressSyncStatus { success, disabled, notConfigured, failed }

class ReadingProgressSyncResult {
  const ReadingProgressSyncResult({
    required this.status,
    this.pushed = 0,
    this.pulled = 0,
    this.error,
    this.syncedAt,
  });

  final ReadingProgressSyncStatus status;
  final int pushed;
  final int pulled;
  final String? error;
  final DateTime? syncedAt;

  bool get isSuccess => status == ReadingProgressSyncStatus.success;

  String describe({required bool chinese}) {
    switch (status) {
      case ReadingProgressSyncStatus.disabled:
        return chinese ? '服务端同步已关闭' : 'Server sync is disabled';
      case ReadingProgressSyncStatus.notConfigured:
        return chinese ? '请先填写服务器地址和用户 ID' : 'Set a server URL and user ID';
      case ReadingProgressSyncStatus.failed:
        return chinese
            ? '同步未完成：${error ?? '网络错误'}'
            : 'Sync did not finish: ${error ?? 'network error'}';
      case ReadingProgressSyncStatus.success:
        return chinese
            ? '同步完成：上传 $pushed 本，更新 $pulled 本'
            : 'Sync complete: $pushed uploaded, $pulled updated';
    }
  }
}

enum _PushStatus { success, conflict, failed }

class _PushOutcome {
  const _PushOutcome._(this.status, {this.record, this.error});

  factory _PushOutcome.success(ReadingProgressRecord record) =>
      _PushOutcome._(_PushStatus.success, record: record);
  factory _PushOutcome.conflict(ReadingProgressRecord? record) =>
      _PushOutcome._(_PushStatus.conflict, record: record);
  factory _PushOutcome.failed(String error) =>
      _PushOutcome._(_PushStatus.failed, error: error);

  final _PushStatus status;
  final ReadingProgressRecord? record;
  final String? error;
}

class _SyncMeta {
  const _SyncMeta({
    required this.localUpdatedAt,
    required this.remoteUpdatedAt,
    required this.lastSyncedAt,
    required this.dirty,
  });

  factory _SyncMeta.empty() => const _SyncMeta(
    localUpdatedAt: 0,
    remoteUpdatedAt: null,
    lastSyncedAt: null,
    dirty: false,
  );

  factory _SyncMeta.fromJson(Map<String, dynamic> json) => _SyncMeta(
    localUpdatedAt: _asInt(json['localUpdatedAt']) ?? 0,
    remoteUpdatedAt: _asInt(json['remoteUpdatedAt']),
    lastSyncedAt: _asInt(json['lastSyncedAt']),
    dirty: json['dirty'] == true,
  );

  final int localUpdatedAt;
  final int? remoteUpdatedAt;
  final int? lastSyncedAt;
  final bool dirty;

  _SyncMeta copyWith({
    int? localUpdatedAt,
    int? remoteUpdatedAt,
    int? lastSyncedAt,
    bool? dirty,
  }) {
    return _SyncMeta(
      localUpdatedAt: localUpdatedAt ?? this.localUpdatedAt,
      remoteUpdatedAt: remoteUpdatedAt ?? this.remoteUpdatedAt,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      dirty: dirty ?? this.dirty,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'localUpdatedAt': localUpdatedAt,
    'remoteUpdatedAt': remoteUpdatedAt,
    'lastSyncedAt': lastSyncedAt,
    'dirty': dirty,
  };
}

/// Opt-in client for synchronizing reading positions with the self-hosted
/// server in `sync_server/`.
///
/// Local SQLite remains the source of truth while the reader is offline. The
/// service only exchanges [ReadingProgressRecord] values; it never uploads
/// book files, notes or statistics.
class ReadingProgressSyncService {
  ReadingProgressSyncService({
    BookDao? bookDao,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 12),
    this.pushDebounce = const Duration(seconds: 2),
  }) : _bookDao = bookDao ?? BookDao(),
       _client = client ?? http.Client();

  static final ReadingProgressSyncService instance =
      ReadingProgressSyncService();

  static const String enabledPreferenceKey = 'reading_progress_sync_enabled_v1';
  static const String serverUrlPreferenceKey =
      'reading_progress_sync_server_url_v1';
  static const String userIdPreferenceKey = 'reading_progress_sync_user_id_v1';
  static const String tokenPreferenceKey = 'reading_progress_sync_token_v1';
  static const String deviceIdPreferenceKey =
      'reading_progress_sync_device_id_v1';
  static const String deviceNamePreferenceKey =
      'reading_progress_sync_device_name_v1';
  static const String lastSyncAtPreferenceKey =
      'reading_progress_sync_last_at_v1';
  static const String lastErrorPreferenceKey =
      'reading_progress_sync_last_error_v1';
  static const String _metaPreferenceKey = 'reading_progress_sync_meta_v1';

  final BookDao _bookDao;
  final http.Client _client;
  final Duration requestTimeout;
  final Duration pushDebounce;

  Timer? _pushTimer;
  Future<void> _metaOperations = Future<void>.value();
  Future<ReadingProgressSyncResult>? _running;

  Future<ReadingProgressSyncConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(deviceIdPreferenceKey);
    if (deviceId == null || deviceId.trim().isEmpty) {
      deviceId = const Uuid().v4();
      await prefs.setString(deviceIdPreferenceKey, deviceId);
    }
    return ReadingProgressSyncConfig(
      enabled: prefs.getBool(enabledPreferenceKey) ?? false,
      serverUrl: prefs.getString(serverUrlPreferenceKey) ?? '',
      userId: prefs.getString(userIdPreferenceKey) ?? '',
      token: prefs.getString(tokenPreferenceKey) ?? '',
      deviceId: deviceId,
      deviceName:
          prefs.getString(deviceNamePreferenceKey) ?? _defaultDeviceName,
    );
  }

  Future<ReadingProgressSyncConfig> saveConfig({
    required bool enabled,
    required String serverUrl,
    required String userId,
    required String token,
    required String deviceName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = await loadConfig();
    final normalizedUrl = _normalizeServerUrl(serverUrl);
    final normalizedUserId = userId.trim();
    final identityChanged =
        previous.serverUrl != normalizedUrl ||
        previous.userId != normalizedUserId;
    await prefs.setBool(enabledPreferenceKey, enabled);
    await prefs.setString(serverUrlPreferenceKey, normalizedUrl);
    await prefs.setString(userIdPreferenceKey, normalizedUserId);
    await prefs.setString(tokenPreferenceKey, token.trim());
    await prefs.setString(
      deviceNamePreferenceKey,
      deviceName.trim().isEmpty ? _defaultDeviceName : deviceName.trim(),
    );
    if (identityChanged) {
      await prefs.remove(_metaPreferenceKey);
      await prefs.remove(lastSyncAtPreferenceKey);
      await prefs.remove(lastErrorPreferenceKey);
    }
    return loadConfig();
  }

  Future<DateTime?> lastSyncedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getInt(lastSyncAtPreferenceKey);
    if (value == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
  }

  Future<String?> lastError() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(lastErrorPreferenceKey);
    return value == null || value.isEmpty ? null : value;
  }

  /// Returns null when the server is reachable, otherwise a short message.
  Future<String?> testConnection(ReadingProgressSyncConfig config) async {
    final serverUrl = _normalizeServerUrl(config.serverUrl);
    if (serverUrl.isEmpty) {
      return 'Server URL is empty';
    }
    try {
      final response = await _client
          .get(
            _endpoint(config.copyWith(serverUrl: serverUrl), '/health'),
            headers: _headers(config),
          )
          .timeout(requestTimeout);
      if (response.statusCode == 200) return null;
      return 'HTTP ${response.statusCode}';
    } catch (error) {
      return error.toString();
    }
  }

  /// Marks a locally saved position as dirty and schedules a debounced push.
  /// The actual record is read from SQLite when the push runs, so a page turn
  /// that happens immediately afterwards always wins.
  Future<void> noteLocalProgressSaved(Book book) async {
    if (book.id == null) return;
    final config = await loadConfig();
    if (!config.isReady) return;
    final key = readingProgressBookKey(book);
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _updateMeta(
      key,
      (current) => (current ?? _SyncMeta.empty()).copyWith(
        localUpdatedAt: now,
        dirty: true,
      ),
    );
    _schedulePush();
  }

  /// Pushes local changes and then applies newer server records.
  Future<ReadingProgressSyncResult> syncNow() {
    final running = _running;
    if (running != null) return running;
    final future = _runSync();
    _running = future.whenComplete(() {
      _running = null;
    });
    return _running!;
  }

  Future<ReadingProgressSyncResult> _runSync() async {
    final config = await loadConfig();
    if (!config.enabled) {
      return const ReadingProgressSyncResult(
        status: ReadingProgressSyncStatus.disabled,
      );
    }
    if (config.serverUrl.isEmpty || config.userId.isEmpty) {
      return const ReadingProgressSyncResult(
        status: ReadingProgressSyncStatus.notConfigured,
      );
    }

    final List<Book> books;
    try {
      books = await _bookDao.getAllBooks();
    } catch (error) {
      return ReadingProgressSyncResult(
        status: ReadingProgressSyncStatus.failed,
        error: error.toString(),
      );
    }
    final booksByKey = <String, Book>{
      for (final book in books) readingProgressBookKey(book): book,
    };
    final meta = await _loadMeta();
    final failures = <String>[];
    var pushed = 0;
    var pulled = 0;

    for (final book in books) {
      if (book.id == null) continue;
      final key = readingProgressBookKey(book);
      final entry = meta[key];
      final shouldPush =
          entry?.dirty == true || (entry == null && book.progress > 0);
      if (!shouldPush) continue;

      final localUpdatedAt = entry?.localUpdatedAt ?? 0;
      var outcome = await _pushBook(config, book, key, entry);
      if (outcome.status == _PushStatus.conflict && entry?.dirty == true) {
        // This device changed the position after the last sync. Keep the
        // local write and retry once against the server's current revision.
        // A missing remote record is also retried with a null base so the
        // position can be recreated after server-side data loss.
        outcome = await _pushBook(
          config,
          book,
          key,
          entry,
          baseOverride: outcome.record?.updatedAt,
        );
      }

      if (outcome.status == _PushStatus.success && outcome.record != null) {
        pushed++;
        await _markPushed(key, outcome.record!, localUpdatedAt);
      } else if (outcome.status == _PushStatus.conflict) {
        final remote = outcome.record;
        if (remote == null) {
          failures.add('conflict:$key');
        } else if (entry?.dirty == true) {
          failures.add('conflict:$key');
        } else {
          await _applyRemote(book, key, remote);
          pulled++;
        }
      } else {
        failures.add(outcome.error ?? 'push_failed');
      }
    }

    try {
      final remoteRecords = await _fetchAll(config);
      for (final record in remoteRecords) {
        if (record.isEmpty) continue;
        final book = booksByKey[record.bookKey];
        if (book == null || book.id == null) continue;
        final entry = await _readMeta(record.bookKey);
        if (entry?.dirty == true) continue;
        if (entry?.remoteUpdatedAt == record.updatedAt) continue;
        await _applyRemote(book, record.bookKey, record);
        pulled++;
      }
    } catch (error) {
      failures.add(error.toString());
    }

    final now = DateTime.now().toUtc();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(lastSyncAtPreferenceKey, now.millisecondsSinceEpoch);
    if (failures.isEmpty) {
      await prefs.remove(lastErrorPreferenceKey);
    } else {
      await prefs.setString(lastErrorPreferenceKey, failures.first);
    }

    if (failures.isEmpty) {
      return ReadingProgressSyncResult(
        status: ReadingProgressSyncStatus.success,
        pushed: pushed,
        pulled: pulled,
        syncedAt: now,
      );
    }
    return ReadingProgressSyncResult(
      status: ReadingProgressSyncStatus.failed,
      pushed: pushed,
      pulled: pulled,
      error: failures.first,
      syncedAt: now,
    );
  }

  Future<_PushOutcome> _pushBook(
    ReadingProgressSyncConfig config,
    Book book,
    String key,
    _SyncMeta? entry, {
    int? baseOverride,
  }) async {
    final record = ReadingProgressRecord.fromBook(
      book,
      bookKey: key,
      deviceId: config.deviceId,
      deviceName: config.deviceName,
    );
    final body = record.toPushJson(
      baseUpdatedAt: baseOverride ?? entry?.remoteUpdatedAt,
    );
    try {
      final response = await _client
          .put(
            _endpoint(
              config,
              '/v1/users/${Uri.encodeComponent(config.userId)}'
              '/progress/${Uri.encodeComponent(key)}',
            ),
            headers: _headers(config),
            body: jsonEncode(body),
          )
          .timeout(requestTimeout);
      final decoded = _decodeJsonMap(response);
      if (response.statusCode == 200) {
        final rawRecord = decoded?['record'];
        if (rawRecord is Map<String, dynamic>) {
          return _PushOutcome.success(
            ReadingProgressRecord.fromJson(rawRecord),
          );
        }
        return _PushOutcome.failed('invalid_response');
      }
      if (response.statusCode == 409) {
        final rawRecord = decoded?['record'];
        if (rawRecord is Map<String, dynamic>) {
          final remote = ReadingProgressRecord.fromJson(rawRecord);
          return _PushOutcome.conflict(remote.isEmpty ? null : remote);
        }
        return _PushOutcome.conflict(null);
      }
      return _PushOutcome.failed('HTTP ${response.statusCode}');
    } catch (error) {
      return _PushOutcome.failed(error.toString());
    }
  }

  Future<List<ReadingProgressRecord>> _fetchAll(
    ReadingProgressSyncConfig config,
  ) async {
    final response = await _client
        .get(
          _endpoint(
            config,
            '/v1/users/${Uri.encodeComponent(config.userId)}/progress',
          ),
          headers: _headers(config),
        )
        .timeout(requestTimeout);
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final decoded = _decodeJsonMap(response);
    final rawRecords = decoded?['records'];
    if (rawRecords is! List) return const [];
    return rawRecords
        .whereType<Map<String, dynamic>>()
        .map(ReadingProgressRecord.fromJson)
        .where((record) => !record.isEmpty)
        .toList(growable: false);
  }

  Future<void> _applyRemote(
    Book book,
    String key,
    ReadingProgressRecord record,
  ) async {
    final bookId = book.id;
    if (bookId == null) return;
    await _bookDao.replaceBookProgress(
      bookId,
      currentPage: record.currentPage,
      readingProgress: record.readingProgress,
      canonicalLocator: record.canonicalLocator,
      totalPages: record.totalPages > 0 ? record.totalPages : null,
    );
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _updateMeta(
      key,
      (_) => _SyncMeta(
        localUpdatedAt: record.updatedAt,
        remoteUpdatedAt: record.updatedAt,
        lastSyncedAt: now,
        dirty: false,
      ),
    );
  }

  Future<void> _markPushed(
    String key,
    ReadingProgressRecord record,
    int pushedLocalUpdatedAt,
  ) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _updateMeta(key, (current) {
      final localChangedDuringPush = current != null
          ? current.localUpdatedAt > pushedLocalUpdatedAt
          : false;
      final localValue = current?.localUpdatedAt ?? record.updatedAt;
      return _SyncMeta(
        localUpdatedAt: localChangedDuringPush ? localValue : record.updatedAt,
        remoteUpdatedAt: record.updatedAt,
        lastSyncedAt: now,
        dirty: localChangedDuringPush,
      );
    });
  }

  void _schedulePush() {
    _pushTimer?.cancel();
    _pushTimer = Timer(pushDebounce, () {
      unawaited(syncNow());
    });
  }

  Future<_SyncMeta?> _readMeta(String key) =>
      _serializeMeta(() async => (await _loadMeta())[key]);

  Future<void> _updateMeta(String key, _SyncMeta? Function(_SyncMeta?) update) {
    return _serializeMeta(() async {
      final meta = await _loadMeta();
      final updated = update(meta[key]);
      if (updated == null) {
        meta.remove(key);
      } else {
        meta[key] = updated;
      }
      await _saveMeta(meta);
    });
  }

  Future<T> _serializeMeta<T>(Future<T> Function() operation) {
    final result = _metaOperations.then((_) => operation());
    _metaOperations = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<Map<String, _SyncMeta>> _loadMeta() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_metaPreferenceKey);
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final result = <String, _SyncMeta>{};
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          result[entry.key] = _SyncMeta.fromJson(value);
        }
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveMeta(Map<String, _SyncMeta> meta) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _metaPreferenceKey,
      jsonEncode(meta.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Map<String, String> _headers(ReadingProgressSyncConfig config) {
    return <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'application/json',
      if (config.token.trim().isNotEmpty)
        'Authorization': 'Bearer ${config.token.trim()}',
    };
  }

  Uri _endpoint(ReadingProgressSyncConfig config, String path) {
    final base = Uri.parse(config.serverUrl);
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

  Map<String, dynamic>? _decodeJsonMap(http.Response response) {
    try {
      final decoded = jsonDecode(
        utf8.decode(response.bodyBytes, allowMalformed: true),
      );
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _pushTimer?.cancel();
    _pushTimer = null;
    _client.close();
  }

  String get _defaultDeviceName {
    if (kIsWeb) return 'Web browser';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android device',
      TargetPlatform.iOS => 'iOS device',
      TargetPlatform.macOS => 'macOS device',
      TargetPlatform.windows => 'Windows device',
      TargetPlatform.linux => 'Linux device',
      TargetPlatform.fuchsia => 'Device',
    };
  }
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}
