# 真果鉴 / 红果鉴 — Persistence, Library, Users, Settings, Cache Layer

**Target:** `/Users/kurisu/project/drama/reference/hongguo` (Flutter app + Go native core)
**Go core:** `native/core` — 132 `.go` files, 27,699 lines (`native/go.mod`, module `duanjuapp/native`, Go 1.24.1)
**Dart app:** `lib/` — the entire user/permission library layer lives here, not in Go
**Snapshot:** version `0.2.73+88` (`native/core/app_runtime.go:356` returns `"version": "0.2.17"` for the core ABI; README says app `0.2.73+88`)

---

## 0. Executive summary — the single most important structural fact

**The Go core has no concept of a user, account, admin, password, or permission.**
A grep for `profile|account|password|admin|bcrypt|argon2` over `native/core/*.go` returns only:
`network_browser.go` (TLS fingerprint profile `Chrome 150`), `provider_duanju_maccms.go` (`maccmsSourceProfile`, an HTTP header set), and `app_lan.go` (`nativeLANConfig.Account`/`.User`, which are LAN identity strings, not auth).

Consequences for the Rust port:

| Concern | Lives in | Language |
|---|---|---|
| Catalog cache, source records, categories cache, resource settings, cover cache, download index, diagnostics | `native/core` | **Go** |
| Users, admin PIN, per-user source/download permission, per-user library (追剧/history), playback/download/catalog prefs, backup & restore, config-corruption lockout | `lib/local_profiles.dart`, `lib/local_store.dart`, `lib/local_snapshot.dart` | **Dart** |
| LAN record CRDT (`lanRecords`) | `lib/lan_sync_models.dart`, `lib/local_store_sync.dart` | **Dart** |
| Merge queue, media library index | `lib/media_merge_queue.dart`, `lib/media_library.dart` | **Dart** |

So the "persistence, library, users/permissions, settings, cache" layer is **split across two runtimes with two different storage engines**:

* Go core → **files in `getApplicationSupportDirectory()`** (JSON, atomic rename).
* Dart → **`SharedPreferences`** with a *single* JSON blob key `localSnapshot.v1` holding `{"version":1,"values":{...}}`, plus a handful of JSON files in the downloads root.

Both are described below. Sections 1–3, 5, 8–10 are Go. Sections 4, 6, 7 are Dart (with the Go settings sub-layer in §7.1).

---

## 1. Data directory layout

### 1.1 Root directory

Set once by the Dart side at engine init (`lib/core_bridge.dart:643-651`):

```dart
Future<void> initialize() async {
  final directory = await getApplicationSupportDirectory();
  final build = await _call({
    'action': 'initialize',
    'directory': directory.path,
  });
  ...
}
```

Go validates it (`native/core/app_runtime.go:251-257`):

```go
func newNativeEngine(directory string) (*nativeEngine, error) {
    if !filepath.IsAbs(directory) {
        return nil, errors.New("应用数据目录无效")
    }
    if err := os.MkdirAll(directory, 0700); err != nil {
        return nil, err
    }
```

On Android this resolves to `/data/data/<pkg>/files` (Flutter `getApplicationSupportDirectory`). Permission mode **`0700`** for every directory the core creates; **`0600`** for every file.

### 1.2 Complete file inventory

| Path (relative to data dir) | Producer | Format | Size cap | Written when |
|---|---|---|---|---|
| `catalogs.json` | `app_catalog_cache.go:253` | `nativeCatalogDisk`, **v3** | **32 MiB** (`nativeCatalogMaxBytes`) | every catalog page save, detail metadata save, cover address save, category discovery |
| `sources.json` | `app_sources.go:119` | `map[string]nativeSourceRecord` | **4 MiB** (`nativeSourceMaxBytes`) | every source-record mutation |
| `resource-settings.json` | `app_settings.go:156` | `nativeResourceSettings` | 16 KiB **read** limit (`app_settings.go:91`) | admin saves settings |
| `download-location.json` | `app_storage.go:186` | `{"directory": "<abs path>"}` | — | download-directory migration |
| `rankings.json` | `app_rankings.go:56` | `map["<boardId>:<page>"]rankingPage` | **8 MiB** | after each ranking page fetch |
| `huangguo-session.json` | `provider_legacy_session.go:148` | `legacySessionState` | 16 KiB **read** limit | legacy (cloudfront) token refresh |
| `lan-identity.json` | `app_lan.go:116` | `nativeLANIdentity` | 32 KiB **read** limit | first LAN start; self-signed cert |
| `covers-v1/<sha256>.img` | `app_covers.go:174` | raw decoded image bytes | 20 MiB per file, **256 MiB** total, 2000 entries | cover cache fill |
| `covers-v1/.decode-*.hevc` | `app_cover_repair.go:162` | extracted HEVC bitstream | 20 MiB source cap | HEIC cover prep |
| `logs/app.log` | `diagnostics.go:52` | JSONL `diagnosticEvent` | **5 MiB**, 2 rotations | diagnostic events |
| `logs/app.log.1`, `logs/app.log.2` | `diagnostics.go:90-105` | rotated | 5 MiB each | rotation |
| `downloads/` (default) | `app_storage.go:56` | directory | — | first run |
| `downloads/index.json` | `app_downloads.go:206` | `[]nativeDownloadRecord` | **32 MiB** | every download state change |

### 1.3 Downloads directory (separate root)

`nativeDownloadLocation` (`app_storage.go:48-57`):

```go
func nativeDownloadLocation(directory string) string {
    var value struct {
        Directory string `json:"directory"`
    }
    body, _ := os.ReadFile(filepath.Join(directory, "download-location.json"))
    if json.Unmarshal(body, &value) == nil && filepath.IsAbs(value.Directory) {
        return filepath.Clean(value.Directory)
    }
    return filepath.Join(directory, "downloads")
}
```

Layout under the downloads root (`app_downloads.go`, `app_download_collections.go`):

```
<root>/index.json                                  # download index
<root>/merge-queue.json                            # written by Dart (lib/media_merge_queue.dart:201)
<root>/media-library.json                          # written by Dart (lib/media_library.dart:317)
<root>/<jobId>/                                    # when DownloadBySource == false
<root>/<source>/<jobId>/                           # when DownloadBySource == true
    .bundle                                        # 64-hex fingerprint of the media bundle
    media.mp4          OR  index.m3u8 + <sha256-16>.<ext> assets
    media.mp4.json     OR  <asset>.json            # per-file resume metadata
    media.mp4.part     OR  <asset>.part            # in-progress bytes
<root>/exports/<safeTitle> [<source>-<12 hex>]/     # Emby export (Dart)
```

`jobId` is deterministic (`app_downloads.go:72-75`):

```go
func nativeDownloadID(drama string, episode int) string {
    hash := sha256.Sum256([]byte(drama + "\x00" + strconv.Itoa(episode)))
    return hex.EncodeToString(hash[:16])   // 32 hex chars
}
```

HLS asset names are `hex(sha256(url)[:16]) + ext` where ext ∈ `.ts .mp4 .m4s .aac .m4a .vtt .key`, defaulting to `.bin` (`app_download_hls.go:87-95`, `nativeDownloadAssetName`).

### 1.4 JSON schemas

#### `catalogs.json` (v3) — `app_catalog_cache.go:21-28`

```go
type nativeCatalogDisk struct {
    Version         int                                  `json:"version"`          // always 3 on write; loader accepts 2 or 3
    Catalogs        map[string][]nativeDrama             `json:"catalogs"`
    States          map[string]nativeCatalogState        `json:"states"`
    Categories      map[string][]nativeCategory          `json:"categories,omitempty"`
    HongguoApp      *hongguoCatalogState                 `json:"hongguoApp,omitempty"`
    Recommendations map[string]nativeRecommendationState `json:"recommendations,omitempty"`
}
```

`nativeCatalogState` (`app_catalog_cache.go:14-19`):

| Field | Type | Meaning |
|---|---|---|
| `updatedAt` | RFC3339 timestamp | last successful (warning-free) fetch; drives the 15-minute freshness TTL |
| `page` | int | last successfully persisted page cursor, ≥1 |
| `hasMore` | bool | whether more pages exist |
| `warning` | string, omitempty | last fetch error text; non-empty forces `Fresh=false` and `HasMore=true` |

`nativeDrama` (`app_runtime.go:78-94`) — the central persisted record:

| Field | JSON | Type | Meaning |
|---|---|---|---|
| `MetadataSchema` | `metadataSchema` | int | always 1 on write; 0 means pre-migration |
| `ID` | `id` | string | `"<source>:<sourceId>"`, canonical |
| `Source` | `source` | string | canonical source id |
| `SourceID` | `sourceId` | string | provider-native id |
| `Title` | `title` | string | display title; `"短剧"` is treated as unknown in merges |
| `Description` | `description` | string | synopsis |
| `Cover` | `cover` | string | absolute http(s) poster URL |
| `Episodes` | `episodes` | int | episode count (0 = unknown) |
| `Category` | `category` | string | genre label; generic values are deprioritized in merges |
| `VIP` | `vip` | `*bool` | **tri-state**: `null`=unknown, `true`, `false` |
| `Heat` | `heat,omitempty` | string | popularity metric, string-typed |
| `Views` | `views,omitempty` | string | play count |
| `OnlineDate` | `onlineDate,omitempty` | string | `YYYY-MM-DD` (China time) |
| `Tags` | `tags,omitempty` | `[]string` | |
| `ReleaseStatus` | `releaseStatus,omitempty` | string | `finished` / `ongoing` / `unknown` / `""` |

`nativeCategory` (`app_categories.go:15-18`): `{"id": string, "name": string}`. The `"全部"` entry has `id: ""`.

`hongguoCatalogState` (`provider_hongguo_app.go:22-37`) — persisted inside `catalogs.json`:

```go
type hongguoCatalogCursor struct {
    Offset        int       `json:"offset"`
    SessionID     string    `json:"sessionId,omitempty"`
    LastID        string    `json:"lastId,omitempty"`
    PageSignature string    `json:"pageSignature,omitempty"`
    Initialized   bool      `json:"initialized"`
    Exhausted     bool      `json:"exhausted"`
    UpdatedAt     time.Time `json:"updatedAt"`
}
type hongguoCatalogState struct {
    Version   int                             `json:"version"`    // must be 1
    DeviceID  string                          `json:"deviceId"`   // 1-32 digits
    InstallID string                          `json:"installId"`  // 1-32 digits
    Feeds     map[string]hongguoCatalogCursor `json:"feeds"`
}
```

Feed keys are exactly the three genre keys `short_play`, `comic_series`, `ai_series`, and `"category:"+key` for the per-category cursors (`provider_hongguo_catalog.go:48-53`).

`nativeRecommendationState` (`app_recommendations.go:9-13`): `{"query": hongguoRecommendationQuery, "page": int, "hasMore": bool}` where the query is `{"genre","offset","sessionId","seen":[]}` (`provider_hongguo_recommendations.go:11-16`).

#### `sources.json` — `app_sources.go:18-34`

```go
type nativeSourceRecord struct {
    Operation       string               `json:"operation"`
    Running         bool                 `json:"running"`
    Stage           string               `json:"stage"`
    Completed       int                  `json:"completed"`
    Total           int                  `json:"total"`
    Added           int                  `json:"added"`
    Error           string               `json:"error,omitempty"`
    NeedsSave       bool                 `json:"needsSave,omitempty"`
    StartedAt       time.Time            `json:"startedAt"`
    FinishedAt      time.Time            `json:"finishedAt"`
    RetryAt         time.Time            `json:"retryAt"`
    Health          *nativeSourceHealth  `json:"health,omitempty"`
    MetadataChecked map[string]time.Time `json:"metadataChecked,omitempty"`
    MetadataRetryAt map[string]time.Time `json:"metadataRetryAt,omitempty"`
    MetadataCursor  string               `json:"metadataCursor,omitempty"`
}
```

Keys are canonical source ids. Only `isHuangguoProviderSource` keys survive load (`app_sources.go:90`).

#### `resource-settings.json` — `app_settings.go:16-25`

```go
type nativeResourceSettings struct {
    ProxyMode           string `json:"proxyMode"`            // "auto" | "direct" | "manual"
    ProxyURL            string `json:"proxyUrl"`
    CatalogConcurrency  int    `json:"catalogConcurrency"`   // 1..6
    CatalogIntervalMS   int    `json:"catalogIntervalMs"`    // 0..5000
    DownloadConcurrency int    `json:"downloadConcurrency"`  // 1..6
    DownloadBySource    bool   `json:"downloadBySource"`
    Warning             string `json:"warning,omitempty"`          // runtime only, cleared on save
    SystemProxyStatus   string `json:"systemProxyStatus,omitempty"`// runtime only, cleared on save
}
```

#### `rankings.json` — `provider_rankings.go:49-59`

Key is `"<boardId>:<page>"`. `rankingPage` = `{boardId, page, items:[]rankingItem, hasMore, totalPages?, updatedText?, fetchedAt, stale?, warning?}` and `rankingItem` = `{rank:int, drama:Drama, metric?:string}` (note: the **full** `Drama` shape from `models.go`, not `nativeDrama`).

#### `huangguo-session.json` — `provider_legacy_session.go:26-33`

```go
type legacySessionState struct {
    Version   int            `json:"version"`   // must be 1
    Scope     string         `json:"scope"`     // normalized API base URL
    DeviceID  string         `json:"deviceId"`  // ^[A-Fa-f0-9]{16}[0-9]{13}$
    Token     string         `json:"token"`     // ≤4096, no CR/LF/TAB/space
    Protocol  legacyProtocol `json:"protocol"`  // {interfaceKey,paramKey,paramIV}
    UpdatedAt time.Time      `json:"updatedAt"`
}
```

#### `lan-identity.json` — `app_lan.go:35-39`

