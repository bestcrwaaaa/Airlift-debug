# The debug console, and the escape it rides on

This is the write-up for the part of AirLift Debug that is not the announcement
tooling: a console that reads, writes, imports, exports and selects the contents of
files on the device, using exactly the same vulnerability the original app used to
replace the call-recording announcements.

Nothing new is exploited. The escape is the one `airlift` found; this fork only changes
the *shape* of what comes back.

---

## 1. The one primitive everything rests on

The AirTraffic escape is not a read/write primitive. It is a **move** primitive.

An app can hand the device a file through `com.apple.streaming_zip_conduit` — that part
is ordinary AFC, and it can only write inside the app's own container. The interesting
part is what happens afterwards:

1. The app stages a StreamingZip archive in the device's **Media** volume
   (`/var/mobile/Media/airlift-src-<token>/`). The archive carries:
   - `p0/p1/p2/link` — a **symlink** to a directory outside the sandbox;
   - `payload` — the file the app wants to place.
2. The app writes `Books/Sync/Books.plist`, which points the *Book* dataclass at those
   two objects, and talks `com.apple.atc` into a sync session (with a Grappa token, on
   iOS 27.0.1+).
3. For every asset, the app sends a `FileComplete` message that says "this object is
   now at *that* path". `ATAirlock` — the daemon that owns the Media ↔ Book handover —
   **follows the symlink** and creates the payload at the real destination.

So the whole capability is: *the app can make the system place a file it controls
somewhere the app itself may not write*. The symlink is the lever.

```
   app (sandboxed)                device
   ┌──────────────┐   stage    ┌──────────────────────────────┐
   │  payload     │──────────▶ │ /var/mobile/Media/          │
   │  symlink ────┼──┐         │   airlift-src-<token>/      │
   └──────────────┘  │         │     p0/p1/p2/link ──────┐   │
                     │         │     payload            │   │
   FileComplete ─────┼─────────┼───────────────────────┼───┼──▶ ATAirlock
                     │         └───────────────────────┘   │
                     │                                     ▼
                     │            /var/mobile/Library/…/file
                     └──────────────────────────────────▶  (outside the sandbox)
```

### Writing

`exploit_write_single_file()` (Rust core, `rust-core/src/exploit.rs`) implements the
diagram above. The destination is `target_dir` + `leaf`, so the directory is the
symlink's target and the file name is the payload's name inside it.

### Reading

Reading is the same trick pointed the other way. ATAirlock will *also* move an existing
file out of its directory and into Media when the app asks for it that way, so:

1. stage the same symlink trick, but point the second asset at the **target file**
   rather than at a payload;
2. ATAirlock relocates the file to `/var/mobile/Media/airlift-recovered-<token>`;
3. the app reads it over AFC — ordinary file I/O inside Media;
4. the app writes it straight back with the proven writer, so the device is left as it
   was found.

Step 4 is why the upstream read path returns a **digest** rather than the bytes: the
bytes never have to cross the C ABI.

---

## 2. What this fork added

The console needs three things the announcement tooling never did.

### 2.1 The bytes, not the digest

`al_exploit_read_file_hash()` returns size + SHA-256. The console wants the content, so
this fork adds:

```c
int32_t al_exploit_read_file_bytes(const char *pairing_path,
                                   const char *target_dir,
                                   const char *leaf,
                                   ALLogCallback log_cb, void *ctx,
                                   char **out_hex, uint64_t *out_size,
                                   char **out_warning, char **out_error);
```

Two decisions worth naming:

- **The bytes travel as hex.** A C string cannot carry NUL bytes, and the alternatives
  (a raw pointer plus a length, or a second allocation) mean the caller has to free
  something on every path out of the function, including the error paths. Hex costs two
  characters per byte and removes every special case. The cap is 8 MiB — a limit of the
  string in memory, not of the device.
- **A failed write-back is a warning, not an error.** The upstream read path did
  `exploit_write_single_file(...).await?` — so if the file could not be written back, the
  read was reported as a failure and the bytes were dropped, even though they had been
  read successfully. For a *hash* that is the right trade (nothing was lost). For the
  console it is not: the file has already been moved out of its directory, so throwing
  the bytes away destroys the only copy. The read now returns the bytes plus a warning,
  and the console shows both.

```rust
let warning = match exploit_write_single_file(...).await {
    Ok(()) => None,
    Err(e) => Some(format!("{target_path} was read but could not be written back: {e}")),
};
```

### 2.2 A write to an arbitrary path

The upstream writer takes a **directory** of staged files and pushes all of them. The
console has one file, whose bytes came from the editor, from the Files app, or from a
previous read. So:

```c
int32_t al_exploit_write_file_bytes(const char *pairing_path,
                                    const char *target_dir, const char *leaf,
                                    const char *payload_hex,
                                    ALLogCallback log_cb, void *ctx,
                                    uint64_t *out_written, char **out_error);
```

