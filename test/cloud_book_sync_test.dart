import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/services/books/book_dao.dart';
import 'package:xxread/services/books/book_import_service.dart';
import 'package:xxread/services/sync/cloud_book_service.dart';
import 'package:xxread/services/sync/reading_progress_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late Database database;
  late BookDao bookDao;
  late BookImportService importer;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('cloud-book-sync-');
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await _createSchema(database);
    bookDao = BookDao(
      database: () async => database,
      documentsDirectory: () async => sandbox,
    );
    importer = BookImportService(
      store: bookDao,
      documentsDirectory: () async => sandbox,
    );
  });

  tearDown(() async {
    await database.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('lists cloud books with the configured user and token', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/users/alice/books');
      expect(request.headers['Authorization'], 'Bearer secret');
      return _jsonResponse({
        'books': [
          _recordJson('a' * 32, 'First'),
          _recordJson('b' * 32, 'Second'),
        ],
        'usageBytes': 2048,
        'quotaBytes': 1024 * 1024,
      });
    });
    final service = CloudBookService(client: client);
    addTearDown(service.dispose);

    final books = await service.listBooks(_config());

    expect(books, hasLength(2));
    expect(books.first.title, 'First');
    expect(books.first.sizeBytes, 512);
    expect(books.first.format, 'txt');
  });

  test('uploads a local file with its content hash', () async {
    final bytes = utf8.encode('Chapter one.\n\nHello cloud shelf.');
    final hash = md5.convert(bytes).toString();
    final file = File(p.join(sandbox.path, 'upload.txt'));
    await file.writeAsBytes(bytes);

    var uploaded = false;
    final client = MockClient((request) async {
      expect(request.method, 'PUT');
      expect(request.url.path, '/v1/users/alice/books/$hash');
      expect(request.url.queryParameters['title'], 'Upload book');
      expect(request.url.queryParameters['author'], 'Author');
      expect(request.url.queryParameters['format'], 'txt');
      expect(request.headers['Authorization'], 'Bearer secret');
      expect(request.bodyBytes, bytes);
      uploaded = true;
      return _jsonResponse({'book': _recordJson(hash, 'Upload book')}, 201);
    });
    final service = CloudBookService(client: client);
    addTearDown(service.dispose);

    final result = await service.uploadBook(
      Book(
        title: 'Upload book',
        author: 'Author',
        filePath: file.path,
        format: 'TXT',
      ),
      _config(),
    );

    expect(uploaded, isTrue);
    expect(result.created, isTrue);
    expect(result.record.bookKey, hash);
    expect(result.record.title, 'Upload book');
  });

  test('downloads a book, verifies its hash and imports it', () async {
    final bytes = utf8.encode('Chapter one.\n\nDownloaded text.');
    final hash = md5.convert(bytes).toString();
    final record = CloudBookRecord(
      bookKey: hash,
      title: 'Downloaded',
      author: 'Author',
      format: 'txt',
      sizeBytes: bytes.length,
      uploadedAt: 1,
      updatedAt: 1,
    );
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/users/alice/books/$hash');
      return http.Response.bytes(
        bytes,
        200,
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'content-length': '${bytes.length}',
        },
      );
    });
    final downloads = Directory(p.join(sandbox.path, 'downloads'));
    final service = CloudBookService(
      client: client,
      importer: importer,
      temporaryDirectory: () async => downloads,
    );
    addTearDown(service.dispose);

    final book = await service.downloadBook(record, _config());

    expect(book.title, 'Downloaded');
    expect(book.contentHash, hash);
    expect(await File(book.filePath).exists(), isTrue);
    expect((await bookDao.getAllBooks()).single.contentHash, hash);
    final leftovers = await downloads
        .list()
        .where((entity) => entity.path.contains('cloud_'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('rejects a download whose bytes do not match the cloud hash', () async {
    final bytes = utf8.encode('Tampered content.');
    final record = CloudBookRecord(
      bookKey: 'c' * 32,
      title: 'Broken',
      author: 'Author',
      format: 'txt',
      sizeBytes: bytes.length,
      uploadedAt: 1,
      updatedAt: 1,
    );
    final client = MockClient((request) async {
      return http.Response.bytes(
        bytes,
        200,
        headers: {'content-length': '${bytes.length}'},
      );
    });
    final service = CloudBookService(
      client: client,
      importer: importer,
      temporaryDirectory: () async =>
          Directory(p.join(sandbox.path, 'downloads')),
    );
    addTearDown(service.dispose);

    await expectLater(
      service.downloadBook(record, _config()),
      throwsA(
        isA<CloudBookException>().having(
          (error) => error.code,
          'code',
          'hash_mismatch',
        ),
      ),
    );
    expect(await bookDao.getAllBooks(), isEmpty);
  });

  test('resolves the book key from a stored content hash', () async {
    final service = CloudBookService(
      client: MockClient((_) async => throw StateError('no request expected')),
    );
    addTearDown(service.dispose);

    final key = await service.resolveBookKey(
      Book(
        title: 'Hashed',
        filePath: p.join(sandbox.path, 'missing.txt'),
        format: 'txt',
        contentHash: 'ABCDEF0123456789ABCDEF0123456789',
      ),
    );

    expect(key, 'abcdef0123456789abcdef0123456789');
  });

  test(
    'cloud library sync uploads missing books and keeps hashes for progress',
    () async {
      final sharedBytes = utf8.encode('Already in the cloud.');
      final sharedHash = md5.convert(sharedBytes).toString();
      final newBytes = utf8.encode('Upload this local book.');
      final newHash = md5.convert(newBytes).toString();
      final legacyBytes = utf8.encode('Legacy book without a hash.');
      final legacyHash = md5.convert(legacyBytes).toString();

      final sharedFile = File(p.join(sandbox.path, 'shared.txt'));
      await sharedFile.writeAsBytes(sharedBytes);
      final newFile = File(p.join(sandbox.path, 'new.txt'));
      await newFile.writeAsBytes(newBytes);
      final legacyFile = File(p.join(sandbox.path, 'legacy.txt'));
      await legacyFile.writeAsBytes(legacyBytes);

      await bookDao.insertBook(
        Book(
          title: 'Shared',
          author: 'Author',
          filePath: sharedFile.path,
          format: 'TXT',
          currentPage: 5,
          totalPages: 10,
          readingProgress: 0.5,
          contentHash: sharedHash,
        ),
      );
      await bookDao.insertBook(
        Book(
          title: 'New',
          author: 'Author',
          filePath: newFile.path,
          format: 'TXT',
          currentPage: 2,
          totalPages: 10,
          readingProgress: 0.2,
          contentHash: newHash,
        ),
      );
      final legacyId = await bookDao.insertBook(
        Book(
          title: 'Legacy',
          author: 'Author',
          filePath: legacyFile.path,
          format: 'TXT',
        ),
      );

      SharedPreferences.setMockInitialValues({
        ReadingProgressSyncService.enabledPreferenceKey: true,
        ReadingProgressSyncService.booksEnabledPreferenceKey: true,
        ReadingProgressSyncService.serverUrlPreferenceKey: 'http://sync.test',
        ReadingProgressSyncService.userIdPreferenceKey: 'alice',
        ReadingProgressSyncService.tokenPreferenceKey: 'secret',
        ReadingProgressSyncService.deviceIdPreferenceKey: 'device-1',
        ReadingProgressSyncService.deviceNamePreferenceKey: 'Test device',
      });

      final cloudRecords = <String, Map<String, dynamic>>{
        sharedHash: _recordJson(sharedHash, 'Shared'),
      };
      final uploadedKeys = <String>[];
      final progressPuts = <String>[];
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer secret');
        final segments = request.url.pathSegments;
        if (segments.length == 4 && segments[3] == 'books') {
          return _jsonResponse({
            'books': cloudRecords.values.toList(),
            'usageBytes': 1024,
            'quotaBytes': 10 * 1024 * 1024,
          });
        }
        if (segments.length == 5 && segments[3] == 'books') {
          final key = segments[4];
          uploadedKeys.add(key);
          cloudRecords[key] = _recordJson(
            key,
            request.url.queryParameters['title'] ?? 'Uploaded',
          );
          return _jsonResponse({'book': cloudRecords[key]}, 201);
        }
        if (segments.length == 5 && segments[3] == 'progress') {
          progressPuts.add(segments[4]);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return _jsonResponse({
            'record': {...body, 'updatedAt': 1000}..remove('baseUpdatedAt'),
          });
        }
        if (segments.length == 4 && segments[3] == 'progress') {
          return _jsonResponse({'records': [], 'serverTime': 1000});
        }
        throw StateError('unexpected ${request.method} ${request.url}');
      });
      final books = CloudBookService(client: client);
      final progress = ReadingProgressSyncService(
        bookDao: bookDao,
        client: client,
        pushDebounce: const Duration(hours: 1),
      );
      final sync = CloudLibrarySync(
        bookDao: bookDao,
        bookService: books,
        progressService: progress,
      );
      addTearDown(books.dispose);
      addTearDown(progress.dispose);

      final result = await sync.syncNow();

      expect(result.status, CloudLibrarySyncStatus.success);
      expect(result.uploaded, 2);
      expect(result.failed, 0);
      expect(result.shelf.keys, containsAll([sharedHash, newHash, legacyHash]));
      expect(uploadedKeys.toSet(), {newHash, legacyHash});
      expect(progressPuts.toSet(), {'hash:$sharedHash', 'hash:$newHash'});
      expect((await bookDao.getBookById(legacyId))?.contentHash, legacyHash);

      final second = await sync.syncNow();
      expect(second.uploaded, 0);
      expect(second.status, CloudLibrarySyncStatus.success);
    },
  );

  test('merges local and cloud books without duplicating legacy rows', () {
    const hashA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const hashB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final localA = Book(
      id: 1,
      title: 'Matched',
      author: 'Author',
      filePath: 'a.txt',
      format: 'TXT',
      contentHash: hashA,
    );
    final legacy = Book(
      id: 2,
      title: 'Legacy match',
      author: 'Author',
      filePath: 'legacy.txt',
      format: 'TXT',
    );
    final cloudOnly = CloudBookRecord(
      bookKey: hashB,
      title: 'Cloud only',
      author: 'Author',
      format: 'txt',
      sizeBytes: 10,
      uploadedAt: 50,
      updatedAt: 50,
    );

    final entries = mergeCloudShelf(
      localBooks: [localA, legacy],
      cloudBooks: [
        CloudBookRecord(
          bookKey: hashA,
          title: 'Matched',
          author: 'Author',
          format: 'txt',
          sizeBytes: 10,
          uploadedAt: 10,
          updatedAt: 10,
        ),
        CloudBookRecord(
          bookKey: 'cccccccccccccccccccccccccccccccc',
          title: 'Legacy match',
          author: 'Author',
          format: 'txt',
          sizeBytes: 10,
          uploadedAt: 20,
          updatedAt: 20,
        ),
        cloudOnly,
      ],
    );

    expect(entries, hasLength(3));
    expect(entries[0].local, localA);
    expect(entries[0].cloud?.bookKey, hashA);
    expect(entries[1].local, legacy);
    expect(entries[1].cloud?.title, 'Legacy match');
    expect(entries[2].isCloudOnly, isTrue);
    expect(entries[2].cloud?.bookKey, hashB);
  });
}

ReadingProgressSyncConfig _config() => const ReadingProgressSyncConfig(
  enabled: true,
  booksEnabled: true,
  serverUrl: 'http://sync.test/',
  userId: 'alice',
  token: 'secret',
  deviceId: 'device-1',
  deviceName: 'Test device',
);

Map<String, dynamic> _recordJson(String key, String title) => {
  'bookKey': key,
  'title': title,
  'author': 'Author',
  'format': 'txt',
  'sizeBytes': 512,
  'uploadedAt': 1,
  'updatedAt': 1,
};

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