```go
type nativeLANIdentity struct {
    ID          string `json:"id"`          // ^[a-f0-9]{32}$
    Certificate string `json:"certificate"` // PEM
    Key         string `json:"key"`         // PEM PKCS8
}
```

#### `downloads/index.json` — `app_downloads.go:25-47`

A JSON **array** (not an object), sorted by `Created` ascending on write.

```go
type nativeDownloadJob struct {
    ID            string      `json:"id"`             // nativeDownloadID(Drama.ID, Index)
    Drama         nativeDrama `json:"drama"`
    Chapter       Chapter     `json:"chapter"`
    Index         int         `json:"index"`          // 1-based episode
    Quality       int         `json:"quality"`        // requested
    ActualQuality int         `json:"actualQuality"`  // negotiated
    State         string      `json:"state"`          // see §1.5
    Archived      bool        `json:"archived,omitempty"`
    Folder        string      `json:"folder,omitempty"` // "<source>/<id>" or ""
    Bytes         int64       `json:"bytes"`
    Total         int64       `json:"total"`
    Progress      float64     `json:"progress"`
    Error         string      `json:"error,omitempty"`
    Created       int64       `json:"created"`         // UnixMilli
    Revision      int64       `json:"revision,omitempty"`
}
type nativeDownloadRecord struct {
    nativeDownloadJob
    File string `json:"file,omitempty"`  // "media.mp4" | "index.m3u8" | ""
    Key  string `json:"key,omitempty"`   // hex CENC/HLS key
}
```

Per-file resume sidecar (`app_download_transfer.go:33-38`):

```go
type nativeDownloadFileState struct {
    URL       string `json:"url"`
    Validator string `json:"validator"` // strong ETag, else Last-Modified
    Total     int64  `json:"total"`
    Complete  bool   `json:"complete"`
}
```

### 1.5 Download state machine

States are exactly `removing | downloading | queued | paused | failed | completed` — anything else fails the whole index load (`app_downloads.go:137-141`). On load:

* `removing` → directory is `RemoveAll`'d and the record dropped (`:150-153`).
* `downloading`, `queued` → rewritten to `paused` with `Error = "上次下载已暂停，点击继续"` (`:155-157`).
* Records whose source is unavailable in this build are **retained but hidden** (`:145-148`).

### 1.6 Versioning / migration scheme

There is **no migration framework**; versioning is per-file, ad hoc, and forward-only:

| Artifact | Version marker | Migration on load |
|---|---|---|
| `catalogs.json` | `version` field | `==2 \|\| ==3` → structured load; else try bare `map[string][]nativeDrama` legacy shape (`app_catalog_cache.go:41`, `:69-77`) |
| `nativeDrama` | `metadataSchema` | `migrateNativeDrama`: if `metadataSchema==0 && source=="huangdou" && VIP!=nil && !*VIP` → `VIP=nil`, then stamp `metadataSchema=1` (`app_catalog_cache.go:80-86`) |
| `hongguoCatalogState` | `version` | must be exactly 1 (`provider_hongguo_app.go:80`) |
| `legacySessionState` | `version` + `scope` | must be 1 and scope must match current API base, else the file is ignored (`provider_legacy_session.go:115-120`) |
| `lan-identity.json` | none | invalid → error, file preserved (`app_lan.go:118-121`) |
| `index.json` | none | full validation; any violation → `loadErr`, index preserved, **all writes and migration blocked** |
| `localSnapshot.v1` (Dart) | `version` | must be 1; unknown → `FormatException` → lockout |
| `merge-queue.json` (Dart) | `schema` | must be 1 |
| backup JSON (Dart) | `schema`+`app` | must be `1` + `"zhenguojian"` |

The `metadataSchema` bump exists to distinguish "huangdou said free" from "huangdou never said" — see §5.1.

---

## 2. Atomic write / durability

### 2.1 Two writers, same recipe

**Writer A — `writeNativeCacheFile`** (`app_catalog_cache.go:264-285`), used by `catalogs.json`, `sources.json`, `rankings.json`, `lan-identity.json`:

```go
func writeNativeCacheFile(path string, data []byte) error {
    if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
        return err
    }
    temporary, err := os.CreateTemp(filepath.Dir(path), ".cache-write-*")
    if err != nil {
        return err
    }
    defer os.Remove(temporary.Name())        // cleanup on every exit path
    _, writeErr := temporary.Write(data)
    if writeErr == nil {
        writeErr = temporary.Sync()          // fsync the data
    }
    closeErr := temporary.Close()
    if writeErr != nil {
        return writeErr
    }
    if closeErr != nil {
        return closeErr
    }
    return os.Rename(temporary.Name(), path) // atomic replace
}
```

**Writer B — `nativeDownloadWrite`** (`app_downloads.go:167-188`), used by `resource-settings.json`, `download-location.json`, `index.json`, and all download media/sidecar files:

```go
func nativeDownloadWrite(path string, data []byte) error {
    file, err := os.CreateTemp(filepath.Dir(path), ".download-write-")
    if err != nil { return err }
    temporary := file.Name()
    defer os.Remove(temporary)
    if err = file.Chmod(0600); err == nil {   // explicit chmod: CreateTemp is 0600 already, belt-and-braces
        _, err = file.Write(data)
    }
    if err == nil { err = file.Sync() }
    closeErr := file.Close()
    if err != nil { return err }
    if closeErr != nil { return closeErr }
    return os.Rename(temporary, path)
}
```

**Writer C — `saveLegacySession`** (`provider_legacy_session.go:132-149`): `os.CreateTemp(dir, ".huangguo-session-*.tmp")` → `json.NewEncoder(file).Encode(state)` → `Close()` → `Rename`. **No `Sync()`** — this is the one writer that skips fsync.

### 2.2 Durability properties and gaps

| Property | Status |
|---|---|
| temp file in the **same directory** as target (same filesystem → rename is atomic) | ✅ all three writers |
| fsync of file contents before rename | ✅ A, B; ❌ C |
| fsync of the **containing directory** after rename | ❌ **never done** — a power loss can lose the rename even though the data was synced |
| permissions | dirs `0700`, files `0600` (CreateTemp default is already 0600) |
| temp-file cleanup on failure | ✅ `defer os.Remove` in all three |
| rollback of prior content | implicit: the old file is untouched until `Rename` succeeds |
| cross-process locking | ❌ none — no `flock`, no lockfile, no PID file |
| concurrent in-process writers | serialized by `engine.mu` (catalog/source) or `manager.mu` (downloads) |

**No advisory file locking anywhere.** `grep -rn "Flock|LOCK_EX|syscall"` over `native/core` returns nothing. Single-process assumption is baked in; the LAN sync layer is the only cross-device writer and it goes through the Dart side.

### 2.3 Size limits and their enforcement

| Constant | Value | Declared | Enforced at | Behavior on breach |
|---|---|---|---|---|
| `nativeCatalogMaxBytes` | `32 << 20` = 33,554,432 | `app_persistence.go:8` | pre-write `len(body) > cap` (`app_catalog_cache.go:249`) **and** on read (`io.LimitReader(file, cap+1)`, `:36-38`) | `errNativeCatalogLimit`; **the old file is left byte-identical**; in-memory data retained |
| `nativeSourceMaxBytes` | `4 << 20` = 4,194,304 | `app_persistence.go:9` | pre-write (`app_sources.go:115`) and on read (`:81`) | `errNativeSourceLimit`; old file preserved |
| downloads `index.json` | `32 << 20` | inline `app_downloads.go:117,203` | pre-write and on read | `"下载记录超过保存上限，原索引已保留"` |
| `rankings.json` | `8 << 20` | inline `app_rankings.go:22,55` | pre-write and on read | write silently skipped |
| `resource-settings.json` | 16 KiB | `app_settings.go:91` | on read only | warning + defaults |
| `lan-identity.json` | 32 KiB | `app_lan.go:118` | on read only | error, file preserved |
| `huangguo-session.json` | 16 KiB | `provider_legacy_session.go:116` | on read only (`io.LimitReader`) | file ignored |
| cover file | `20 << 20` | `nativeCoverMaxBytes` | download read + cache scan | `"海报文件过大"` |
| cover cache total | `256 << 20` | `nativeCoverCacheBytes` | LRU prune | evict oldest |
| diagnostic line | 5 MiB | `diagnosticLogBytes` | per write | `"单条诊断日志过大"` |

### 2.4 Error surface and retry protocol

Persistence failures are **first-class, typed, and surfaced to the UI**. `app_persistence.go:14-33`:

```go
type nativePersistenceError struct {
    label string
    cause error
}
func (err *nativePersistenceError) Error() string {
    if errors.Is(err.cause, errNativeCatalogLimit) || errors.Is(err.cause, errNativeSourceLimit) {
        return err.cause.Error()          // limit messages are shown verbatim
    }
    return err.label + "尚未保存，最新结果仅在本次运行中保留；请检查剩余空间和存储权限后重试保存"
}
```

The **degraded-mode protocol** for catalogs:

1. `writeCatalogDiskLocked` fails → `engine.catalogSaveError = nativeSaveError("剧库", err)`.
2. `markCatalogSavePendingLocked` (`app_persistence.go:73-94`) walks every catalog key, sets `record.NeedsSave = true` on the owning source and `Stage = "等待保存"` when not running, then persists `sources.json`.
3. `nativeCached` (`app_catalog_cache.go:103-107`) appends the error to `Warning` and forces `Fresh=false, HasMore=true`.
4. `nativeCatalog` (`app_runtime.go:501-508`): if a save is pending, it retries the write **before** any network call, and if the retry succeeds (or memory has items) it returns cached data without paging.
5. `saveCatalogCache` with a warning rewinds `Page` to the last saved cursor and sets `HasMore=true` (`app_catalog_cache.go:224-227`) — **an unsaved page never advances the cursor**.
6. Explicit recovery: `sourceJob` with `command="retrySave"` → `retrySourceSave` (`app_persistence.go:106-115`) retries both catalog and source writes, bypassing the network backoff. `runSourceTask` treats `nativePersistenceError` specially (`app_sources.go:246-253`): `Stage` becomes `"已保存，可继续更新"` or `"等待保存"` and `Error` is cleared.

On success, `finishCatalogSaveLocked` (`app_persistence.go:56-71`) clears `NeedsSave` and sets `Stage = "已保存，可继续更新"`.

Restart recovery for `NeedsSave` (`app_sources.go:98-108`):

```go
if record.NeedsSave {
    record.NeedsSave = false
    record.Stage = "上次保存未完成"
    record.Error = "已恢复可读取的缓存，请重新更新"
    for key, state := range engine.catalogStates {
        if key == source || strings.HasPrefix(key, source+"|") {
            state.UpdatedAt = time.Time{}     // invalidate freshness
            engine.catalogStates[key] = state
        }
    }
}
```

Interrupted task recovery (`app_sources.go:93-97`): `Running=true` becomes `Running=false`, `Stage="任务已中断"`, `Error="上次任务未完成，已保留已更新内容，可重新开始"`.

**Download rollback** is explicit and per-operation. `enqueueContext` (`app_downloads.go:264-321`) snapshots `previous map[string]nativeDownloadRecord` before mutating and restores it on any failure; `controlExpected` (`:349-407`) does the same. `remove` is two-phase: mark `removing` + save → `RemoveAll` → delete record + save; if the second save fails the record is re-inserted so the files are still tracked (`:413-426`).

---

## 3. Catalog cache

### 3.1 Key scheme

`nativeCatalogKey` (`app_categories.go:27-33`):

```go
func nativeCatalogKey(source, category string) string {
    source = canonicalProviderSource(source)
    if category = strings.TrimSpace(category); category != "" {
        return source + "|" + category
    }
    return source
}
```

So keys are `"<source>"` (whole-source feed) or `"<source>|<category>"`. Examples: `hongguo`, `hongguo|short_play`, `hongguoai|ai-duanju`, `huangju|@new`, `dsd|5`.

**Per-category independence is a hard invariant.** `TestNativeCategoryPaginationStaysIndependent` asserts `ai-duanju` at page 2 and `ai-manju` at page 1 coexist with separate item lists and survive restart (`app_categories_test.go:13-58`).

**Dual-write to the base key**: whenever a categorized key is saved, the items are also merged into `catalogs[baseSource]` (`app_catalog_cache.go:235-237`):

```go
if base, _, categorized := strings.Cut(source, "|"); categorized {
    engine.catalogs[base] = mergeNativeCatalog(engine.catalogs[base], items)
}
```

The base key has **no** `catalogStates` entry of its own for the categorized feeds — its `Page`/`HasMore` come only from direct whole-source fetches. `sourceStatusLocked` reads `catalogStates[source]` for the base key, so after only categorized fetches `Page` reports `1`.

Recommendations get a synthetic namespace (`app_recommendations.go:15`):

```go
func nativeRecommendationKey(genre string) string { return sourceHongguo + "|recommendation:" + genre }
```

### 3.2 Freshness TTL

```go
const nativeCatalogTTL = 15 * time.Minute     // app_catalog_cache.go:12
```

Freshness predicate (`app_catalog_cache.go:100`):

```go
Fresh: len(items) > 0 &&
       state.Warning == "" &&
       !state.UpdatedAt.IsZero() &&
       age >= 0 &&                    // guards clock skew / future timestamps
       age < nativeCatalogTTL
```

`UpdatedAt` is stamped only on a warning-free save (`app_catalog_cache.go:230-233`). `TestNativeCatalogCacheFreshnessPagingAndRefresh` verifies: first request fetches; second within TTL is served from cache with zero HTTP calls; restart still serves cache; `force=true` refetches; manually aging `UpdatedAt` past 15 min forces refetch (`app_cache_test.go:182-244`).

Cache hit path (`app_runtime.go:509-513`): only when `query == "" && page == 1 && !input.Force`.

### 3.3 Offset / session / signature / lastId persistence

This is the 红果 App feed cursor, persisted **in the same snapshot as the items** — this is the crux of P1-R1.