The Rust side decodes the hex, connects the tunnel, snapshots `Books/Sync/Books.plist`,
calls the *unchanged* `exploit_write_single_file()`, and restores the Books state. The
proven writer stays proven — the console did not get a second, weaker write path, it got
a different way of feeding the same one.

### 2.3 A listing

```c
int32_t al_exploit_list_dir(const char *pairing_path, const char *path,
                            ALLogCallback log_cb, void *ctx,
                            char **out_json, char **out_error);
```

This one does **not** use the escape. It is plain AFC over the same tunnel:
`AFC_OP_READDIR` plus `AFC_OP_GET_FILEINFO` per entry, returned as JSON.

The reason it is limited is worth stating plainly: **AFC is rooted at the device's
Media volume.** `/var/mobile/Media` and everything under it is browsable. The rest of
the filesystem is reachable *one file at a time, by path*, through the escape — but the
device offers no way to enumerate it. So the console has two different notions of
"browse", and the UI says which one it is using.

---

## 3. The Swift side

Three files, in `ios-app/`:

| File | What it is |
|---|---|
| `DebugEngine.swift` | The FFI surface: read, write, list, hex codec, path splitting. No UI. |
| `DebugViewModel.swift` | The state: path, content, payload source, selection range, log. Every device call is blocking and runs off the main thread. |
| `DebugConsoleView.swift` | The console itself. |

### Path handling

The exploit needs a **directory** and a **bare file name** — the symlink points at the
directory, the payload lands inside it. `DebugEngine.split()` does that, and refuses
anything that is not an absolute path, so a typo cannot turn into a write to `/`.

### Payload sources

Write and export take their bytes from one of three sources:

- **Editor** — the text editor's content, UTF-8.
- **Imported** — the file picked from the Files app.
- **Device** — the bytes of the last file read off the device.

### Selecting content

The console keeps a character range (`selectionStart` … `selectionEnd`) over the editor
content. It can copy that range, keep only that range, or write **only** that range to
the device — which is the operation that makes the console pleasant to use: pull one
line out of a plist on the device, paste it somewhere else, or write one value back.

The range is stored as offsets rather than as a `TextSelection`, because the console
has to work on content that is not valid UTF-8 (a hex dump) and because a numeric range
survives a round trip through the editor.

### Serialisation

The device tolerates one exploit session at a time. The console refuses to start while
the announcement screen is running, and vice versa, instead of queueing behind it.

---

## 4. What this is good for, and what it is not

**Good for:**

- Inspecting the files a jailbroken-style escape can reach: preferences, caches, the
  announcement folder, the Media volume.
- Patching one value in a plist on the device, from the phone, without a computer.
- Reproducing the upstream research: the escape is the interesting part, and a console
  that can read a file's *content* is a much better instrument than one that can only
  compare hashes.

**Not for:**

- Touching a sealed system volume. `recurringDisclosureTwinkle.caf` lives in
  `TelephonyUtilities.framework` on the sealed volume; the escape cannot replace it,
  and neither can the console.
- Touching somebody else's device. This is a research tool that writes outside the
  sandbox; it is only ever a good idea on a phone you own.
- Being a reliable editor for a file the daemon regenerates. iOS rewrites the
  announcements when the configuration it expects changes — see the upstream README.

---

## 5. Notes for a defender

If the interesting question is what to do about the escape itself:

- **The symlink is the bug.** `ATAirlock` follows a symlink that arrived through a
  Book-sync `FileComplete` message, and the payload then lands wherever the symlink
  points. Validating that the destination of a completed asset is inside the Media
  volume would close it. Apple patched the underlying `airlift` exploit in iOS 27.2
  beta 3; the specifics of that fix are not public.
- **The escape needs a pairing record and a loopback tunnel.** It is not a
  zero-click, network-facing bug: the app has to be paired with the device and the
  device has to be reachable over the tunnel. Treat the pairing file as a credential —
  it is one, and it grants full device access.
- **A debug console multiplies the impact of a bad build.** The upstream app can only
  write three known files. This fork can write any path the escape reaches. Both are
  sideloaded builds that the user chose to install, and both are unsigned by design —
  but a console that takes a path from a text field is a much larger surface than one
  that does not.

---

## 6. References

- `airlift` — Johnny Franks: the original PoC and the ATAirlock analysis
  (<https://github.com/0xjohnnydev/airlift>)
- `AirCard-iOS` — Mak5er: the loopback tunnel, the Rust FFI core, the Grappa tokens
  (<https://github.com/Mak5er/AirCard-iOS>)
- `idevice` — the RSD/AFC/streaming_zip_conduit plumbing
  (<https://github.com/jkcoxson/idevice>)
- `AirliftSilence-iOS` — the upstream this fork starts from
  (<https://github.com/YiHoooong/AirliftSilence-iOS>)
