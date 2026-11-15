import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/models/reading_progress_sync.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/sync/reading_progress_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late Database database;
  late BookDao bookDao;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('progress-sync-');
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await _createSchema(database);
    bookDao = BookDao(
      database: () async => database,
      documentsDirectory: () async => sandbox,
    );
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await database.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('book keys prefer content hashes and stay stable without one', () {
    final hashed = Book(
      title: 'Shared',
      filePath: 'shared.txt',
      format: 'txt',
      contentHash: 'abc123',
    );
    expect(readingProgressBookKey(hashed), 'hash:abc123');

    final first = Book(
      title: 'Metadata only',
      author: 'Same author',
      filePath: 'one.txt',
      format: 'txt',
    );
    final second = Book(
      title: 'Metadata only',
      author: 'Same author',
      filePath: 'two.txt',
      format: 'txt',
    );
    expect(readingProgressBookKey(first), readingProgressBookKey(second));
    expect(readingProgressBookKey(first), startsWith('meta:'));
  });

  test('record round-trips and does not send a client updatedAt', () {
    final record = ReadingProgressRecord.fromBook(
      Book(
        title: 'Round trip',
        author: 'Author',
        filePath: 'round.txt',
        format: 'txt',
        currentPage: 4,
        totalPages: 10,
        readingProgress: 0.4,
        contentHash: 'hash',
        lastCanonicalLocator: '{"version":1}',
      ),
      bookKey: 'hash:hash',
      deviceId: 'device-1',
      deviceName: 'Test',
    );
    final restored = ReadingProgressRecord.fromJson({
      ...record.toPushJson(baseUpdatedAt: 12),
      'updatedAt': 99,
    });
    expect(restored.bookKey, 'hash:hash');
    expect(restored.currentPage, 4);
    expect(restored.readingProgress, 0.4);
    expect(record.toPushJson(baseUpdatedAt: 12)['baseUpdatedAt'], 12);
    expect(record.toPushJson()['updatedAt'], isNull);
  });

  test(
    'sync uploads local progress then applies a newer server record',
    () async {
      final localId = await bookDao.insertBook(
        Book(
          title: 'Shared progress',
          author: 'Author',
          filePath: 'shared.txt',
          format: 'txt',
          currentPage: 3,
          totalPages: 10,
          readingProgress: 0.3,
          contentHash: 'abc',
        ),
      );

      SharedPreferences.setMockInitialValues({
        ReadingProgressSyncService.enabledPreferenceKey: true,
        ReadingProgressSyncService.serverUrlPreferenceKey: 'http://sync.test/',
        ReadingProgressSyncService.userIdPreferenceKey: 'alice',
        ReadingProgressSyncService.tokenPreferenceKey: 'secret',
        ReadingProgressSyncService.deviceIdPreferenceKey: 'device-1',
        ReadingProgressSyncService.deviceNamePreferenceKey: 'Test device',
      });

      var remoteRecords = <Map<String, dynamic>>[];
      final putBodies = <Map<String, dynamic>>[];
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer secret');
        if (request.method == 'GET') {
          return _jsonResponse({'records': remoteRecords, 'serverTime': 10});
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        putBodies.add(body);
        return _jsonResponse({
          'record': {...body, 'updatedAt': 1000}..remove('baseUpdatedAt'),
          'serverTime': 1000,
        });
      });

      final service = ReadingProgressSyncService(
        bookDao: bookDao,
        client: client,
        pushDebounce: const Duration(hours: 1),
      );
      addTearDown(service.dispose);

      final first = await service.syncNow();
      expect(first.status, ReadingProgressSyncStatus.success);
      expect(first.pushed, 1);
      expect(first.pulled, 0);
      expect(putBodies.single['bookKey'], 'hash:abc');
      expect(putBodies.single['baseUpdatedAt'], isNull);
      expect(putBodies.single['updatedAt'], isNull);

      remoteRecords = [
        {
          'bookKey': 'hash:abc',
          'title': 'Shared progress',
          'author': 'Author',
          'format': 'txt',
          'contentHash': 'abc',
          'currentPage': 8,
          'totalPages': 10,
          'readingProgress': 0.8,
          'canonicalLocator': '{"version":1,"chapterId":"two"}',
          'chapterIndex': 8,
          'updatedAt': 2000,
        },
      ];

      final second = await service.syncNow();
      expect(second.status, ReadingProgressSyncStatus.success);
      expect(second.pushed, 0);
      expect(second.pulled, 1);

      final stored = await bookDao.getBookById(localId);
      expect(stored?.currentPage, 8);
      expect(stored?.readingProgress, 0.8);
      expect(stored?.lastCanonicalLocator, contains('"two"'));
      expect(stored?.lastRenderedLocator, isNull);
    },
  );

  test('local dirty position retries against a server conflict', () async {
    final localId = await bookDao.insertBook(
      Book(
        title: 'Conflict book',
        author: 'Author',
        filePath: 'conflict.txt',
        format: 'txt',
        currentPage: 5,
        totalPages: 10,
        readingProgress: 0.5,
        contentHash: 'conflict',
      ),
    );
    SharedPreferences.setMockInitialValues({
      ReadingProgressSyncService.enabledPreferenceKey: true,
      ReadingProgressSyncService.serverUrlPreferenceKey: 'http://sync.test',
      ReadingProgressSyncService.userIdPreferenceKey: 'alice',
      ReadingProgressSyncService.deviceIdPreferenceKey: 'device-1',
    });

    var remote = <String, dynamic>{
      'bookKey': 'hash:conflict',
      'title': 'Conflict book',
      'author': 'Author',
      'format': 'txt',
      'contentHash': 'conflict',
      'currentPage': 2,
      'totalPages': 10,
      'readingProgress': 0.2,
      'updatedAt': 5000,
    };
    var putCount = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return _jsonResponse({
          'records': [remote],
          'serverTime': 5000,
        });
      }
      putCount++;
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (putCount == 1) {
        return _jsonResponse({'error': 'conflict', 'record': remote}, 409);
      }
      expect(body['baseUpdatedAt'], 5000);
      final updated = {...body, 'updatedAt': 6000}..remove('baseUpdatedAt');
      remote = Map<String, dynamic>.from(updated);
      return _jsonResponse({'record': updated, 'serverTime': 6000});
    });

    final service = ReadingProgressSyncService(
      bookDao: bookDao,
      client: client,
      pushDebounce: const Duration(hours: 1),
    );
    addTearDown(service.dispose);

    final storedBefore = await bookDao.getBookById(localId);
    await service.noteLocalProgressSaved(storedBefore!);
    final result = await service.syncNow();

    expect(result.status, ReadingProgressSyncStatus.success);
    expect(putCount, 2);
    expect(result.pushed, 1);
    expect(result.pulled, 0);
    final stored = await bookDao.getBookById(localId);
    expect(stored?.currentPage, 5);
    expect(stored?.readingProgress, 0.5);
  });
}

http.Response _jsonResponse(Map<String, dynamic> body, [int status = 200]) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<void> _createSchema(Database database) async {
  await database.execute('''
    CREATE TABLE books(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      author TEXT NOT NULL DEFAULT 'Unknown',
      filePath TEXT NOT NULL,
      format TEXT NOT NULL,
      currentPage INTEGER NOT NULL DEFAULT 0,
      totalPages INTEGER NOT NULL DEFAULT 1,
      reading_progress REAL,
      importDate INTEGER NOT NULL,
      cached_content TEXT,
      cached_pages TEXT,
      file_modified_time INTEGER,
      content_hash TEXT UNIQUE,
      table_of_contents TEXT,
      cover_image_path TEXT,
      text_encoding TEXT,
      last_canonical_locator TEXT,
      last_rendered_locator TEXT,
      layout_signature TEXT
    )
  ''');
}