Cursor fields (`provider_hongguo_app.go:22-30`): `Offset`, `SessionID`, `LastID`, `PageSignature`, `Initialized`, `Exhausted`, `UpdatedAt`.

**Page parse** (`provider_hongguo_catalog.go:196-250`):

```go
next, parseErr := strconv.Atoi(mapString(data, "next_offset"))
hasMore, paginationOK := data["has_more"].(bool)
if !paginationOK || hasMore && parseErr != nil {
    return items, cursor, errors.New("App 分页标记无效，已保留上次位置")
}
if parseErr != nil { next = cursor.Offset + len(rows) }

lastID, signature := "", ""
if len(items) > 0 {
    lastID = items[len(items)-1].ID
    sort.Strings(ids)
    signature = fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(ids, "\n"))))
}
// progress guard: a hasMore page that doesn't advance, or repeats the same ID set, is rejected
if hasMore && (len(items) == 0 || next <= cursor.Offset || next > 1_000_000 || signature == cursor.PageSignature) {
    return items, cursor, errors.New("App 分页未前进，已保留上次位置")
}
if !hasMore && (next < cursor.Offset || next > 1_000_000) { next = cursor.Offset }

session := mapString(data, "session_id")
if len(session) > 4096 || strings.ContainsAny(session, "\r\n\x00") {
    return items, cursor, errors.New("App 分页会话无效，已保留上次位置")
}
cursor.Exhausted = !hasMore
cursor.Initialized = true
cursor.Offset = next
cursor.SessionID = session
cursor.LastID = lastID
cursor.PageSignature = signature
cursor.UpdatedAt = time.Now()
```

So the **page signature is `sha256(sorted ids joined by "\n")`**, used purely as a stall detector: if two consecutive pages return the same ID *set*, the second is rejected as "not advancing" even if `next_offset` moved.

**Session expiry**: 30 minutes (`provider_hongguo_catalog.go:106-108`):

```go
if age := time.Since(cursor.UpdatedAt); age < 0 || age > 30*time.Minute {
    cursor.SessionID = ""
}
```

**Session recovery** is bounded to two attempts (`:126-155`): attempt 0 may use the saved session; on failure it clears `payload["session_id"]` and retries once; any `requestBackoff` or `ctx` error aborts immediately. `TestNativeHongguoCursorRecoversSessionsAfterRestart` covers `expired`, `rejected` (`{"code":1001}`) and `repeated-page` scenarios and asserts ≤3 calls, final `offset=36`, `sessionId="new-session"`, and 3 merged items (`app_catalog_persistence_test.go:132-191`).

**Cursor save timing**: the cursor is written into `client.state.Feeds[...]` immediately after each successful page (`provider_hongguo_catalog.go:183-186`), but it only reaches **disk** when `writeCatalogDiskLocked` runs with `engine.hongguoCatalog` snapshotted. Critically, a metadata-only write (`saveDetailMetadata`) snapshots `engine.hongguoCatalog`, which is only refreshed from the live downloader state on `saveCatalogCache` (`app_catalog_cache.go:221-223`) — so an in-flight page's cursor is *not* persisted by an unrelated metadata write. This exact behavior is locked down by `TestNativeCatalogMetadataSaveExcludesInFlightCursor` (`app_catalog_persistence_test.go:350-400`).

**Head vs tail scanning** (`provider_hongguo_catalog.go:80-90, 169-182`):

* Not "more" and cursor initialized → scan **head** from `tail = cursor` (looking for new items at the top).
* Otherwise → scan **tail** from `cursor` until `Exhausted` or `pageLimit` pages.
* Head scan stops after `headLimit = min(pageLimit, 3)` pages or when a page yields zero new IDs; the checkpoint then reverts to the saved tail cursor if the tail was further along (`scan.tail.Offset >= cursor.Offset`).
* In `update` mode the round limit is `pageLimit + headLimit`.

`pageLimit = cfg.MaxPagesPerSort` clamped to `[1, 200]` (`:61-67`), default 50 (`app_runtime.go:76`).

### 3.4 Merge-by-id rules

Two merge functions, both keyed strictly on `ID`.

`mergeNativeCatalog` (`app_catalog_cache.go:111-126`) — list-level, order-preserving:

```go
func mergeNativeCatalog(first, second []nativeDrama) []nativeDrama {
    items := append([]nativeDrama{}, first...)
    indices := make(map[string]int, len(items))
    for index, item := range items { indices[item.ID] = index }
    for _, item := range second {
        if index, found := indices[item.ID]; found {
            items[index] = mergeNativeDrama(items[index], item)
        } else {
            indices[item.ID] = len(items)
            items = append(items, item)
        }
    }
    return items
}
```

Existing positions are **never reordered**; new IDs append.

`mergeNativeDrama(previous, fresh)` (`app_catalog_cache.go:128-173`) — field-level, **fresh wins except when fresh is empty**:

| Field | Rule |
|---|---|
| `ID` | if both non-empty and differ → return `fresh` wholesale (identity mismatch) |
| `Source`, `SourceID` | fresh if non-empty |
| `Title` | fresh unless `""` or `"短剧"` |
| `Description`, `Cover` | fresh if non-empty |
| `Category` | fresh if non-empty, **unless** fresh is a generic label *and* previous is non-generic |
| `Episodes` | fresh if `> 0` |
| `VIP` | fresh `nil` → previous (tri-state preserved; `false` is a real value) |
| `Heat`, `Views`, `OnlineDate` | fresh if non-empty |
| `Tags` | fresh if `len > 0` |
| `ReleaseStatus` | fresh unless `""` or `"unknown"` |

Generic category set (`app_catalog_cache.go:175-181`): `短剧, 真人剧, 漫剧, AI剧, AI 剧, AI短剧, AI 短剧, AI漫剧, AI 漫剧`.

The Dart `Drama.merge` (`lib/models.dart:212-250`) is a **line-for-line mirror** of this, including the generic-category table — they must stay in sync.

### 3.5 Dedup

Dedup happens at three levels:

1. **Per fetch**: `nativeCatalog` builds `seen map[string]bool` and skips empty or duplicate IDs before normalizing (`app_runtime.go:710-717`).
2. **Within a 红果 page**: `parseHongguoCatalogPage` dedups into `ids` for the signature but keeps the item order (`provider_hongguo_catalog.go:204-214`).
3. **Across categories**: because `mergeNativeCatalog` is keyed on `ID`, the base source list accumulates one entry per ID even when the same drama appears in multiple categories. `TestNativeCatalogPreservesLargeLibraryAndPage501` asserts 6000 items in `ai-duanju` + 2 in `ai-manju` where one ID overlaps → base list is exactly **6002**, not 6003 (`app_catalog_persistence_test.go:244-254`).

### 3.6 The "6000 items / 500 pages" limits and how they were changed

The README (`README.md:131-132`) states the change under **P1-R2**:

> | P1-R2 | 两版 | 移除 6000 条和 500 页静默上限，按 ID 合并持久保存；32 MiB 保存限制明确报错 | 第 6001 条、第 501 页、重启、跨分类去重 |

**What the old code did (inferred from git history):** the only commit that ever contained a `6000` in `native/core` is the initial import `52dc0fc` ("真果鉴/红果鉴 0.2.58+67 源码"), and there it appears **only in the test** (`app_catalog_persistence_test.go:230`, `items := make([]nativeDrama, 6000)`). `git log -S"6000"` and `git log -S"nativeCatalogMaxItems"` find no production constant. The current tree's `git grep -n 6000 52dc0fc -- native/core` confirms: no production 6000 anywhere. The caps were therefore **removed before or at the first published snapshot**, and the current code encodes their absence as test assertions.

**Current state — no item cap, no page cap:**

* Item count: unbounded except by the 32 MiB serialized limit. `TestNativeCatalogPreservesLargeLibraryAndPage501` saves 6000 items, then fetches page **501** and asserts the request URL literally contains `page=501` (`app_catalog_persistence_test.go:238-243`):
  ```go
  if requested != "501" { t.Fatal("catalog silently clamped the requested page", requested) }
  ```
  After restart it asserts `len(cached.Items) == 6001`, `cached.Page == 501`, `cached.HasMore == false`, base list `6002`.
* Page number: `nativeCatalog` does `page := max(1, input.Page)` (`app_runtime.go:499`) — no upper clamp. The only upper bound is the *source-level* guard in `loadMoreSourceCatalogPages` (`app_sources.go:439-441`):
  ```go
  if page > 1000000 { return errors.New("站源分页已达到接口范围，已保留目录位置") }
  ```
  and the 红果 cursor guard `next > 1_000_000` in `parseHongguoCatalogPage`.
* The **remaining `500`s are unrelated** and must not be confused with the removed page cap:
  * `app_rankings.go:33,65` — ranking page range `1..500` (a ranking-specific limit, still enforced).
  * `app_downloads.go:245`, `app_download_collections.go:78` — "1 to 500 episodes per enqueue / 1 to 500 jobs per batch" (download API limits).
  * `provider_dsd_catalog.go:179`, `provider_guipian.go:210`, `provider_hanxiaoquan.go:167`, `provider_huangju.go:164` — per-page row-count sanity guards ("too many rows in one page").
  * `provider_hongguo.go:90-91` — `pages > 500 → 500` inside the *HTML* 红果 route walker (`fetchHongguoRoute`), a different code path from the App feed. This one **is still a page cap** on that specific legacy route.
  * `provider_duanju_api.go:316` — `page > 500` rejection for one duanju API source.

**How the 32 MiB limit is surfaced instead** (`app_persistence_test.go` / `app_catalog_persistence_test.go:321-348`): oversized data produces `errNativeCatalogLimit`, the previous `catalogs.json` stays byte-identical (`bytes.Equal(before, after)`), the in-memory list keeps both items, `Fresh=false`, `Warning` contains `"上限"`, further paging stops issuing network requests (`requests.Load() == 0` for page 3), and after restart only the last durable state (1 item, page 1) is visible.

---

## 4. Library (追剧) & watch progress

**This is entirely Dart.** No Go file persists favorites, history, or follow state.

### 4.1 Storage substrate

`lib/local_snapshot.dart` — a single `SharedPreferences` string key `localSnapshot.v1` containing:

```json
{"version": 1, "values": { "<key>": "<json-encoded string>", ... }}
```

Key ownership is enforced by two whitelists plus a regex (`lib/local_snapshot.dart:11-45`):

```dart
static const storageKey = 'localSnapshot.v1';
static const libraryKeys = {
  'history', 'favorites', 'followStates', 'seriesCandidates', 'mediaHistory',
  'source', 'hideVip', 'playback', 'downloadPreferences', 'catalogView',
  'recentSearches', 'lanRecords', 'lanSettings', 'lanReceipts',
};
static const globalKeys = {
  'profiles', 'activeProfile', 'displayMode', 'themeMode',
  'autoExport', 'exportPosters', 'forceLogin',
};
static bool owns(String key) =>
    globalKeys.contains(key) || libraryKeys.contains(key) ||
    RegExp(r'^profile\.[a-zA-Z0-9_-]{1,64}\.(history|favorites|followStates|seriesCandidates|mediaHistory|source|hideVip|playback|downloadPreferences|catalogView|recentSearches|lanRecords|lanSettings|lanReceipts)$').hasMatch(key);
```

### 4.2 Per-user isolation

`lib/local_store.dart:108-109` — the single most important line for isolation:

```dart
String _key(String key, [String? id]) =>
    (id ?? _current) == 'default' ? key : 'profile.${id ?? _current}.$key';
```

* The admin profile (`id == "default"`) uses **bare** keys (`history`, `favorites`, …) — this preserves pre-multi-user installs.
* Every other profile gets `profile.<id>.<key>`.
* Profile ids match `^[a-zA-Z0-9_-]{1,64}$` (`local_profiles.dart:46`), so the prefix is unambiguous.
* Deleting a profile removes exactly `LocalSnapshot.libraryKeys.map((key) => _key(key, id))` (`local_store.dart:846-857`).
* Global keys (`profiles`, `activeProfile`, `displayMode`, `themeMode`, `autoExport`, `exportPosters`, `forceLogin`) are shared; everything in `libraryKeys` is per-user.

`local_store.dart:123-126`:

```dart
bool allowsSource(String source) =>
    !locked && SourceSite.isAvailable(source) && profile.allows(source);
```

`profile.allows` (`local_profiles.dart:27`): `admin || sources.contains(source)`.

Reads are filtered through `allowsSource` at every accessor (`history`, `favorites`, `watched`, `isFavorite`, `following`, `seriesDramasFor`), so revoking a source immediately hides previously-cached records without deleting them.

### 4.3 Data model

**`WatchEntry`** (`lib/models.dart:360-389`) — one per drama:

```json
{
  "drama": { "metadataSchema": 1, "id": "hongguo:7399…", "source": "hongguo", "sourceId": "7399…",
             "title": "…", "description": "…", "cover": "https://…", "episodes": 24,
             "category": "…", "vip": true, "heat": "", "views": "", "onlineDate": "2026-01-02",
             "tags": [], "releaseStatus": "finished" },
  "episode": 7,
  "position": 123.456,
  "duration": 600.0,
  "updatedAt": "2026-10-15T10:19:00.000"
}
```

`finished` is derived: `duration > 1 && position >= duration - 1` (`:373`).

**`FollowState`** (`lib/follow_state.dart:14-181`):

```json
{
  "status": "planned" | "watching" | "watched",
  "manuallyWatched": false,
  "knownEpisodes": 24,
  "readEpisodes": 20,
  "seriesSeasons": {
    "hongguo:7399…": {"id":"hongguo:7399…","title":"…","season":2,"unit":"季","read":false}
  }
}
```

