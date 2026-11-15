# Self-hosted sync server

This optional server stores reading positions and, when the user enables the
cloud shelf, whole TXT/EPUB book files for the Origo X local reader. Notes,
bookmarks and reading statistics are never uploaded.

## Run

Run from the repository root after `flutter pub get`, so the `crypto` package
used for upload verification is available:

```sh
dart run sync_server/bin/server.dart
```

For a standalone binary:

```sh
dart compile exe sync_server/bin/server.dart -o sync_server/build/origo-sync.exe
```

The compiled binary embeds its dependencies and can be copied to another
machine.

## Environment variables

| Variable             | Default                            | Purpose                                            |
| -------------------- | ---------------------------------- | -------------------------------------------------- |
| `HOST`               | `0.0.0.0`                          | Bind address                                       |
| `PORT`               | `8787`                             | Bind port                                          |
| `SYNC_DATA_FILE`     | `sync_server/data/progress.json`   | Reading-position JSON file                         |
| `SYNC_BOOKS_DIR`     | `<data dir>/books`                 | Book blob directory                                |
| `SYNC_BOOKS_INDEX`   | `<data dir>/books.json`            | Book metadata index                                |
| `SYNC_MAX_BOOK_MB`   | `500`                              | Maximum size of one uploaded book                  |
| `SYNC_USER_QUOTA_MB` | `5120`                             | Per-user book storage quota (5 GiB)                |
| `SYNC_USERS`         | unset                              | Per-user tokens: `alice:token1,bob:token2`         |
| `SYNC_TOKEN`         | unset                              | Shared token when `SYNC_USERS` is unset            |

When `SYNC_USERS` is set, a token only grants access to its own user namespace;
`alice` cannot read or write `bob`'s data. Keep `SYNC_TOKEN` unset in that mode.
If neither variable is set, the server accepts any request on the local network.
User IDs may contain letters, digits, `.`, `_` and `-` (including non-ASCII
letters such as `书友`); IDs that look like paths are rejected.

Example:

```sh
SYNC_USERS="alice:change-me,bob:another-secret" PORT=8787 \
  dart run sync_server/bin/server.dart
```

For access from phones use a LAN address such as `http://192.168.1.10:8787`, and
put the server behind a TLS reverse proxy if it is reachable from the internet.
The bundled server has no user registration or account service; tokens are
configured by the operator.

## Data layout

```text
sync_server/data/
  progress.json              # reading positions, one document per user
  books.json                 # cloud book metadata
  books/<userId>/<hash>.txt  # book blobs, named by content hash
  books/<userId>/<hash>.epub
```

Uploads are streamed to a temporary file, hashed with MD5 (the same content hash
the app uses for local imports), and only committed when the hash matches the
requested book key. The metadata index is replaced atomically. Book files are
overwritten in place when the same hash is uploaded again and removed with the
metadata when a book is deleted.

## API

### Health

- `GET /health` — no token required.

### Reading positions

- `GET /v1/users/{userId}/progress`
- `PUT /v1/users/{userId}/progress/{bookKey}`

`PUT` bodies may include `baseUpdatedAt`, the `updatedAt` value the client last
saw. When it does not match the stored revision the server responds with
`409 Conflict` and the current record, letting the client pull before retrying.
The server assigns `updatedAt` on every accepted write.

### Book files

- `GET /v1/users/{userId}/books` — metadata list plus `usageBytes`/`quotaBytes`.
- `GET /v1/users/{userId}/books/{bookKey}` — download; supports `Range` and
  `ETag`/`If-None-Match`.
- `HEAD /v1/users/{userId}/books/{bookKey}` — size and headers only.
- `PUT /v1/users/{userId}/books/{bookKey}?title=...&author=...&format=txt`
  — upload raw bytes. `bookKey` is the lowercase MD5 of the body. Accepted
  formats are `txt` and `epub`.
- `DELETE /v1/users/{userId}/books/{bookKey}` — remove the file and metadata.

Example upload:

```sh
curl --fail-with-body -X PUT \
  "http://127.0.0.1:8787/v1/users/alice/books/$(md5sum book.epub | cut -d' ' -f1)?title=My%20Book&author=Author&format=epub" \
  -H "Authorization: Bearer change-me" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @book.epub
```

Errors use a stable `error` code such as `unauthorized`, `hash_mismatch`,
`book_too_large`, `quota_exceeded`, `unsupported_format` or `book_not_found`.

## Client setup

Open the local library in the app, tap the cloud-sync icon, enter the server URL,
a user ID (for example `family`) and the matching token, then save. Enable
**Cloud book mode** to give the library a server-backed shelf: every time it
opens it uploads the local TXT/EPUB files and reading positions that are
missing from the server, lists the books already stored there, and downloads a
cloud-only book the first time you open it. Every device that uses the same
server URL, user ID and token shares positions and book files for books with
matching content hashes. The cloud-shelf icon offers manual upload, download and
delete, plus a bulk upload action when an earlier transfer failed.

The feature is disabled by default and works entirely offline until enabled.
Without **Cloud book mode**, only reading positions are exchanged and no book
file leaves the device.

## Operations

- Run one server process per data directory. The stores keep state in memory and
  persist through atomic file replacement.
- Back up the whole data directory; `progress.json` and `books.json` are not
  enough to restore downloads because the blobs live under `books/`.
- Give `SYNC_DATA_FILE`, `SYNC_BOOKS_DIR` and `SYNC_BOOKS_INDEX` absolute paths
  when running as a Windows service; the working directory is not the repo.
- Use HTTPS and strong per-user tokens before exposing the server outside a
  trusted network. The server does not implement rate limiting or virus
  scanning; only upload books you trust.
