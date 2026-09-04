---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball Table Loading

How a `vpx` file is opened, read, and turned into a live table, at the code level.
This is the deep-dive behind the [architecture hub](vpinball-architecture.md).
It folds in two earlier research notes (a network-I/O audit and a post-load
bookkeeping study) and reconciles them against what actually shipped, because both
were written against a local branch whose approach was not the one that landed.

> Provenance. Front matter records the verified commit. Each major section ends
> with a `Verified against:` line. Confidence is marked inline: verified in code
> (with an anchor), from a commit or PR, or inference. Line numbers are jump
> hints; trust the symbol and the `verified_against` commit.

For the user-facing side, where companion files live and the folder-per-table
search order, see the repo's [`docs/FileLayout.md`](../vpinball/docs/FileLayout.md).
This doc stays on the read path and its performance.

## The container

A `vpx` file is a Microsoft OLE/CFB compound file: a mini filesystem of named streams
inside one file. VPX stores the table as many streams under a `GameStg/` storage,
`GameData` (the table record), `Version`, `GameItem<n>` (one per part),
`Image<n>`, `Sound<n>`, `Collection<n>`, `Font<n>`, plus info streams
(`TableInfo/*`, `CustomInfoTags`, `MAC`).

The reader is **POLE**, a small third-party CFB library vendored at
`third-party/include/pole/`. The entry point is `PinTable::LoadGameFromFilename`
(`src/parts/pintable.cpp`, def at line 1393): it opens
`POLE::Storage rootStorage(loadedFile.c_str())` (line 1414), reads `GameStg/Version`
to get the file-format version, then reads `GameStg/GameData` through a
`BiffReader` into the `PinTable`.

*Verified against: `src/parts/pintable.cpp` (`LoadGameFromFilename`), `third-party/include/pole/`.*

## POLE is now the reader on every platform

This is the single most important change from the older architecture, and it
invalidates a lot of prior notes. VPX used to split: `StgOpenStorage` (native
Win32 OLE) on Windows, POLE only on `__STANDALONE__`. At this commit **POLE reads
on every platform**. `LoadGameFromFilename` opens a `POLE::Storage` with no
`__STANDALONE__` branch, and the Win32 `StgOpenStorage` path survives only on the
**write/save** side (`pintable.cpp` lines 766, 840, 857) and in script-driven
saves (`ScriptGlobalTable.cpp`).