Validation (`:140-181`): `knownEpisodes` int `0..1000000`; `readEpisodes` null or `0..knownEpisodes`; `manuallyWatched` bool and **must imply `status == watched`**; `seriesSeasons` ≤200 entries, key must equal `notice.id`, no duplicates; each notice `id` starts with `"hongguo:"`, ≤512 chars, `title` non-empty ≤300, `season` `1..200`, `unit ∈ {"季","部"}`, `read` bool (`:217-241`).

Derived update signals (`:29-37`):

```dart
int get newEpisodes => readEpisodes == null ? 0 : max(0, knownEpisodes - readEpisodes!);
int get newSeasons  => seriesSeasons.values.where((n) => !n.read).length;
bool get hasUpdates => newEpisodes > 0 || newSeasons > 0;
```

**`SeriesSeasonNotice`** is how "new season of the same series" is detected for 红果, populated by `observeHongguoSeriesSeasons` in `lib/hongguo_series.dart` (called from `_refreshDramas`, `local_store.dart:684-689`).

**`mediaHistory`** (`local_store.dart:555-584`): a separate `map[id]WatchEntry` used only when `canDownload` is true, capped at **300** entries with insertion-order eviction.

### 4.4 Limits

| Collection | Cap | Enforcement |
|---|---|---|
| `favorites` (追剧) | **20000** | `toggleFavorite` throws `"追剧数量已达上限，请先整理追剧"`; `setFollowStatus` same; LAN merge checks post-merge (`local_store.dart:442, 465, 185`) |
| `history` | **300** (kept newest by `updatedAt`) | `sorted.take(300)` on every save (`:541`) |
| `mediaHistory` | **300** | `while (data.length > 300) data.remove(data.keys.first)` (`:579-581`) |
| `recentSearches` | **20**, each ≤80 runes | `rememberSearch` (`:326-341`) |
| `seriesCandidates` | **2000** (sorted by id) | `_refreshDramas` (`:698-706`) |
| `followStates` | ≤20000, keys ⊆ favorite ids | backup validation (`:947-950`) |
| `lanRecords` | **25000** (`LanDocument.limit`) | `lan_sync_models.dart:411` |
| whole snapshot | **16 MiB** | `LocalSnapshot.commit` (`local_snapshot.dart:101-103`) |
| backup file | **8 MiB** | `exportBackup` / `validateBackup` |

### 4.5 Merge rules

**History save** (`local_store.dart:513-553`) merges the drama record, never the position:

```dart
final previous = _history[entry.drama.id]?.drama;
final current = previous == null
    ? entry
    : WatchEntry(
        drama: previous.merge(entry.drama),   // metadata merge, fresh-wins-if-nonempty
        episode: entry.episode,               // always the new position
        position: entry.position,
        duration: entry.duration,
        updatedAt: entry.updatedAt,
      );
```

If the drama is also followed, `followStates[id] = following.afterPlayback(current)` and the favorite's drama is merged too.

**Follow-state observation** (`follow_state.dart:63-93`):

```dart
FollowState observe(Drama drama) {
  final count = max(knownEpisodes, drama.episodes);   // monotonic: never decreases
  return FollowState(
    status: !manuallyWatched && status == FollowStatus.watched && count > knownEpisodes
        ? FollowStatus.watching       // a finished show that gained episodes reverts to watching
        : status,
    ...
    knownEpisodes: count,
    readEpisodes: readEpisodes ?? (count > 0 ? count : null),
    ...
  );
}

FollowState afterPlayback(WatchEntry entry) {
  final state = observe(entry.drama);
  if (state.manuallyWatched || entry.position <= 0) return state;   // no position ⇒ no status change
  return FollowState(
    status: state.knownEpisodes > 0 && entry.finished && entry.episode >= state.knownEpisodes
        ? FollowStatus.watched
        : FollowStatus.watching,
    ...
  );
}
```

So: **update detection is `knownEpisodes` growth** (monotonic high-water mark), and "new episodes" is `knownEpisodes - readEpisodes` where `readEpisodes` advances only on `markRead()` / explicit `watched`.

**Resume point** (`follow_state.dart:244-251`):

```dart
int resumeEpisodeIndex(List<Episode> episodes, WatchEntry? watch) {
  if (episodes.isEmpty || watch == null) return 0;
  final current = episodes.indexWhere((item) => item.number == watch.episode);
  if (current >= 0 && !watch.finished) return current;
  final next = episodes.indexWhere((item) => item.number > watch.episode);
  if (next >= 0) return next;
  return current >= 0 ? current : episodes.length - 1;
}
```

### 4.6 Incremental sync markers (LAN)

`lib/lan_sync_models.dart` implements a **version-vector CRDT** over three per-record fields: `member` (bool: followed), `status` ({status, manual}), `progress` ({episode, position, duration, updatedAt}).

* `LanVersion` = `map[replicaId(32 hex) → counter]`, ≤64 replicas, counter in `1 .. 9_007_199_254_740_000` (`:60-77`).
* `LanCell` = a sorted list of `{v, value}` candidates, ≤32; two candidates are only legal if their version vectors are **concurrent** (neither includes the other) and their values differ (`:110-127`). `conflict` = `values.length > 1`.
* `LanDocument` = `{schema: 1, replica: 32hex, counter: int, records: [LanRecord]}`; `counter` is the Lamport clock, advanced by `max(counter, cell.version[replica]) + 1` on each edit (`:449-455`).
* `LanRecord` = `{drama, member, status, progress, known, read}` with `id == drama.id`; single-record size cap **512 KiB** (`:339-341`).
* Receipts prevent double-apply: `lanReceipts` is a list of `{operation, hash, savedAt}`, last **64**, and `applyLanRecords` early-returns if the operation id is already present (`local_store_sync.dart:128-131, 150`).
* Optimistic concurrency: `applyLanRecords` compares `document.hashFor(sources)` to the caller's `base` and throws `"记录刚刚发生变化，请重新同步或预览"` on mismatch (`:152-154`).

`history` is **not** versioned per-field; it is a projection of `progress` cells plus `updatedAt` sorting, truncated to 300.

### 4.7 Write serialization and epochs

All mutations funnel through a single-slot promise chain (`local_store.dart:1118-1121`):

```dart
Future<void> _queue(Future<void> Function() action) {
  _writes = _writes.catchError((Object _) {}).then((_) => action());
  return _writes;
}
```

Every mutation captures `final epoch = _epoch;` before queuing and re-checks `epoch != _epoch` inside — so a profile switch or config lock mid-queue aborts the stale write (`:313, 331, 395, 434, 463, 488, 502, 515, 571, 589, 602, 628, 742`). `_epoch++` happens on `switchProfile`, `lock`, `_block`, `_installBackup`, and a changed `reload`.

---

## 5. Metadata enrichment

### 5.1 VIP tri-state (unknown vs known vs VIP)

`nativeDrama.VIP` is `*bool` (`app_runtime.go:88`). The three states are load-bearing:

* `nil` → **never determined** (needs enrichment; also blocks "no more work" decisions).
* `true` → VIP.
* `false` → known free.

The `metadataSchema` migration exists precisely because pre-v1 黄豆 data wrote `false` for "unknown" (`app_catalog_cache.go:80-86`):

```go
func migrateNativeDrama(drama nativeDrama) nativeDrama {
    if drama.MetadataSchema == 0 && drama.Source == sourceHuangdou && drama.VIP != nil && !*drama.VIP {
        drama.VIP = nil      // a pre-schema huangdou `false` was actually "unknown"
    }
    drama.MetadataSchema = 1
    return drama
}
```

The Dart reader mirrors this so old JSON still decodes correctly (`lib/models.dart:181-187`):

```dart
vip: json['vip'] == true ? true
   : json['vip'] == false && (json['source'] != 'huangdou' || intValue(json['metadataSchema']) >= 1) ? false
   : null,
```

黄豆's inference itself (`provider_huangdou_vip.go:9-43`) is a priority cascade that returns `*bool` and can legitimately return `nil`:
1. `is_vip`/`isVip` in `{"true","1","y"}` → `true`; `{"false","0","n"}` → remember as `known`.
2. `pay_type` == `vip` → `true`; `free` → remember as `known`.
3. any positive `vip_episodes[]` entry → `true`.
4. any `episodes[].type == "vip"` → `true`.
5. otherwise → `known` (possibly `nil`).

`unknownVip` count is reported per source in `nativeSourceStatus` (`app_sources.go:137-144`) — only for `sourceHuangdou`.

### 5.2 What triggers enrichment

`nativeNeedsExtraMetadata` (`app_metadata.go:11-14`):

```go
func nativeNeedsExtraMetadata(drama nativeDrama) bool {
    return drama.Source == sourceHongguo && drama.OnlineDate == "" ||
        drama.Source == sourceHuangdou && (drama.Heat == "" || drama.VIP == nil)
}
```

So: 红果 needs it when `onlineDate` is missing; 黄豆 needs it when `heat` is missing **or** VIP is unknown.

`nativeExtraMetadata` (`app_metadata.go:16-66`) runs under a **15 s** timeout and a background-catalog context:

```go
ctx, cancel := context.WithTimeout(context.WithValue(ctx, backgroundCatalogKey{}, true), 15*time.Second)
```

* 红果: requires `hongguoNumericID` (`^[0-9]{1,32}$`), GETs `<hongguoBaseURL>/detail?series_id=<id>`, parses via `parseHongguoSortDetail` (`provider_detail_metadata.go:11-24`), which validates `series_id` echo and non-empty title.
* 黄豆: `huangdouDetail(ctx, id)`; if heat is still empty it does a second `/drama/list` call with `{keywords, page:"1", page_size:"50"}` and picks the row whose `id` (after stripping `rp_`) matches, then `mergeDramaMetadata`.

### 5.3 Field precedence

**Detail path** (`nativeDetail`, `app_runtime.go:722-790`) — most authoritative wins, applied in order:

1. `drama` as passed in (already cached).
2. `nativeNormalize(raw)` from the provider detail call, but **only if `raw.ID == drama.ID`** (identity check).
3. 红果 only: `hongguoCachedDrama` overlay.
4. 黄豆 only: `huangdouDetail` overlay (again guarded by `fresh.ID == drama.ID`).
5. `drama.Source, drama.SourceID = source, sourceID` (forced).
6. `drama.Episodes = len(chapters)` (forced, from the authoritative chapter list) — except 红果/剧果/野果 where `Episodes = max(len(chapters), nativeNormalize(raw).Episodes)` (`:782-784`).

**Field-level merge** is `mergeNativeDrama` (§3.4): fresh wins unless empty, `"短剧"`, or `"unknown"`; `VIP` only fills when fresh is `nil`; generic category never overwrites specific.

**Sort/detail HTML patch** `parseHuangguoSortDetail` (`provider_detail_metadata.go:26-92`) — JSON-LD `@graph` walk, matching on host+path:
* accepts `@type ∈ {WebPage, VideoObject, TVSeries, Movie}`;
* rejects on host mismatch (unless `providerSourceForURL` resolves to the same source), path mismatch, empty name, or `huangguoTitleNeedsRepair` for the AI source;
* `Title` ← `row.Name` (last match wins);
* `Cover` ← `providerCoverAddress(row.Image)` then `Thumbnail`, resolved against `pageURL`, http(s)-only, no userinfo;
* `OnlineDate` ← `providerReleaseDate(firstNonEmpty(Uploaded, Published))`, but only if currently empty **or** `row.Type == "VideoObject"`;
* fallback `og:image` from `<meta property="og:image">`;
* `Views` ← `normalizeViews(reViewsText)` from the `hg-web-detail__meta` block;
* `OnlineDate` ← `providerReleaseDate(reDateText)` if still empty and the meta contains `"上线"`;
* AI source: `TotalEpisode`/`EpisodeCount` ← `episodeIndex(data-ep-base)`.

**Date normalization** (`provider_sort_details.go`):
* `providerReleaseDate`: parse RFC3339Nano → format `2006-01-02` in CST (UTC+8), else `normalizeDate`, then reject unless it parses as `YYYY-MM-DD` with year `2000..2100`.
* `providerTimestampDate`: parse int; if `> 100_000_000_000` divide by 1000 (ms→s); format in CST; reject year outside `2000..2100`.
* `providerChinaTime = time.FixedZone("CST", 8*60*60)` (`provider_sort_metadata.go:10`).
* `hongguoOnlineDate` (`provider_sort_metadata.go:24-46`) additionally maps `"今日上新"` → today, `"昨日上新"` → yesterday, and any label ending in `"上新"` via `normalizeDate`.

**`nativeNormalize`** (`app_runtime.go:213-237`) is the single funnel from the wide `Drama` shape to `nativeDrama`:
* cover: first http(s) candidate over 12 keys, `//` → `https:`;
* episodes: **max** over 8 keys (not first-non-empty);
* `Source`/`SourceID` derived from `splitProviderDramaID(drama.ID)`, **not** from `drama.Source`;
* title via `DisplayTitle()` (`title` → `name` → `"短剧"`);
* description via `firstNonEmpty(Desc, Intro)`;
* `MetadataSchema: 1` stamped.

### 5.4 Failure retry schedule

`updateSource`'s metadata pass (`app_sources.go:306-409`):

```go
if operation != "vipMetadata" && time.Since(record.MetadataChecked[drama.ID]) < 24*time.Hour {
    continue                                    // don't re-check anything checked in the last 24 h
}
if time.Now().Before(record.MetadataRetryAt[drama.ID]) {
    continue                                    // honor the retry cooldown
}
```

Selection also requires one of: `operation ∈ {metadata, vipMetadata}`, or `Episodes <= 0`, or `Description == ""`, or (`source == huangdou && VIP == nil`). **Batch size is capped at 8** (`if len(pending) >= 8 { break }`), and the scan **starts after `MetadataCursor`** and wraps modulo the list — so it's a rotating sweep, not a from-the-top restart:

```go
start := 0
for index, drama := range items {
    if drama.ID == record.MetadataCursor { start = index + 1; break }
}
for scanned := 0; scanned < len(items); scanned++ {
    drama := items[(start+scanned)%len(items)]
```

