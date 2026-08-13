# 105. Upload-Phase Token Refresh for Drive Attachments

Date: 2026-08-13

## Status

Proposed

## Reference

Builds on [ADR-0103](0103-attach-drive-file-as-attachment.md), which left the web+OPFS upload leg not refresh-and-retry safe.

## Context

The download leg uses a public, unauthenticated `downloadLink`.
The upload leg uses the app's own session token.

A batch of large drive files can outlive the access token's TTL, so a 401 mid-upload is expected, not exotic.
Where it lands depends on the strategy:

| Upload path | Transport | 401 today |
|---|---|---|
| IO `FileBackedStagedFile` | `FileUploader` → worker isolate → `DioClient` | Refreshed and retried by `AuthorizationInterceptors`; body rebuilt from `filePathExtraKey`. No change needed. |
| Web buffered `BytesStagedFile` | `FileUploader` main isolate → `DioClient` | Same; body rebuilt from `streamDataExtraKey`, a second `BodyBytesStream` instance, so the replay has an unconsumed stream. No change needed. |
| Web + OPFS `OpfsStagedFile` | raw `XMLHttpRequest` (`opfs_xhr_upload.dart`) | Bypasses every interceptor. Header read once at transfer start; the chip is dropped. **This ADR.** |

So the work is one new capability on the interceptor, plus its use from the single path that cannot reach Dio.
Not a second refresh implementation.

## Decision

### `ensureFreshAuthorizationHeader({bool forceRefresh = false})`

The app's only non-Dio auth entry point.

The refresh chain is private:
`_refreshTokenThenRetry` → `_getNewTokenForIOSPlatform`/`_getNewTokenForOtherPlatform` → `_invokeRefreshTokenFromServer` → `_updateNewToken` → `_updateCurrentAccount`.

Every part of it — iOS keychain lookup, token persistence, account-cache update, error classification — must apply identically off-Dio.
So the new API composes those members instead of forking a parallel path.

Three rules it holds to:

- **Expiry is `_isTokenExpired`, never `TokenOIDC.isTokenValid()`.**
  That getter only asserts non-empty fields, so a check written against it would never refresh anything.
- **Non-OIDC short-circuits before touching `_configOIDC`.**
  Under `basic` and `none` it is null, and the `!` inside the refresh chain would throw on every drive upload against the Basic-auth backend.
- **A missing refresh token is not a refresh.**
  Return the current header and let the server's 401 decide — the same gate `validateToRefreshToken` already applies on the Dio path.

### Single-flight refresh, shared with the Dio path

Today's dedup is a side effect of `QueuedInterceptorsWrapper` queueing concurrent `onError` calls.
It does not extend one inch past Dio.

Up to three concurrent OPFS uploads refreshing on their own — possibly alongside a Dio 401 — would issue parallel token requests with the same refresh token.
Against a provider with refresh-token rotation, the first response rotates it and the rest come back `invalid_grant` → `clear()` → the user is logged out mid-attach.

So a `_refreshTokenOnce()` memo lives on the interceptor: assign-before-await, cleared in `whenComplete`.
`_refreshTokenThenRetry` is refactored to call it, coalescing Dio-originated and drive-originated refreshes into one token request.

A post-`clear()` guard re-checks the auth type after the await and discards the new token.
Otherwise a refresh resolving after logout resurrects a dead session and re-persists it.

### Injection as `ResolveAuthHeader`, not a `String`

`workplace` cannot depend on the main app, so the refresher is passed in the way `StagedFileUploader` already is:

```dart
typedef ResolveAuthHeader = Future<String?> Function({bool forceRefresh});
```

It replaces the `String authHeader` on the transfer and upload request types.
`DriveTransferPipeline` passes the function through instead of resolving eagerly.

That also closes a bug the `String` shape made invisible.
The header is resolved at *transfer* start today — before a download that can run for minutes — so it can be stale even when no token ever expired.
Resolving inside the uploader, immediately before `xhr.send`, makes the 401 path a rare fallback rather than the primary mechanism.

### Retry-once in the OPFS uploader

The staged file is still on OPFS, and the strategy still owns its `dispose()` in a `finally`.
So a replay costs no re-download and leaks nothing.

On a 401 with the retry unused:

1. Check cancellation first — a cancel during the refresh gap must stay a cancel, not become an auth error.
2. `resolveAuthHeader(forceRefresh: true)`.
3. Resend the same `web.File` once.

A second 401 fails the file normally.
The bound is a local flag, never a loop, so a broken server cannot hold the chip forever.

When the refresh itself is rejected, `ensureFreshAuthorizationHeader` clears the session and throws `RefreshTokenFailedException` — the contract `onError` already has.
The resolver closure injected by `ComposerController` catches it, calls `handleRefreshTokenFailedException()` (saving the draft and reconnecting), and rethrows, so the chip fails like any other.

Session lifecycle never crosses into `workplace`; the only thing crossing the boundary is a `Future<String?>`.

## Consequences

- One refresh implementation for the whole app, reached from Dio and non-Dio callers alike.
  No duplicated platform, keychain, or persistence logic.
- IO and web-buffered uploads gain no new code and behave exactly as before.
- The header is as fresh as it can be at send time, so 401-driven replay is the exception, not the mechanism.
- `UploadController.updateUploadProgress` becomes monotonic (`max(current, mapped)`).
  A replay restarts `sent` at 0 and would otherwise snap the bar back to the midpoint; ADR-0103's one-bar-two-halves contract then holds across retries too.

## Risks

- Multi-tab refresh coordination is unchanged and out of scope.
  The memo is per-isolate, and two tabs each holding a rotated refresh token is a pre-existing, app-wide condition.
- A second consecutive 401 fails that file; the user re-picks it.
- `xhr.timeout` stays unset, so a stalled upload still relies on cancel.