The unification landed in [`c12bb38f5`](https://github.com/vpinball/vpinball/commit/c12bb38f5)
("Use POLE library to read on all platforms"), a large rewrite of `pintable.cpp`.

Consequence for anyone reading older analysis: any finding scoped "Windows uses
StgOpenStorage, so this only affects macOS/Linux" is stale. The read path is one
path now. The `STGM_TRANSACTED` mode on the old Windows read open (which prior
notes flagged as a possible slowdown) is no longer on the read path at all.

*Verified against: `src/parts/pintable.cpp` (read vs write opens), `src/core/ScriptGlobalTable.cpp`.*

## The load pipeline

`LoadGameFromFilename` runs roughly in this order:

1. **Load table settings** for the table being opened (the `ini` override file), so
   settings apply during load.
2. **Open the container** and read `GameStg/Version`.
3. **Read `GameStg/GameData`** via `BiffReader` into the `PinTable`. This yields
   counts of sub-objects, sounds, textures, fonts, and collections
   (`m_loadTemp[0..4]`).
4. **Build a load queue** of every remaining stream to read (collections, game
   items, images, sounds, fonts), each as a `LoadTask { name, task }`.
5. **Sort the queue by physical offset** and dispatch it across a thread pool.
6. **Post-load bookkeeping**: resolve duplicate names, collection membership,
   layer/partgroup names, then `InitPostLoad`.

Collections are loaded before parts on purpose, to resolve name conflicts, this
was fixed in [`978de4ef2`](https://github.com/vpinball/vpinball/commit/978de4ef2)
("Load collection before unnamed part to avoid name conflicts").

*Verified against: `src/parts/pintable.cpp` (`LoadGameFromFilename` body).*

## Two deliberate reads, both for network storage

Streams in a `vpx` file are stored close to the reverse of the order the loader wants
them, and tables are increasingly served from a NAS over SMB. Two design choices
in the loader target exactly that:

**Physical-offset order.** The load queue is sorted by
`rootStorage.streamOffset()` (line 1617) so reads move forward through the file
instead of seeking backward. On a table whose streams are mostly backward-laid-out,
this is the difference between defeating and cooperating with OS readahead.

**One reader on network paths.** The pool is sized
`IsNetworkPath(m_filename) ? 1 : GetLogicalNumberOfProcessors()` (line 1620;
`IsNetworkPath` in `src/core/def.cpp`). Many threads reading scattered offsets of
one file over SMB is far slower than one thread reading sequentially, because
concurrent readers defeat readahead. So on a network path the reads serialize onto
one thread while parsing stays on the pool. This landed in
[`88dff1d2e`](https://github.com/vpinball/vpinball/commit/88dff1d2e)
("Load on a single thread when file is on a network").

**Trap.** These two only help because the payload is read essentially in full at
load, nearly every `GameItem`/`Image`/`Sound`/`Collection` stream is opened during
`LoadGameFromFilename`; almost nothing is deferred. That full read is the
irreducible floor; the offset sort and single-reader lower the *cost* of reading
it, they do not reduce *how much* is read.

*Verified against: `src/parts/pintable.cpp` (queue sort, pool sizing), `src/core/def.cpp` (`IsNetworkPath`).*

## History: the pre-read that did not ship

Prior research (see the retired `nas-io-performance-audit` note) explored two
other approaches on a local branch: a `BufferedIStream` decorator, and slurping
the whole `vpx` file into memory and running POLE off the buffer. A later draft,
[PR #3817](https://github.com/vpinball/vpinball/pull/3817), proposed a
producer/consumer pre-read: read each stream in offset order into a
`std::make_shared<vector<uint8_t>>`, hand the buffer to a pool worker that parses
from a `MemoryIStream`, and throttle the producer with a `maxBytesInFlight` cap.

**None of that shipped.** PR #3817 was closed unmerged (2026-08-31), and there is
no `MemoryIStream`, `maxBytesInFlight`, or `bytesInFlight` anywhere in `src/` or
`standalone/` at this commit. What survived from the whole line of work is the one
durable insight, read in physical-offset order, plus the network single-reader.
An even earlier whole-file slurp (`#3767`) was also abandoned.

If you are reading old notes or old branches: treat slurp, `BufferedIStream`, and
the in-flight byte cap as paths not taken. The shipped design is the plain
offset-sorted, per-stream, network-serialized reader above. This POLE-readahead
line is settled; it is not an open design question.

*Verified against: PR #3817 (closed unmerged), grep for `MemoryIStream`/`bytesInFlight` in `src/` and `standalone/` (absent).*

## Bulk reads are single-shot

Individual asset reads are already "open, read all, close", not incremental, so
there is no per-asset buffering win to chase:

- `read_file` (`src/core/def.cpp:569`) reads an entire file into a `vector<uint8_t>`.
- `PinBinary::ReadFromFile` (`src/parts/pinbinary.cpp`) is `m_buffer = read_file(...)`.
- `Sound::CreateFromFile` (`src/parts/Sound.cpp`) reads the whole file, and
  `CreateFromStream` reads a whole stream.
- Image decode is fully in memory: `BaseTexture::CreateFromFile`
  (`src/renderer/Texture.cpp:101`) reads via `PinBinary` then hands the buffer to
  `CreateFromData`.

*Verified against: `src/core/def.cpp`, `src/parts/pinbinary.cpp`, `src/parts/Sound.cpp`, `src/renderer/Texture.cpp`.*

## File integrity hashing (Windows only)

On non-standalone builds, load computes an MD2 hash over the BIFF data to validate
file integrity. It is set up in `LoadGameFromFilename` (`CryptCreateHash(hcp,
CALG_MD2, ...)`, line 1438) and fed as `BiffReader` reads
(`BiffReader::ReadBytes` / string reads call `CryptHashData`,
`src/utils/BiffReader.cpp:53,202`). A separate MD5 hash derives a decryption key
for unlocking old VP8/VP9 password-protected scripts.

The integrity hash is skippable: `Editor.DisableHash` (read at `pintable.cpp:1433`
as `GetEditor_DisableHash()`) turns it off for slightly faster loads. Standalone
builds have no `CryptoAPI` and so never hash, which the code comment notes makes
`DisableHash` "match standalone". So the hashing cost is a Windows-only concern,
and one the user can already opt out of.

*Verified against: `src/parts/pintable.cpp` (hash setup, `Editor.DisableHash`), `src/utils/BiffReader.cpp` (`CryptHashData`).*

## Trap: FlexDMD opens the `vpx` file a second time

The FlexDMD plugin reads images out of the table file independently of the main
loader. `VPXFile` (`plugins/flexdmd/resources/VPXFile.cpp:6`) constructs its own
`new POLE::Storage(path)` and BIFF-walks image stream headers, stopping at the
`DATA` tag (line 99) so it reads headers, not full payloads. It reuses one
`POLE::Storage` rather than re-opening per stream, so it is one extra open of the
file, not per-image, but it is a second independent reader of the same `vpx` file
outside the main load path. Worth knowing when reasoning about load-time file
access or first-touch open cost on network storage.

*Verified against: `plugins/flexdmd/resources/VPXFile.cpp`.*

## Known debt: post-load bookkeeping is O(n²) in three places

Once the streams are read, `LoadGameFromFilename` does name-resolution bookkeeping
that scales poorly on large tables. All three patterns below are **still present
at this commit**, none was upstreamed. An earlier note (the retired
`post-load-bookkeeping-optimization` study) measured these on a local build and
proposed fixes; the fixes did not land, so they remain live debt, not history.

1. **`PinTable::ParseScript`** (`pintable.cpp:4486`) dedupes script identifiers
   with a linear `FindIndexOf` over a `vector<string>` (the check at line 4547),
   O(n²) in identifier count. On a 20k-line table script this is a measurable
   slice of load time. The fix would be an `unordered_set`.

2. **`Collection::InitPostLoad`** (`src/parts/Collection.cpp:52`) resolves each
   collection member name by scanning *all* parts (`pt->GetParts()`) for a name
   match, O(N members × M parts). The table already maintains a name map
   (`m_scriptableNames`, an `ankerl::unordered_dense::map<wstring, IEditable*>` at
   `pintable.h:501`); routing membership resolution through it would drop this to
   near-linear. The map exists and is populated before collections resolve, so the
   fix is available and unused.

3. **Layer/partgroup resolution** (`pintable.cpp` ~line 1841) does a
   `std::ranges::find_if` over `m_vedit` per part that carries an expected
   partgroup name, another repeated linear scan. This constraint arrived with
   hierarchical `PartGroup` in 10.8.1 (see the code comment). A prebuilt
   `wstring -> PartGroup*` map before the loop would remove it.

These are independent, low-risk, behavior-preserving optimizations. They matter
most on large or network-loaded tables, where load time is already the pain point.

*Verified against: `src/parts/pintable.cpp` (`ParseScript`, layer resolution), `src/parts/Collection.cpp` (`InitPostLoad`), `src/parts/pintable.h` (`m_scriptableNames`).*