Outcomes (`:371-396`):

| Outcome | `MetadataChecked[id]` | `MetadataRetryAt[id]` |
|---|---|---|
| success | `now` | deleted |
| success but 黄豆 VIP still `nil` | `now` | `now + 5 min` |
| failure, error contains `"404"` | untouched | `now + **24 h**` |
| failure, other | untouched | `now + **5 min**` |
| `ctx` cancelled | untouched | untouched |

**Abort conditions**: a `nativePersistenceError` aborts the whole pass immediately (`:398-401`); a `requestBackoff` aborts; **2 accumulated failures** abort (`len(failures) >= 2`).

**Scan position persistence**: `record.MetadataCursor = drama.ID` is written for **every** processed drama, success or failure (`:373`). It lives in `sources.json`, so it survives restart.

### 5.5 404 cooldown

The 404 detection is a **substring match on the error string** (`app_sources.go:391-393`):

```go
retry := 5 * time.Minute
if strings.Contains(err.Error(), "404") {
    retry = 24 * time.Hour
}
```

This is fragile (any error text containing "404", including a drama ID, triggers it) but it is the actual behavior. There is no structured 404 error type.

### 5.6 Cover metadata / repair

Separate from drama metadata. `nativeCoverAddress` (`app_cover_metadata.go:14-110`) resolves a poster URL per source when the cached URL fails:
* 红果: POST `/novel/player/video_detail/v1/` `{series_id}`, echo-check `series_id_str`/`series_id`, then `hongguoCoverAddress(series_cover, cover)` (which enforces http(s), no userinfo, ≤8192 chars, `//`→`https:`).
* 黄豆: `huangdouDetail` + `nativeNormalize(...).Cover` with ID echo-check.
* 剧果/野果/帝果/青空/鬼片/韩小圈/duanju: full detail fetch, take normalized cover.
* cloudfront: `rankingSourceID` guard, `/api/app/playlet/detail/<id>`, echo-check, then 12-key scan with `legacyCoverURL`.
* 黄果 AI/视频: HTML detail page + `parseHuangguoSortDetail`.

Repair caching (`app_cover_repair.go:14-87`):
* `cache.repairs[id]` holds `{done, address, err, retryAt}`.
* In-flight calls coalesce on `done`.
* **Cooldown `retryAt = now + 5 min`** (`:83`); within the cooldown, the previous `address`/`err` is returned without a network call unless `force`.
* Map capped at **512**; when full it evicts one completed (`retryAt` non-zero) entry, else errors with `"海报正在加载，请稍后重试"`.
* Repair work is serialized through a **1-slot** channel `repairSlots` (`:58`) with a 15 s timeout (`:71`).

Repaired addresses are written back into the catalog (`saveCoverAddress`, `:124-139`) → `writeCatalogDiskLocked`.

**Cover byte cache** (`app_covers.go`):
* Key: `sha256(source + "\x00" + coverURL + "\x00" + referer)` hex → `covers-v1/<key>.img` (`:121-123`).
* Referer policy per source (`nativeCoverReferer`, `:85-104`): cloudfront `.zdmhyg.cn`/`pic.tuafjz.cn` → 黄果 AI base; 黄豆 `tideember.cc`/`xqjurgek.top` → `scheme://host/home`, else provider base + `/home`; everything else → provider base + `/`.
* TTL **30 days** (`nativeCoverTTL = 30 * 24 * time.Hour`).
* Concurrency: **4** download slots (`slots`), **256** pending cap.
* Failure fallback: an expired-but-present file is returned on network failure (`fallback`), but a **forced** retry surfaces the error instead (`:188-192`) — verified by `TestNativeCoverFormatsFailuresAndOfflineFallback` (`app_cache_test.go:142-144`).
* Decode cascade (`nativeDecodeCover`, `:244-276`): passthrough if already an image → strip `Salted__`+16 → AES-256-CBC with key `f5d965df75336270`, IV `97b60394abc2fbe1`, PKCS#7 unpad → XOR first `min(100,len)` bytes with `2019ysapp7527` → else return original.
* Magic-byte acceptance (`nativeIsCoverImage`, `:278-296`): PNG, JPEG, GIF87a/89a, RIFF/WEBP, HEIC/AVIF via `ftyp` brands `avif avis heic heix hevc hevx mif1`.
* Startup sweep deletes `.decode-*` temp files older than 1 h (`:61-66`).
* LRU prune by `usedAt` when over **256 MiB** or **2000** entries (`:298-318`).

---

## 6. Users & permissions

**All in Dart.** Files: `lib/local_profiles.dart`, `lib/local_store.dart`, `lib/local_snapshot.dart`, `lib/profiles_screen.dart`, `lib/settings_screen.dart`.

### 6.1 User record schema

`lib/local_profiles.dart:9-68`:

```json
{
  "id": "default",
  "name": "管理员",
  "admin": true,
  "sources": ["hongguo", "huangdou"],
  "download": true,
  "salt": "0f3a…(32 hex)",
  "pinHash": "9c1e…(64 hex)"
}
```

| Field | Type | Rules |
|---|---|---|
| `id` | string | `^[a-zA-Z0-9_-]{1,64}$`; `"default"` is the sole admin |
| `name` | string | trimmed, non-empty, `length <= 40` |
| `admin` | bool | **must equal `(id == "default")`** — `admin != (id == 'default')` is a validation failure |
| `sources` | `[]string` | deduped via `toSet().toList()`; each must pass `SourceSite.isKnown` |
| `download` | bool | must be bool if present; defaults `true` |
| `salt` | string | `""` or `^[a-f0-9]{32}$` |
| `pinHash` | string | `""` or `^[a-f0-9]{64}$` |

`(salt.isEmpty != hash.isEmpty)` is rejected — both or neither. `protected => salt.isNotEmpty && pinHash.isNotEmpty` (`:26`).

`SourceSite.isKnown` accepts exactly the **23** ids in `SourceSite.allValues` (`lib/models.dart:79-92` = 11 explicit + 12 `duanjuValues`): `hongguo, huangdou, huangju, yeguo, dsd, huangguo-video, huangguoai, cloudfront, sorani, guipian, hanxiaoquan, yaguo, maoguo, fanguo, guanguo, heguo, xingguo, huaguo, niuguo, wangguo, faguo, piguo, wuguo`. `isAvailable` is narrower: the hongguo-only build exposes only `["hongguo"]` (`:93-94`), the all-sources build exposes all 23.

### 6.2 Admin password hashing

**Not bcrypt, not argon2, not PBKDF2 — a custom iterated HMAC-SHA256 "pin hash"** (`lib/local_profiles.dart:79-93`):

```dart
String _derivePin(String pin, String salt) {
  final key = Hmac(sha256, utf8.encode(pin));
  var value = key.convert([...utf8.encode(salt), 0, 0, 0, 1]).bytes;
  final result = List<int>.from(value);
  for (var i = 1; i < 120000; i++) {
    value = key.convert(value).bytes;
    for (var j = 0; j < result.length; j++) {
      result[j] ^= value[j];
    }
  }
  return result.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

Future<String> hashProfilePin(String pin, String salt) =>
    Isolate.run(() => _derivePin(pin, salt));
```

Precisely:
* `key = HMAC-SHA256(key = UTF8(pin))` — the pin is the HMAC **key**, not the message.
* `v₀ = HMAC(key, UTF8(salt) ‖ 0x00 0x00 0x00 0x01)`.
* `acc = v₀`; for `i = 1 .. 119999`: `vᵢ = HMAC(key, vᵢ₋₁)`; `acc ^= vᵢ` (32-byte XOR accumulator).
* Output = lowercase hex of `acc` → **64 hex chars**, matching `^[a-f0-9]{64}$`.

Total: **120,000 HMAC-SHA256 invocations**. Runs in a separate isolate so the UI thread isn't blocked.

Verification is **constant-time** (`:95-103`):

```dart
Future<bool> checkProfilePin(LocalProfile profile, String pin) async {
  if (!profile.protected) return true;
  final actual = await hashProfilePin(pin, profile.salt);
  var difference = actual.length ^ profile.pinHash.length;
  for (var i = 0; i < actual.length && i < profile.pinHash.length; i++) {
    difference |= actual.codeUnitAt(i) ^ profile.pinHash.codeUnitAt(i);
  }
  return difference == 0;
}
```

Salt generation: `randomProfileToken()` = 16 `Random.secure()` bytes → 32 hex chars (`:71-77`). The same generator produces non-admin profile ids.

Pin length policy (`local_store.dart:809-811`): **6 to 128 characters** on set; there is no length check on verify.

### 6.3 Per-user source / download permissions

| Check | Code | Effect |
|---|---|---|
| source allowed | `allowsSource(source) = !locked && SourceSite.isAvailable(source) && profile.allows(source)` (`local_store.dart:123-126`) | gates catalog/search/history/favorites visibility, `setSource`, `setCatalogSource`, LAN record application |
| download allowed | `canDownload = !locked && (profile.admin \|\| profile.download)` (`:122`) | gates `mediaWatched`/`saveMediaWatch`, download preferences UI, merge queue items (`job.owner == store.profile.id`) |
| admin only | `_requireAdmin()` → throws `"仅管理员可以修改此设置"` | `setExportPosters`, `setAutoExport`, `setForceLogin`, `saveProfile`, `deleteProfile`, `exportBackup`, `importBackup`, `recoverBackup` |
| resource settings | `_allowed = profileEpoch == _epoch && !store.locked && store.profile.admin` (`resource_settings_screen.dart:96-98`) | network settings UI |

Note `SourceSite.isAvailable` is a **build-time** gate (hongguo-only vs all-sources), independent of the per-user `sources` list. Both must pass.

### 6.4 Backup / restore format

`exportBackup` (`local_store.dart:859-908`) — **schema 1**, `app: "zhenguojian"`:

```json
{
  "schema": 1,
  "app": "zhenguojian",
  "profiles": [ { "id": "default", "name": "管理员", "admin": true, "sources": [...], "download": true, "salt": "...", "pinHash": "..." } ],
  "displayMode": "auto",
  "themeMode": "system",
  "autoExport": false,
  "exportPosters": false,
  "forceLogin": true,
  "libraries": {
    "<profileId>": {
      "followSync": [ { "drama": {...}, "member": [...], "status": [...], "progress": [...], "known": 24, "read": 20 } ],
      "history": [ WatchEntry, ... ],
      "favorites": [ Drama, ... ],
      "followStates": { "<id>": FollowState },
      "seriesCandidates": [ Drama, ... ],
      "mediaHistory": { "<id>": WatchEntry },
      "source": "hongguo",
      "hideVip": true,
      "playback": { "speed": 1.0, "quality": 0, "autoAdvance": true, "danmaku": true, "preload": true,
                    "enhancement": { "mode": "off", "content": "automatic" } },
      "downloadPreferences": { "quality": 0, "includeVip": false },
      "catalogView": { "sort": "source", "release": "", "allSources": false },
      "recentSearches": ["..."]
    }
  }
}
```

**`followSync` is the LanRecord list**, serialized via `LanDocument.records.values.map(toJson)` (`local_store_sync.dart:4-13`). It is *not* the raw `lanRecords` blob — it drops the replica id and the document counter.

**Export guard** (`:903-906`): `utf8.encode(content).length > 8*1024*1024` → `"备份超过 8 MiB 保存上限，请先整理记录；尚未写出备份文件"`, then `validateBackup(content)` runs on the just-produced string before returning it.

**Validation** `validateBackup` (`:910-981`) — all must hold:
1. size ≤ 8 MiB
2. `schema == 1` **and** `app == "zhenguojian"`
3. `_readProfiles(data['profiles'])` succeeds (all per-record rules + aggregate rules)
4. `themeMode` ∈ `{light, dark, system}` if present
5. `forceLogin` is bool if present
6. per profile: `libraries[profile.id]` exists as a Map
7. `mediaHistory.length <= 300`, `history.length <= 300`, `favorites.length <= 20000`
8. every history/mediaHistory row parses as `WatchEntry`; every favorite/seriesCandidate parses as `Drama`
9. `followStates.length <= 20000` and every key is a String that is in the favorite id set; each value parses as `FollowState`
10. `seriesCandidates.length <= 2000`
11. `hideVip` is bool, `source` is String
12. `playback`/`downloadPreferences`/`catalogView` parse via their `fromJson`
13. `recentSearches.length <= 20`, every entry a String ≤80 runes
14. `followSync` (if present) is a List ≤ `LanDocument.limit`; every row parses as `LanRecord`; ids unique; **the set of `followed==true` ids must equal the favorites id set exactly** (`local_store_sync.dart:28-38`)

**Install** `_installBackup` (`:983-1043`) builds the complete `values` map and commits it with `replace: true` (wipes the snapshot), setting `activeProfile` to the admin profile. `followSync` is re-wrapped as `LanDocument(replica: lanID(), records: syncRecords).toJson()` — **a fresh replica id**, so the restored device becomes a new CRDT replica.

`importBackup` requires admin (`:1045-1048`); `recoverBackup` requires the config to be broken (`:1050-1085`).

### 6.5 First-run vs corrupt-config detection, lockout, recovery

**First run** (`local_store.dart:44-68`):

```dart
_snapshot = LocalSnapshot(preferences);
final raw = _snapshot!.getString('profiles');
if (raw == null &&
    (_snapshot!.getString('activeProfile') != null ||
     _snapshot!.values.keys.any((key) => key.startsWith('profile.')))) {
  throw const FormatException('已有用户配置缺失');   // ← partial state = corruption, not first run
}
_profiles = raw == null
    ? [const LocalProfile(id: 'default', name: '管理员', admin: true)]
    : _readProfiles(jsonDecode(raw));
```

The discriminator is **the presence of any other profile-related key while `profiles` is absent**. Clean first run ⇒ synthesize a single unprotected admin named `管理员`.

