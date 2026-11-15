import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xxread/models/book.dart';
import 'package:xxread/pages/local_library_page.dart';
import 'package:xxread/services/sync/cloud_book_service.dart';
import 'package:xxread/services/sync/reading_progress_sync_service.dart';

void main() {
  testWidgets('local library filters books and opens the selected local book', (
    tester,
  ) async {
    final books = [
      Book(
        id: 1,
        title: 'A local story',
        author: 'Alex',
        filePath: 'story.txt',
        format: 'txt',
      ),
      Book(
        id: 2,
        title: 'Another book',
        author: 'Sam',
        filePath: 'book.epub',
        format: 'epub',
      ),
    ];
    Book? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalLibraryPage(
          booksLoader: () async => books,
          onOpenBook: (book) async => opened = book,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('A local story'), findsOneWidget);
    expect(find.text('Another book'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'alex');
    await tester.pump();
    expect(find.text('A local story'), findsOneWidget);
    expect(find.text('Another book'), findsNothing);
    await tester.tap(find.text('A local story'));
    await tester.pumpAndSettle();
    expect(opened?.id, 1);
  });

  testWidgets('import action refreshes the local library', (tester) async {
    final books = <Book>[];
    await tester.pumpWidget(
      MaterialApp(
        home: LocalLibraryPage(
          booksLoader: () async => List.of(books),
          onImport: () async => books.add(
            Book(
              id: 1,
              title: 'Imported',
              filePath: 'imported.txt',
              format: 'txt',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import TXT / EPUB'));
    await tester.pumpAndSettle();
    expect(find.text('Imported'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });

  testWidgets('cloud mode lists remote books and downloads on tap', (
    tester,
  ) async {
    final local = Book(
      id: 1,
      title: 'Local story',
      author: 'Alex',
      filePath: 'local.txt',
      format: 'TXT',
      contentHash: 'a' * 32,
    );
    final record = CloudBookRecord(
      bookKey: 'b' * 32,
      title: 'Cloud story',
      author: 'Sam',
      format: 'txt',
      sizeBytes: 1024,
      uploadedAt: 1,
      updatedAt: 1,
    );
    final cloudBooks = _FakeCloudBookService(
      CloudShelf(books: [record], usageBytes: 1024, quotaBytes: 1024 * 1024),
    );
    Book? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: LocalLibraryPage(
          booksLoader: () async => [local],
          cloudSync: _FakeCloudSync(
            config: const ReadingProgressSyncConfig(
              enabled: true,
              booksEnabled: true,
              serverUrl: 'http://sync.test',
              userId: 'alice',
              token: 'secret',
              deviceId: 'device-1',
              deviceName: 'Test device',
            ),
            shelf: CloudShelf(
              books: [record],
              usageBytes: 1024,
              quotaBytes: 1024 * 1024,
            ),
          ),
          cloudBookService: cloudBooks,
          progressSyncService: _FakeProgressSync(),
          onOpenBook: (book) async => opened = book,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cloud book mode'), findsOneWidget);
    expect(find.text('Local story'), findsOneWidget);
    expect(find.text('Cloud story'), findsOneWidget);

    await tester.tap(find.text('Cloud story'));
    await tester.pumpAndSettle();

    expect(cloudBooks.downloaded?.title, 'Cloud story');
    expect(opened?.title, 'Cloud story');
  });
}

class _FakeCloudSync extends CloudLibrarySync {
  _FakeCloudSync({required this.config, required this.shelf});

  final ReadingProgressSyncConfig config;
  final CloudShelf shelf;

  @override
  Future<ReadingProgressSyncConfig> loadConfig() async => config;

  @override
  Future<CloudLibrarySyncResult> syncNow({
    void Function(CloudLibrarySyncProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      const CloudLibrarySyncProgress(phase: CloudLibrarySyncPhase.listing),
    );
    return CloudLibrarySyncResult(
      status: CloudLibrarySyncStatus.success,
      shelf: shelf,
      shelfLoaded: true,
      progressResult: const ReadingProgressSyncResult(
        status: ReadingProgressSyncStatus.success,
      ),
      syncedAt: DateTime.now(),
    );
  }
}

class _FakeCloudBookService extends CloudBookService {
  _FakeCloudBookService(this.shelf);

  final CloudShelf shelf;
  Book? downloaded;

  @override
  Future<CloudShelf> listShelf(ReadingProgressSyncConfig config) async => shelf;

  @override
  Future<Book> downloadBook(
    CloudBookRecord record,
    ReadingProgressSyncConfig config, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(1);
    final book = Book(
      title: record.title,
      author: record.author,
      filePath: 'cloud.txt',
      format: record.format,
    );
    downloaded = book;
    return book;
  }
}

class _FakeProgressSync extends ReadingProgressSyncService {
  @override
  Future<ReadingProgressSyncResult> syncNow() async =>
      const ReadingProgressSyncResult(
        status: ReadingProgressSyncStatus.success,
      );
}
