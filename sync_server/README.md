# Self-hosted progress sync server

This optional server stores only reading positions for the Origo X local
reader. It does not receive book files, notes or reading statistics.

## Run

```sh
dart run sync_server/bin/server.dart
```

Environment variables:

| Variable         | Default                           | Purpose                              |
| ---------------- | --------------------------------- | ------------------------------------ |
| `HOST`           | `0.0.0.0`                         | Bind address                         |
| `PORT`           | `8787`                            | Bind port                            |
| `SYNC_DATA_FILE` | `sync_server/data/progress.json`  | JSON storage file                    |
| `SYNC_TOKEN`     | unset                             | Optional bearer token for `/v1` APIs |

Example:

```sh
SYNC_TOKEN=change-me PORT=8787 dart run sync_server/bin/server.dart
```

For access from phones use a LAN address such as
`http://192.168.1.10:8787`, and put the server behind a TLS reverse proxy if it
is reachable from the internet. The bundled server has no user authentication;
the optional token is shared by all clients pointed at the same server.

## API

- `GET /health`
- `GET /v1/users/{userId}/progress`
- `PUT /v1/users/{userId}/progress/{bookKey}`

`PUT` bodies may include `baseUpdatedAt`, the `updatedAt` value the client last
saw. When it does not match the stored revision the server responds with
`409 Conflict` and the current record, letting the client pull before retrying.
The server assigns `updatedAt` on every accepted write. If this device has an
unsynced local position, the client keeps that position and retries once
against the server's latest revision; otherwise the server record is applied.

## Client setup

Open the local library in the app, tap the cloud-sync icon, enter the server
URL and a user ID (for example `family`), then choose **Save and sync**. Every
device that uses the same server URL and user ID shares reading positions for
books with matching content hashes.

The feature is disabled by default and works entirely offline until enabled.