**Corruption detection** is `catch (_)` around the whole `_initialize` (`:65-67`) → `_block(...)`.

`_block` (`:88-100`) is the lockout:

```dart
void _block(String message) {
  _configurationError = message;   // "本地用户配置损坏，已锁定访问。原始记录已保留，请重新读取或从备份恢复。"
  _locked = true;
  _profiles = [const LocalProfile(id: 'default', name: '配置待恢复', download: false)];
  _current = 'default';
  _history.clear(); _favorites.clear(); _followStates.clear(); _seriesCandidates.clear();
  _epoch++;
}
```

Lockout effects: `locked => _locked || _configurationError != null`; `allowsSource` returns false; `canDownload` false; every getter that consults `locked` returns a safe default (`source` → `''`, `playbackPreferences` → const, `recentSearches` → `[]`, `hideVip` → `true`, `displayMode` → `'auto'`); all mutations throw.

Aggregate profile rules (`_readProfiles`, `:70-86`) that can trigger corruption:
* `profiles.isEmpty`
* `profiles.length > 20`
* duplicate ids
* `profiles.where(admin).length != 1` (exactly one admin required)
* `profiles.length > 1 && !adminProfile.protected` (multi-user requires an admin pin)

**Recovery flow** (`recoverBackup`, `:1050-1085`):

1. Reject if `_configurationError == null` → `"请从设置中恢复备份"` (must use normal import).
2. `validateBackup(content)`.
3. Try to read the **original** admin record out of the raw preferences (both the new `localSnapshot.v1` blob and a legacy bare `profiles` string):
   ```dart
   final raw = preferences.getString(LocalSnapshot.storageKey);
   final values = raw == null ? null : (jsonDecode(raw) as Map)['values'] as Map;
   final records = jsonDecode((values?['profiles'] as String?) ?? preferences.getString('profiles') ?? '[]') as List;
   for (final row in records) { if (row is Map && row['admin'] == true) { originalAdmin = LocalProfile.fromJson(...); } }
   ```
4. **Verifier selection**: `originalAdmin?.protected == true ? originalAdmin! : backupAdmin`. So if the corrupt config still contains a protected admin, the *original* password must be supplied; otherwise the *backup's* admin password is accepted.
5. If the chosen verifier is unprotected → `"无法验证管理员身份，请使用包含管理员密码的备份恢复"`.
6. `_checkPin(verifier, pin)` — subject to the same rate limit as any login.
7. `_snapshot ??= LocalSnapshot.empty(preferences)` then `_installBackup(data)`.

**Escape hatch**: `exportRecoveryData()` (`:1087-1098`) dumps every owned key verbatim:

```json
{ "app": "zhenguojian", "recovery": true,
  "values": { "localSnapshot.v1": "<raw string>", "profile.viewer.history": "...", ... } }
```

written to `<appSlug>-recovery.json` by `profiles_screen.dart:42`. This is *not* a `validateBackup`-compatible format — it's a raw rescue dump for manual recovery.

**Reload** (`:1100-1116`) re-reads prefs; if `profiles` and `activeProfile` are unchanged it preserves the previous `locked` state, otherwise it bumps `_epoch` (invalidating all queued writes).

**Login rate limiting** (`:742-756`):

```dart
Future<void> _checkPin(LocalProfile target, String pin) async {
  if (DateTime.now().isBefore(_retryAfter)) throw StateError('密码输入过于频繁，请稍后再试');
  if (!await checkProfilePin(target, pin)) {
    _failures++;
    if (_failures >= 3) {
      _retryAfter = DateTime.now().add(Duration(seconds: (_failures * 2).clamp(0, 30)));
    }
    throw StateError('密码不正确');
  }
  _failures = 0;
}
```

So: failures 1–2 have no delay; from the 3rd failure on, the cooldown is `failures * 2` seconds clamped to **30 s max**. Counters are **in-memory only** — restarting the app resets them.

### 6.6 Profile CRUD constraints

`saveProfile` (`:776-845`):
* admin required.
* name 1–40 chars.
* every source must be `isKnown`.
* creating/editing a non-`default` profile requires the admin to be `protected` → `"请先为管理员设置密码，再创建或修改其他用户"`.
* new profiles capped at **20** → `"最多支持 20 个本地用户"`.
* new profile id = `randomProfileToken()` (32 hex).
* `pin == null` ⇒ unchanged; `pin == ""` ⇒ clear (rejected if `targetId == 'default' && profiles.length > 1`); else length 6–128, new salt + hash.
* `admin: targetId == 'default'`.
* Sort order: admin first, then by `name.compareTo` (`:831-837`).
* Note: `sources` is *not* re-validated for the hongguo-only build, only `isKnown` — a restored foreign-source profile keeps its identity and permissions (`test/app_build_test.dart:75-99`).

`deleteProfile` (`:846-857`): admin required, `default` undeletable, removes the profile plus all `libraryKeys` for that id.

`switchProfile` (`:758-768`): refuses when `_configurationError != null`; `_checkPin(target, pin)`; commits `activeProfile`; sets `_current`; `_locked = false`; `_loadLibrary()`; `_epoch++`.

`lock()` (`:769-774`): no-op unless `profile.protected`; sets `_locked` and bumps `_epoch`.

`forceLogin` (`:116-120`): defaults to `admin.protected`, overridable by the global bool `forceLogin`; used to auto-lock on startup (`:63`).

---

## 7. Settings

### 7.1 Go core: resource / network settings

**File**: `<dataDir>/resource-settings.json` — schema in §1.4.

**Defaults** (`app_settings.go:27-29`):

```go
func defaultResourceSettings() nativeResourceSettings {
    return nativeResourceSettings{ProxyMode: "auto", CatalogConcurrency: 3, CatalogIntervalMS: 250, DownloadConcurrency: 2}
}
```

Note `DownloadBySource` defaults to `false` (zero value) and `ProxyURL` to `""`.

**Load** (`app_settings.go:85-105`) — a four-way classification that distinguishes missing from invalid:

```go
settings := defaultResourceSettings()
file := filepath.Join(engine.directory, "resource-settings.json")
info, err := os.Stat(file)
if err == nil {
    var stored nativeResourceSettings
    if info.Mode().IsRegular() && info.Size() <= 16384 {
        if data, readErr := os.ReadFile(file); readErr == nil && json.Unmarshal(data, &stored) == nil && stored.validate() == nil {
            settings = stored
        } else {
            settings.Warning = "网络与下载设置无法读取，已使用默认值，请重新保存设置"
        }
    } else {
        settings.Warning = "网络与下载设置无效，已使用默认值，请重新保存设置"
    }
} else if !os.IsNotExist(err) {
    settings.Warning = "网络与下载设置无法读取，已使用默认值，请重新保存设置"
}
engine.settings = settings
engine.applyResourceSettings(settings)
```

Key behaviors: a **missing file is silent** (no warning); a non-regular file, oversize file, parse failure, or validation failure all fall back to defaults **with a warning**. The invalid file is *not* deleted or rewritten.

**Validation and clamping ranges** (`app_settings.go:31-58`) — hard rejection, **no clamping**:

| Field | Rule | Error |
|---|---|---|
| `CatalogConcurrency` | `1..6` | `"并发应为 1 至 6，请求间隔应为 0 至 5000 毫秒"` |
| `CatalogIntervalMS` | `0..5000` | same |
| `DownloadConcurrency` | `1..6` | same |
| `ProxyMode` | `∈ {"auto","direct","manual"}` | `"代理模式无效"` |
| `ProxyURL` | if `mode=="manual"` **or** URL non-empty: `len <= 2048`; parseable; `Hostname() != ""`; **no fragment, no query**; path `""` or `"/"`; scheme `∈ {http, https, socks5, socks5h}`; port (if present) `1..65535` | `"代理地址过长"` / `"请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址"` / `"代理端口无效"` |

Note the condition: a non-empty `ProxyURL` is validated **even in `auto` or `direct` mode**.

**Save** (`app_settings.go:145-165`):

```go
settings.ProxyURL = strings.TrimSpace(settings.ProxyURL)
settings.Warning = ""              // runtime-only fields stripped
settings.SystemProxyStatus = ""
if err := settings.validate(); err != nil { return nativeResourceSettings{}, err }
engine.settingsMu.Lock()
defer engine.settingsMu.Unlock()
data, err := json.Marshal(settings)
if err == nil {
    err = nativeDownloadWrite(filepath.Join(engine.directory, "resource-settings.json"), data)
}
if err != nil {
    return nativeResourceSettings{}, errors.New("未能保存网络与下载设置，原设置保持不变")
}
engine.settings = settings
engine.applyResourceSettings(settings)
engine.downloader.client.CloseIdleConnections()
```

Failure ⇒ `engine.settings` is untouched, so the in-memory config stays consistent with disk. Success ⇒ the router and limiters are live-updated and idle HTTP connections are dropped so the new proxy takes effect immediately.

**Apply** (`app_settings.go:124-143`):

```go
router.mode, router.manual = settings.ProxyMode, manual
limiter.concurrency = settings.CatalogConcurrency
limiter.interval    = time.Duration(settings.CatalogIntervalMS) * time.Millisecond
limiter.notifyLocked()                    // wakes all waiters
engine.downloads.concurrency = settings.DownloadConcurrency
engine.downloads.bySource    = settings.DownloadBySource
engine.downloads.scheduleLocked()
```

**Proxy routing** (`app_settings.go:69-83`) — loopback always bypasses:

```go
func (router *proxyRouter) proxy(request *http.Request) (*url.URL, error) {
    if request.URL.Hostname() == "127.0.0.1" || request.URL.Hostname() == "localhost" || request.URL.Hostname() == "::1" {
        return nil, nil
    }
    ...
    switch mode {
    case "direct": return nil, nil
    case "manual": return manual, nil
    }
    return router.systemSettings().resolve(request)
}
```

**System proxy model** (`proxy_system.go:14-53`):

```go
type nativeSystemProxy struct {
    HTTP   string   `json:"http"`
    HTTPS  string   `json:"https"`
    Bypass []string `json:"bypass"`
    PAC    bool     `json:"pac"`
}
```

`resolve`: bypass list entries are lowercased/trimmed; `<local>` matches hostnames without a dot that aren't IPs; other entries go through `path.Match` against the hostname; then `HTTP` for `http`, `HTTPS` for `https`; if empty and `PAC` → error `"系统使用自动代理脚本，请在网络设置中配置手动代理或选择直连"`; if empty and no PAC → `http.ProxyFromEnvironment`. Re-read at most every **30 s** unless `systemOverride` is set (`:45-53`).

`updateSystemProxy` (`:55-80`): validates each of `HTTP`/`HTTPS` as a manual proxy URL, caps `len(Bypass) <= 1000` (`"系统代理排除列表过长"`), no-ops on identical config, then `CloseIdleConnections`.

`resourceSettings()` (`app_settings.go:107-122`) synthesizes `systemProxyStatus`:
* default: `"自动读取系统静态代理及环境变量"`
* `PAC && HTTP=="" && HTTPS==""`: `"检测到系统自动代理脚本；请配置手动代理或选择直连"`
* `HTTP!="" || HTTPS!=""`: `"已读取系统静态代理"`

**Important**: `resource-settings.json` is **global, not per-user**, and the proxy URL is explicitly excluded from the Dart backup (`resource_settings_screen.dart` helper text: `"支持 HTTP、HTTPS、SOCKS5；仅保存在本机，不进入配置备份。"`).

### 7.2 Dart: playback preferences

Per-user key `playback` (bare for admin, `profile.<id>.playback` otherwise). `lib/playback_preferences.dart`:

```json
{ "speed": 1.0, "quality": 0, "autoAdvance": true, "danmaku": true, "preload": true,
  "enhancement": { "mode": "off", "content": "automatic" } }
```

| Field | Type | Default | Validation |
|---|---|---|---|
| `speed` | double | `1` | must be **exactly** one of `[.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0]` (`playbackSpeeds`) |
| `quality` | int | `0` | `0 <= quality <= 4320` |
| `autoAdvance` | bool | `true` | — |
| `danmaku` | bool | `true` | — |
| `preload` | bool | `true` | — |
| `enhancement.mode` | enum string | `"off"` | `off\|automatic\|economy\|quality` |
| `enhancement.content` | enum string | `"automatic"` | `automatic\|general\|animation` |

Invalid speed/quality ⇒ `FormatException('播放偏好无效')`; unknown enum names **silently fall back** to `off`/`automatic` (`video_enhancement_preferences.dart:39-53`).

### 7.3 Dart: download preferences

Per-user key `downloadPreferences`:

```json
{ "quality": 0, "includeVip": false }
```

| Field | Type | Default | Validation |
|---|---|---|---|
| `quality` | int | `0` | must be in `[0, 1080, 720, 480]` (`DownloadPreferences.qualities`) |
| `includeVip` | bool | `false` | must be bool |

`quality == 0` renders as `"自动 · 优先高清"`, otherwise `"<n>P"` (`download_preferences.dart:6`).

### 7.4 Dart: catalog view

Per-user key `catalogView`:

```json
{ "sort": "source", "release": "", "allSources": false }
```

`sort` ∈ `source | name | season | date | heat | views` (unknown → `source`); `release` ∈ `"" | "finished" | "ongoing" | "unknown"` (unknown → `""`); `allSources` bool (`lib/catalog_sort.dart:15-52`).

### 7.5 Dart: per-user simple settings

| Key | Type | Default | Notes |
|---|---|---|---|
| `hideVip` | bool | `true` | `_bool(_key('hideVip')) ?? true` |
| `source` | string | first allowed source | rejected if not in `sources` |
| `recentSearches` | `[]string` | `[]` | ≤20, ≤80 runes each |

### 7.6 Dart: global settings

| Key | Type | Default | Admin-only |
|---|---|---|---|
| `displayMode` | `auto\|television\|standard` | `auto` | no |
| `themeMode` | `light\|dark\|system` | `system` | no |
| `autoExport` | bool | `false` | **yes** |
| `exportPosters` | bool | `false` | **yes** |
| `forceLogin` | bool | `admin.protected` | **yes** |
| `activeProfile` | profile id | `default` | via switchProfile |

Invalid enum values are **silently ignored on write** (`setDisplayMode`/`setThemeMode` return `Future.value()` when the value isn't in the allowed set) and **fall back on read**.

---

## 8. Source records / health

### 8.1 The per-source state machine

State lives in `nativeSourceRecord` (§1.4). The externally-visible projection is `nativeSourceStatus` (`app_sources.go:36-55`), which adds `Count`, `UnknownVIP`, `Page`, `HasMore`, `UpdatedAt`, `StorageError` from the catalog cache and save-error state.

**Operations** (`app_sources.go:172-179`):

```go
switch operation {
case "update", "more", "metadata", "vipMetadata", "check", "checkCatalog", "retrySave":
default:
    return nativeSourceStatus{}, errors.New("无效的站源操作")
}
if operation == "vipMetadata" && source != sourceHuangdou {
    return nativeSourceStatus{}, errors.New("当前站源不需要补齐 VIP 资料")
}
```

| Operation | Behavior |
|---|---|
| `update` | fetch page 1 (head), then up to `MaxPagesPerSort - 1` more tail pages, then metadata sweep |
| `more` | fetch **one** more tail page only, then return (`app_sources.go:303-305`) |
| `metadata` | metadata sweep only |
| `vipMetadata` | metadata sweep restricted to `VIP == nil` dramas; 黄豆 only |
| `check` | health check with playback probes (5 steps) |
| `checkCatalog` | health check without playback (1 step) |
| `retrySave` | **no network**; retries `catalogs.json` + `sources.json` writes (`app_persistence.go:106-115`) |

**Stage vocabulary** (exact strings, UI-visible): `"准备中"`, `"查找新剧"`, `"继续加载历史分页"`, `"补齐剧集资料"`, `"已完成"`, `"未完成"`, `"已停止"`, `"正在停止"`, `"已保存，可继续更新"`, `"等待保存"`, `"上次保存未完成"`, `"任务已中断"`, `"访问失败"`, plus health step names.

**Start** (`app_sources.go:167-216`) — the sequence of gates:

1. `nativeSourceAvailable(source)` → else `errNativeBuildSource` (`"当前版本不包含此站源"`).
2. operation whitelist (above).
3. if `drama.ID != ""`: `nativeDramaAvailable(drama)` **and** `sourceFromDramaID(drama.ID) == source`.
4. `retrySave` short-circuits before any locking.
5. **Idempotent dedup**: if a task already exists for this source, return the current status and **do not replace it** (`:190-194`). `TestSourceJobsDeduplicateCancelAndRecoverAfterRestart` asserts a second `check` while `update` runs leaves `Operation == "update"` and issues no extra request (`app_sources_test.go:143-148`).
6. **RetryAt gate**: `time.Now().Before(previous.RetryAt)` → `"站源暂时暂停请求，请在 %d 秒后重试"` with `max(1, int(time.Until(RetryAt).Seconds()+0.999))` (`:199-202`).
7. `ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)` — **3-minute hard task timeout**.
8. Record reset: `Operation`, `Running=true`, `Stage="准备中"`, `Completed=Total=Added=0`, `NeedsSave=false`, `Error=""`, `StartedAt=now`, `FinishedAt=zero`, `RetryAt=zero`. Persisted immediately.
9. `go engine.runSourceTask(...)`.

**Cancel** (`app_sources.go:218-229`): cancels the context, sets `Stage = "正在停止"`, returns the status. The task's deferred handler then sets `Stage="已停止"`, `Error="已保留更新内容，可稍后继续"`.

**Completion** (`app_sources.go:231-274`), in the deferred handler:

```go
record.Running, record.FinishedAt = false, time.Now()
record.Stage = "已完成"
if err != nil {
    record.Stage, record.Error = "未完成", publicError(err).Error()
    var persistence *nativePersistenceError
    if errors.As(err, &persistence) {
        record.NeedsSave, record.Error = engine.catalogSaveError != nil, ""
        record.Stage = "已保存，可继续更新"
        if record.NeedsSave { record.Stage = "等待保存" }
    }
    if errors.Is(err, context.Canceled) {
        record.Stage, record.Error = "已停止", "已保留更新内容，可稍后继续"
    }
    if errors.Is(err, context.DeadlineExceeded) {
        record.Error = "本次站源任务超时，已保留更新内容，可继续更新"
    }
    var backoff *requestBackoff
    if errors.As(err, &backoff) { record.RetryAt = backoff.until }
}
```

A panic is recovered and converted to `"站源任务处理失败，已保留缓存"` (`:234-236`).

`Added` is computed by a `defer` that diffs the item count before/after (`:279-282`): `record.Added = max(0, after - count)`.

### 8.2 Status projection quirks

`sourceStatusLocked` (`app_sources.go:132-153`):

```go
if warning != "" && !record.Running && stage == "已完成" {
    stage = "等待保存"
}
return nativeSourceStatus{
    Source: source, Count: len(engine.catalogs[source]), UnknownVIP: unknownVIP,
    Page: max(1, state.Page), HasMore: !found || state.HasMore,
    ...
    StorageError: warning,
}
```

* `warning` = `storageWarningLocked()` = dedup-joined `catalogSaveError` + `sourceSaveError` (`app_persistence.go:96-104`).
* `HasMore` is `true` when no state exists yet (`!found`).
* `UnknownVIP` counts `catalogs[source]` entries with `VIP == nil`, **only for 黄豆**.

### 8.3 Health check probes

`checkSource` (`app_source_health.go:54-192`) builds a `nativeSourceHealth`:

```go
type nativeHealthStep struct {
    Name       string `json:"name"`
    State      string `json:"state"`        // "ok" | "failed"
    Message    string `json:"message"`
    Host       string `json:"host,omitempty"`
    HTTPStatus int    `json:"httpStatus,omitempty"`
    ElapsedMS  int64  `json:"elapsedMs"`
    CFRay      string `json:"cfRay,omitempty"`
}
type nativeSourceHealth struct {
    CheckedAt time.Time          `json:"checkedAt"`
    State     string             `json:"state"`    // "checking" | "ok" | "catalogOnly" | "failed"
    Sample    string             `json:"sample"`   // drama title used for the playback probe
    Steps     []nativeHealthStep `json:"steps"`
}
```

**State transitions**: `"checking"` at start → on completion, `"failed"` if any step failed, else `"ok"` when `playback==true`, else `"catalogOnly"` (`:64-74`). `publish()` clones and persists the report to `sources.json` after **every step**, so a crash mid-check leaves a partial report.

**`checkCatalog` (playback=false)** — exactly 1 step:

1. `"入口与目录"`: `nativeCatalog(source, page=1, force=true)`. Fails if `Warning != ""`, or if `len(items) == 0` (`"入口可达，但没有解析到有效剧集"`). Success message: `"已解析 %d 部剧"`.

**`check` (playback=true)** — up to 5 steps:

1. `"入口与目录"` — as above. Abort on failure.
2. Sample selection (`:118-128`): use `selected` if provided, else the **first non-VIP item**, else `items[0]`. `report.Sample = drama.Title`.
3. `"分集目录"`: `GetHuangguoChapters(ctx, source, id)`; picks the **first non-VIP chapter**; message `"%d 集，检测第 %s 集"`. Fails with `"没有可用于检测的免费分集"` if all are VIP.
4. `"播放地址与播放列表"`: `resolveProviderMedia` then `sourceProbeResources` (HLS master → media playlist walk, **max depth 6**, only `AES-128` or `NONE` key methods, must yield a valid http(s) segment URL).
5. `"播放密钥"`: pass if `len(media.CENCKey) == 16 || len(media.HLSKey) == 16` (`"密钥长度有效"`); else if no `keyURL` → `"当前媒体无需额外密钥"`; else if `data:` URI → base64-decode, require exactly 16 bytes (`"内嵌密钥有效"`); else HTTP GET with a **17-byte** limit, require 16 bytes.
6. `"媒体连接"`: GET the segment with `Range: bytes=0-1023`, require non-empty body. Message: `"已读取媒体开头；实际播放效果请在播放器确认"`.

`sourceProbeBytes` (`:243-278`): 15 s timeout, `limit = 17` for keys else `1024` + `Range: bytes=0-1023`; accepts `200`/`206`; rejects `text/html` / `application/json` bodies via `catalogResponseBlockReason`; body limited by `io.LimitReader`.

**Progress reporting during a check** (`:76-82`): `record.Stage = <step name>`, `record.Completed = len(report.Steps)`, `record.Total = 5` for playback or `1` otherwise.

**Redaction**: step messages are `publicError(err).Error()` — URLs get query/fragment/userinfo redacted (see §10). `TestSourceHealthChecksHLSKeyAndBoundedMedia` explicitly asserts the persisted `sources.json` does **not** contain the preview token `"fixture-preview"` (`app_sources_test.go:231-234`).

### 8.4 Request backoff (source-level rate limiting)

`requestBackoff` (`network_limiter.go:19-33`):

```go
type requestBackoff struct {
    host   string
    until  time.Time
    status int
    reason string
}
func (backoff *requestBackoff) Error() string {
    seconds := max(1, int(time.Until(backoff.until).Seconds()+0.999))
    return fmt.Sprintf("%s HTTP %d%s，请在 %d 秒后重试", backoff.host, backoff.status, reason, seconds)
}
```

Triggered on `403`, `429`, or `Cf-Mitigated: challenge` (`observe`, `:196-201`). Delay: `Retry-After` seconds if parseable, else `Retry-After` HTTP-date if in the future, else **1 minute**; clamped to **30 minutes max** (`observeBlock`, `:203-220`).

Two maps: `backoffs` (foreground) and `backgroundBackoffs` (background). A background request that is **not** 429 writes to `backgroundBackoffs` instead — so background catalog work backs off without blocking the user's foreground browsing.

`backoff.until` is copied into `record.RetryAt`, which then gates `startSourceTask` and is surfaced as `retryAt` in `nativeSourceStatus`. `NativeRequest` maps it to `{"code": "source_blocked", "retryAt": <time>}` (`app_runtime.go:306-310`).

### 8.5 Global request limiter

`requestLimiter` (`network_limiter.go:80-98`) — per-**source** gates plus a global concurrency cap:

* `concurrency` and `interval` come from resource settings.
* Foreground vs background: background requests wait for `lastForeground + interval` and only run when `foregroundWaiting == 0 && active == 0` (`lowPriorityReady`).
* Each source has its own `requestGate{busy, lastStart}` so a single source is serialized even when global concurrency allows more.
* `notifyLocked()` closes/replaces the `changed` channel to wake all waiters when settings change.

Defaults from engine construction (`app_runtime.go:262`): `newRequestLimiter(3, 250*time.Millisecond)`.

---

## 9. Categories

### 9.1 Model

`nativeCategory{ID, Name}` (`app_categories.go:15-18`). The list is always led by a synthetic "all" entry with an empty id:

```go
all := []nativeCategory{{Name: "全部"}}     // ID == ""
```

Persisted in `catalogs.json` under `"categories"` as `map[source][]nativeCategory` (`engine.categoryOptions`).

### 9.2 Per-source provisioning

`nativeCategories` (`app_categories.go:79-166`):

| Source | How the list is produced | Network? |
|---|---|---|
| `hongguo` | static: `[全部] + hongguoAppGenres` → `short_play/真人剧`, `comic_series/漫剧`, `ai_series/AI剧` | never |
| `huangguoai` | static: `[全部] + nativeAICategories` (`ai-duanju/AI 短剧`, `ai-manju/AI 漫剧`, `ai-huanlian/AI 换脸`, `ai-mogai/AI 魔改`) | never |
| `huangdou` | static: `[全部]` only | never |
| `cloudfront` | `/api/app/playlet-tab/all` → `legacyTabList`, filtered by `validNativeCategory` | yes |
| `huangguo-video` | HTML scrape of `<base>/videos` via `parseHuangguoVideoCategories` | yes |
| `huangju` | `fetchHuangjuCategories` | yes |
| `yeguo` | `fetchYeguoCategories` | yes |
| `dsd` | `fetchDSDCategories(ctx, force)` | yes |
| `sorani` | static `soraniCategories`: `1/TV番剧`, `2/剧场动画`, `5/特摄剧场` | no (in-process) |
| `guipian` | static `guipianCategories` (**19** entries: `3/恐怖片`, `6/大陆鬼片`, `7/日韩鬼片`, `8/林正英鬼片`, `9/港台鬼片`, `10/泰国鬼片`, `11/欧美鬼片`, `31/剧情片`, `12/国产剧`, `13/美剧`, `14/韩剧`, `15/日剧`, …) | no |
| `hanxiaoquan` | static `hanxiaoquanCategories`: `1/最新韩剧`, `2/韩国电影`, `3/韩国综艺`, `4/韩国动漫` | no |
| duanju sources | `fetchDuanjuCategories(ctx, source)` | yes |
| anything else | error `"请选择有效站源"` | — |

### 9.3 Caching

```go
engine.mu.Lock()
cached := append([]nativeCategory{}, engine.categoryOptions[source]...)
engine.mu.Unlock()
if len(cached) > 1 && !force {
    return cached, nil
}
```

Cache is considered valid when `len > 1` (i.e. at least one real category beyond "全部"). `force=true` bypasses. Static sources bypass the cache entirely (they `return all, nil` before the cache check).

After a successful discovery, `engine.categoryOptions[source] = all` and `writeCatalogDiskLocked()` persists it. **A discovery failure does not poison the cache** — the error returns before the write (`:152-154`).

If discovery yields only "全部" → `"站源暂未返回内容分类，请稍后重试"` (`:155-157`).

### 9.4 Validation rules

`validNativeCategory(source, category)` (`app_categories.go:35-77`) — the **first** line of defense, and it is also the cache-namespace guard (the `|` in a category would forge a new catalog key):

```go
if category == "" { return true }
if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") { return false }
switch source {
case sourceHongguo:       // must be a hongguoAppGenres key
case sourceHuangguoAI:    // must be a nativeAICategories ID
case sourceHuangguoVideo: // strconv.Atoi > 0
case sourceCloudFront:    // must equal strings.TrimSpace(category) (no surrounding space)
case sourceHuangju:       // == huangjuNewestCategory ("@new") OR (validHuangjuID && !hasPrefix("@"))
case sourceYeguo:         // validYeguoCategory
case sourceDSD:           // webProviderNumericID
case sourceSorani:        // validSoraniCategory (len<=128, in fixed table)
case sourceGuipian:       // validGuipianCategory (len<=16, in fixed table)
case sourceHanxiaoquan:   // validHanxiaoquanCategory (len<=8, in fixed table)
}
if isDuanjuProviderSource(source) { return validDuanjuCategory(source, category) }
return false
```

Per-source extra constraints:
* `validHuangjuID` (`provider_huangju.go:21-24`): non-empty, `len <= 450`, already trimmed, not `"."`/`".."`, no `/ \ : ? # % | " < >`, no control chars.
* `validDuanjuCategory` (`provider_duanju.go:174-189`): `len <= 128`, no `| / \ \x00 \r \n`; for `heguo/xingguo/yaguo/maoguo/niuguo` the part before the first `-` must match `webProviderNumericID`; `fanguo/guanguo` accept anything; default accept.
* `validSoraniCategory`: `len <= 128` + fixed table.
* `validGuipianCategory`: `len <= 16` + fixed table.
* `validHanxiaoquanCategory`: `len <= 8` + fixed table.

Enforced at every entry point: `nativeCatalog` (`app_runtime.go:491-494`), the `cached` action (`:444-447`), and `categories`.

### 9.5 HTML category discovery

`parseHuangguoVideoCategories` (`app_categories.go:171-189`):

```go
var categoryAnchorPattern = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
var categoryTextPattern = regexp.MustCompile(`(?s)<[^>]*>`)
```

* href must parse and its path (trailing `/` stripped) must be `""` or `/videos`;
* `id` = `?category=` query value, must pass `validNativeCategory`;
* name = anchor text with tags stripped, HTML-unescaped, trimmed; must be non-empty and `<= 24 runes`;
* dedup by id (first wins).

`TestNativeCategoryDiscoveryUsesSourceLinks` asserts the exact behavior on a fixture with a duplicate, an unrelated path, and `?category=../bad` (`app_categories_test.go:60-73`).

### 9.6 AI category fan-out

`fetchHuangguoAICatalogPage` (`app_categories.go:191-241`) — when no category is selected, all 4 AI categories are fetched **concurrently through a 2-slot semaphore** (`slots := make(chan struct{}, 2)`), one page each:

```
<base>/api/videos/category/<id>?sort=hot&page=<p>&size=24
```

`more = more || len(result.items) >= 24 || result.err != nil` — note a **failure also sets HasMore**, so a partial failure keeps paging alive. Results are concatenated in **category order** (results slice indexed by category), and failures are `errors.Join`ed.

---

## 10. Diagnostics

### 10.1 What is logged

`diagnosticEvent` (`diagnostics.go:19-42`) — one JSON object per line:

| Field | JSON | Type | Notes |
|---|---|---|---|
| `Time` | `time` | RFC3339 | overwritten with `time.Now()` on every write |
| `Level` | `level` | string | `"info"`, `"warning"`, or default `"error"` |
| `Event` | `event` | string | see table below |
| `Message` | `message` | string | **required**; truncated to 4096 chars |
| `Source` | `source,omitempty` | string | |
| `DramaID` | `dramaId,omitempty` | string | |
| `DramaTitle` | `dramaTitle,omitempty` | string | truncated to 256 |
| `Episode` | `episode,omitempty` | int | |
| `Run` | `run,omitempty` | uint64 | |
| `HTTPStatus` | `httpStatus,omitempty` | int | |
| `Host` | `host,omitempty` | string | |
| `Client` | `client,omitempty` | string | e.g. `"Chrome 150"` |
| `Protocol` | `protocol,omitempty` | string | e.g. `"HTTP/2.0"` |
| `CFRay` | `cfRay,omitempty` | string | truncated to 128 |
| `ResponseType` | `responseType,omitempty` | string | Content-Type, truncated to 128 |
| `RequestedQuality` | `requestedQuality,omitempty` | int | |
| `Quality` | `quality,omitempty` | int | |
| `AvailableQualities` | `availableQualities,omitempty` | `[]int` | |
| `StartSeconds` | `startSeconds,omitempty` | float64 | |
| `OffsetBytes` | `offsetBytes,omitempty` | int64 | |
| `TotalBytes` | `totalBytes,omitempty` | int64 | |
| `Attempt` | `attempt,omitempty` | int | |

**Events actually emitted in this snapshot** (only four call sites):

| Event | Level | Where | Fields |
|---|---|---|---|
| `cover_failed` | `error` (default) | `app_covers.go:197` | `source`, `dramaId`, `message` |
| `stream_upstream_error` | `error` | `app_stream.go:295-299` | `host`, `message` = `"代理上游媒体失败: %v, url: %s"` |
| `stream_upstream_status` | `error` | `app_stream.go:310-314` | `host`, `httpStatus`, `message` |
| `network.browser_request` | `info` if `<400` and no CF challenge, else `warning` | `network_browser.go:206-212` | `source=huangguo-video`, `host`, `httpStatus`, `client`, `protocol`, `cfRay`, `responseType`, `message="黄果浏览器指纹请求完成"` |

Many `diagnosticEvent` fields (`Episode`, `Run`, `StartSeconds`, `OffsetBytes`, `TotalBytes`, `Attempt`, `Quality`, `AvailableQualities`, `RequestedQuality`) are **declared but never populated** in this snapshot — they're vestigial from a richer logging era. A Rust port can keep the schema for compatibility but only needs to emit the four events above.

### 10.2 Where and rotation

`newDiagnosticLog(directory)` (`diagnostics.go:51-53`):

```go
return &diagnosticLog{path: filepath.Join(directory, "logs", "app.log"), limit: diagnosticLogBytes}
```

* `diagnosticLogBytes = 5 * 1024 * 1024` (5 MiB)
* `diagnosticLogBackups = 2`

**Write** (`:55-88`): marshal → append `'\n'` → lock → reject if a single line exceeds the limit (`"单条诊断日志过大"`) → `MkdirAll(dir, 0700)` → `Stat` → **if `size + len(data) > limit`, rotate first** → `OpenFile(O_CREATE|O_WRONLY|O_APPEND, 0600)` → `Write` → `errors.Join(writeErr, file.Close())`.

So the log grows to just under 5 MiB, then rotates. Max on-disk footprint: `app.log` + `.1` + `.2` ≈ **15 MiB**.

**Rotation** (`:90-105`) — classic rename cascade, oldest first:

```go
oldest := log.path + ".2"
os.Remove(oldest)                                  // ignore ErrNotExist
for index := 2; index > 0; index-- {
    previous := log.path
    if index > 1 { previous += "." + strconv.Itoa(index-1) }
    os.Rename(previous, log.path+"."+strconv.Itoa(index))   // app.log → .1 ; .1 → .2
}
```

**No retention by age** — only by size and count.

**Write failure** is reported **once per process** via `sync.Once` to stderr, never recursively (`:122-126`):

```go
downloader.diagnostics.warningOnce.Do(func() {
    fmt.Fprintf(os.Stderr, "诊断日志保存失败：%v\n", publicError(err))
})
```

### 10.3 Redaction

Three layers.

**Layer 1 — configured secrets** (`redactConfiguredString`, `:107-114`):

```go
for _, secret := range []string{cfg.Token, cfg.AESKeyHex, cfg.InterfaceKey, cfg.ParamKey, cfg.ParamIV} {
    if secret = strings.TrimSpace(secret); secret != "" {
        value = strings.ReplaceAll(value, secret, "[redacted]")
    }
}
return redactErrorString(value)
```

Plain substring replacement of the five `Config` secret fields with the literal `[redacted]`.

**Layer 2 — URL scrubbing** (`redactErrorString`, `helpers.go:29-49`):

```go
var rePublicURL = regexp.MustCompile(`(?i)(?:https?|socks5h?)://[^\s"'<>]+`)

func redactErrorString(s string) string {
    return rePublicURL.ReplaceAllStringFunc(s, func(raw string) string {
        u, err := url.Parse(raw)
        if err != nil { return "[无效 URL 已隐藏]" }
        if u.Host == "" { return raw }
        if u.User != nil { u.User = url.User("redacted") }
        if u.RawQuery != "" { u.RawQuery = "[redacted]" }
        if u.Fragment != "" { u.Fragment = "redacted" }
        return u.String()
    })
}
```

So `https://user:pw@host/p?signature=abc#frag` → `https://redacted@host/p?[redacted]#redacted`. **Scheme, host, and path survive** — signed paths and hostnames remain visible (intentional: they're the debugging signal), but query strings (where signatures/tokens live) do not. Note `RawQuery` is set to the literal `[redacted]` which is *not* URL-escaped — the output is not guaranteed to re-parse.

**Layer 3 — public error wrapper** (`publicError`, `helpers.go:17-27`):

```go
func publicError(err error) error {
    if err == nil { return nil }
    return redactedError{cause: err}
}
type redactedError struct{ cause error }
func (err redactedError) Error() string { return redactErrorString(err.cause.Error()) }
func (err redactedError) Unwrap() error { return err.cause }
```

Because `Unwrap` is preserved, `errors.Is`/`errors.As` still work through the wrapper — `TestSourceBackoffUsesRelativeTimeAndRetainsTypedError` asserts exactly this (`app_sources_test.go:241-250`). This is why `record.Error` is always `publicError(err).Error()`.

**Additional field-level caps** applied before write (`recordDiagnostic`, `:116-127`):
* `Message` → `truncate(redactConfiguredString(...), 4096)`
* `DramaTitle` → `truncate(redactConfiguredString(...), 256)`
* `CFRay` → `truncate(..., 128)` at the call site
* `ResponseType` → `truncate(..., 128)` at the call site

`truncate` (`helpers.go:51-58`) is **rune-aware**, appends `"..."`, and trims first:

```go
func truncate(s string, n int) string {
    s = strings.TrimSpace(s)
    r := []rune(s)
    if len(r) <= n { return s }
    return string(r[:n]) + "..."
}
```

**What is NOT redacted**: drama IDs, source ids, hostnames, paths, HTTP status codes, `Cf-Ray` values (only truncated), and the literal text of Chinese error messages. Health-check step messages go through `publicError`, so they inherit layer 2. Download and cover paths are logged as absolute local paths in `stream_upstream_error` (`url: %s` with `asset.address`, which for local playback is a local path).

---

## 11. Rust port checklist — invariants that will bite

1. **Split the layer.** Users/permissions/library are Dart. Port them as a separate module with a single serialized snapshot store; do not expect the Go core to have them.
2. **`nativeDrama.VIP` must be `Option<bool>`.** `None` ≠ `Some(false)`. The `metadataSchema` migration exists only to repair pre-v1 黄豆 data.
3. **Cursor and items must be committed atomically.** `catalogs.json` contains both; a metadata-only write must *not* flush an in-flight cursor (test `TestNativeCatalogMetadataSaveExcludesInFlightCursor`).
4. **Never advance a page cursor on a failed save.** Rewind `Page` to the last durable value, set `HasMore = true`, `Fresh = false`, and retry the write before any network I/O.
5. **Merge is ID-keyed and order-preserving.** New IDs append; existing positions never move. Field merge is "fresh wins unless empty/`短剧`/`unknown`"; generic categories never beat specific ones.
6. **Per-category keys are `"<source>|<category>"`; the base key accumulates a union.** Category strings containing `|`, `/`, `\`, `\x00`, `\r`, `\n` must be rejected *before* they reach the key.
7. **`page` has no upper bound** (removed 6000/500 caps); the only ceiling is 32 MiB serialized. `max(1, page)` on input, and the source-loop guard at 1,000,000.
8. **Red-果 cursor has four guards**: `next > offset` (progress), `next <= 1_000_000`, `signature != previous signature` (stall), session length ≤4096 with no CR/LF/NUL; session TTL 30 min; at most 2 attempts with session reset between them.
9. **Atomic writes need directory fsync.** The Go code omits it — add `File::sync_all` on the file *and* `fsync` on the parent dir in Rust, or explicitly document the same weaker guarantee.
10. **No cross-process locking exists.** If the Rust port ever runs two processes, add a lockfile; otherwise inherit the single-process assumption.
11. **Every size limit must fail loudly with a distinct message** (`32 MiB` catalog, `4 MiB` sources, `8 MiB` rankings, `16 KiB` settings, `5 MiB` log, `256 MiB`/2000-entry cover cache, `20 MiB` cover file, `8 MiB` backup, `16 MiB` snapshot).
12. **Redaction is three-layered and must preserve `Unwrap` semantics** so `errors.Is`/`As` still detect `requestBackoff`, `context.Canceled`, and `nativePersistenceError` after wrapping.
13. **Health reports are persisted after every step**, so a partial report is a valid on-disk state. States: `checking` / `ok` / `catalogOnly` / `failed`.
14. **`retrySave` must not touch the network** and must bypass the `RetryAt` cooldown.
15. **The metadata sweep is rotating** (`MetadataCursor`, modulo wrap, batch of 8) with a 24 h re-check window, 5 min / 24 h (on "404") retry cooldowns, and abort after 2 accumulated failures.
16. **The admin PIN is 120,000 HMAC-SHA256 rounds with the pin as the HMAC key** — reproduce byte-for-byte or existing backups become unopenable.
