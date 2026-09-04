---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball DMD Colorization: Formats and History

The DMD colorization formats and their community history, behind the `serum` and
`vni` plugins. This is a companion deep-dive to the
[architecture hub](vpinball-architecture.md); the plugin wiring that consumes these
formats (source override, the display bus) is in the
[plugin-system deep-dive](vpinball-plugin-system.md). Nothing here is required to
build or run VPX.

Unlike the other deep-dives, most of this doc is about **external** projects
(Pin2DMD, dmd-extensions, libserum/libvni) and community history, not VPX's own
code. So its `verified_against` marker covers only the VPX-side code claims (the
`vni`/`serum`/`dmdutil` plugins at `c321a1812`); the format internals and history
are sourced to the upstream repos and forum threads named inline, and those
citations are the provenance for that material.

> Provenance. Front matter records the commit the VPX-side claims were verified
> against. The `Sources` section and inline citations are the provenance for the
> format and history material. Confidence is marked throughout by the sourcing
> convention below.

**Sourcing convention used throughout.** Format and code details are taken from reading source, with
the file or commit named. Community history is taken from the VPUniverse threads linked inline, read
directly; those record what participants stated, and are attributed to the speaker rather than
presented as established fact. Where something could not be determined it is marked unresolved rather
than inferred. No expansion of the "VNI" acronym is asserted, because none was found.

## What colorization operates on

The ROM emits a monochrome indexed frame: shade indices, not colour. In libvni's API the frame is
`const uint8_t* frame` of `width * height` indexed pixels plus a `bitlen`, and the palette is
`(1 << bitlen) * 3` bytes of RGB triples.

Frame sizes seen in these formats: 128x32 is the common case; libvni carries explicit handling for
128x16 (`jsm174` commit [`44375cf`](https://github.com/PPUC/libvni/commit/44375cf1e9d25c7063e52068f6915cb7a3c888d6)); `plugins/dmdutil` rejects sources above 256x64. zedrummer's post
describes 128x32 as usual with 192x64 and 256x64 as rare.

Both plugins in this repo obtain the frame via `dmdId.GetIdentifyFrame(...)`, compare `frameId` to
detect change, and run a colorize thread on a fixed 16666 us tick. Both formats match a frame against
an author-prepared database and apply the associated result; the mechanisms differ and are described
per format below.

## Two lineages

Colorization split into two independent format families that never merged.

```
PIN2DMD lineage                            Serum lineage
  pal                                        cRZ
  pal + vni    (virtual pinball)             cROMc
  pal + fsq    (real pin, SD card)
  pac          (encrypted, from 2022)
       |                                           |
   plugins/vni                              plugins/serum
   via libdmdutil -> PPUC/libvni            via libdmdutil -> PPUC/libserum
```

Rough dating, anchored on repository creation: the Pin2DMD editor repo dates to January 2015 and the
PIN2DMD hardware repo to May 2016 (the projects themselves may predate their GitHub presence). PAC
appeared mid-2022. `PPUC/libserum` was created in December 2022, making Serum the much later arrival
despite now being the default.

Both arrive in VPX through the same gateway: this repo pins `LIBDMDUTIL_SHA`, and libdmdutil's own
`platforms/config.sh` pins `LIBVNI_SHA` and `LIBSERUM_SHA`. Neither colorizer is built here. See the
dependency tree in the [architecture hub](vpinball-architecture.md#transitive-pins).

## The PIN2DMD lineage

### Origin

[lucky01/PIN2DMD](https://github.com/lucky01/PIN2DMD) is a full-colour LED DMD controller for real and
virtual pinball machines, started by Lucky1 and joined shortly after by Steve45 as co-author. It is
hardware first; the file formats exist to feed that hardware.

The authoring tool is the **Pin2DMD Editor**, which lives in
[sker65/go-dmd-clock](https://github.com/sker65/go-dmd-clock), a Java project by Stefan Rinke whose
original target was a "goDMD" clock, not pinball. That history is still visible in the code: when
the editor writes a colorization for virtual pinball it names the variable `aniFilename` and simply
swaps the extension to `vni`, carrying over from the clock's `ani` animation files.

Support for virtual pinball came later, through
[freezy/dmd-extensions](https://github.com/freezy/dmd-extensions) (`dmdext`), whose `LibDmd`
component implemented a C# reader for PAL/VNI. That C# reader is the direct ancestor of the code VPX
uses today.

### What "VNI" means

**Unresolved.** No source found expands the acronym: not the Pin2DMD editor source, not
dmd-extensions, not libvni, not the Pin2DMD documentation. What is verifiable:

- A `vni` file's first four bytes are the ASCII string `VPIN`, not `VNI`. Checked in the magic
  comparison of all three readers.
- `freezy/dmd-extensions` names its reader class `VniFile` and logs it as
  "virtual animation file" (`VniLoader.cs`).
- The Pin2DMD editor derives the output filename by taking a variable it calls `aniFilename` and
  replacing the extension with `vni` (`ProjectHandler.java`).
- Pin2DMD's documentation states that for virtual pinball you get two files, a `pal` and a `vni`.

No expansion of the three letters is asserted here.

### PAL, the mandatory half

The `pal` file carries the palettes and the matching database:

- One or more palettes, one flagged as default.
- **Mappings** keyed by a CRC/checksum of a single bit plane of the identifying frame. A mapping
  says what to do on a hit: switch palette, or jump to an animation in the companion `vni`.
- Optional **masks**. When a plain plane checksum misses, the matcher retries with each mask
  applied, so an author can key on a stable region of a frame and ignore a changing score.

Everything a colorization strictly needs is in the PAL. A bare palette table with no keyframes is
the SmartDMD case, where a patched ROM signals palette changes in-frame. See
**SmartDMD: patched-ROM colorization** below for a full treatment of that mechanism, its scope
(Stern SAM/Spike only), and its history.

In `libvni` this asymmetry is explicit: `Vni_LoadFromPaths` ends with `if (!ctx->pal) return nullptr;`,
and has no equivalent check for the VNI. **A `vni` without its `pal` fails to load; a `pal` alone
loads.** `VniLoader.cs` behaves the same way, exposing `FilesExist` as
`_pacPath != null || _palPath != null`, so the VNI path is not consulted.

### VNI, the optional half

The `vni` file holds replacement animation frames, full RGB artwork substituted for the ROM's
output, rather than just a recolouring of it.

Structure, per libvni's reader:

| Element | Detail |
|---|---|
| Magic | `VPIN` (4 bytes ASCII) |
| Version | `uint16` big-endian |
| Animation count | `uint16` big-endian |
| Offset table | Present only when version >= 2; one `uint32` per animation |
| Animations | Sequences of frames, each with a delay; frames stored as **bit planes**, not packed pixels |
| Compression | Optional per frame, **heatshrink** with window 10 / lookahead 5 |

All multi-byte fields are big-endian. Animations are located by byte offset. A mapping in the PAL
references an animation by its offset in the VNI, which is why the reader records `seq.offset` as it
parses.

Frame storage and PAL matching use the same unit: frames are stored as bit planes, and PAL mappings
are keyed on the checksum of a bit plane. libvni's decoder calls
`FrameUtil::Helper::ReverseByte` via its `reverse_bits` helper, and `find_mapping` takes a `reverse`
flag, so plane checksums are computed in both bit orders.

### FSQ

The real-pin counterpart to `vni`, consumed from the Pin2DMD device's SD card. No code in this
repository reads it, and no open reader for it was found. Included here because the Pin2DMD editor
repository carries a **primary-source format specification** at
[`doc/README.md`](https://github.com/sker65/go-dmd-clock/blob/master/doc/README.md), which documents
FSQ alongside its companion files. Everything in this subsection comes from that document and from the
editor's Java source.

**Conventions the document states apply to all of these files:** every binary number is big-endian,
MSB first; colours are 3-byte RGB; frames are stored as a raw uncompressed pixel map, plane by plane,
least-significant plane first, left pixel is high-significant-bit, which it likens to the PPM image
format; and every repeated structure named with a `SeqOf` prefix begins with a count of the structures
that follow.

`pin2dmd.fsq`, "all sets of replacement frames sequences that can be used in key frame mappings":

| Level | Field | Type | Notes |
|---|---|---|---|
| file | `SeqOfFrameSequences` | int16 | count of frame sequences |
| sequence | `SeqOfFrames` | int16 | count of frames |
| frame | `Index` | int32 | documented as "delay in ms for this frame to be displayed" |
| frame | `NoOfPlanes` | int16 | number of planes / subframes |
| frame | `SizeOfPlane` | int16 | bytes per plane |
| frame | `PlaneData` | `NoOfPlanes * SizeOfPlane` bytes | all planes, LS plane first |

Note the `Index` field: named as an index, documented as a per-frame delay in milliseconds.

Two structural points worth setting against VNI:

- **FSQ frame data is raw and uncompressed.** VNI supports optional per-frame heatshrink compression.
- **Sequences are addressed by absolute file offset**, resolved from the palette file rather than from
  a table inside the FSQ itself. VNI is also offset-addressed (libvni records `seq.offset` while
  parsing), so both lineages share that approach.

### The real-pin companion files

The same document specifies the two files that accompany FSQ on the device.

`palettes.dat` carries palettes *and* the key-frame database, the role the `pal` plays on the vpin
side. `Version` is int8 and the document says it is "actually 1". Then `SeqOfPalettes` (int16) of
palettes, each with `Index` (int16), `NoOfColors` (int16), `Type` (int8; 0 normal, 1 default, and only
one palette per file may be marked default) and `NoOfColors * 3` bytes of RGB. After the palettes comes
`SeqOfKeyFrameMappings` (int16), each mapping being:

| Field | Type | Notes |
|---|---|---|
| `Hash` | 16 bytes | **md5 hash of the key frame** |
| `PaletteIndex` | int16 | palette to switch to |
| `Offset` | int64 | offset into the FSQ for a replacement sequence, or 0 for palette switching only |
| `Duration` | int16 | time until switching back to the default palette; 0 means never switch back |

**This differs from what libvni reads.** libvni's PAL reader keys its mappings on a 32-bit plane
checksum (`checksum_plane`, with an optional mask retry and a `reverse` bit-order flag), not on a
16-byte MD5. The documented spec is version 1; whether the vpin `pal` diverged later, or whether the
two targets always used different matching, was not determined.

`pin2dmd.dat` holds device-level settings: `DeviceMode` (int8; 0 pinmame rgb, 1 pinmame mono, 2 wpc,
3 stern), `DefaultPaletteIndex` (int8), an 8-byte `CustomSmartDMDSig`, and optional display timing as
five int16 values, `Total` plus `DutyPlane0` through `DutyPlane3`. The SmartDMD signature field is the
device-side counterpart to the patched-ROM SmartDMD case.

### Editor observations on the export path

From the editor's Java source, at commit [`842d975`](https://github.com/sker65/go-dmd-clock/commit/842d975100b62eb20086dd0d3a38f67d899f4344):

- **FSQ has two export generations.** `ProjectHandler.java` calls
  `exporter.writeFrameSeqTo(dos, frameSeqMap, useOldExport ? 1 : 2)`, so the writer is parameterised by
  a format version of 1 or 2. What differs between them is not visible here (see below).
- **Filenames differ between disk and device.** The specification names the files `pin2dmd.dat` and
  `palettes.dat`, but `LivePreviewHandler.java` uploads them to the device as `pin2dmd.pal` (from
  internal `a.dat`) and `pin2dmd.fsq` (from internal `a.fsq`). The `pal` on a Pin2DMD device is
  therefore the `palettes.dat` structure under a different name.
- **Colour depth is reduced on export.** `ProjectHandler.java` logs that a 24-bit scene will be reduced
  to 15-bit and drops six planes to do it (`planes.remove(5)` three times, then `planes.remove(10)`
  three times).
- **The writer itself is not in the repository.** `ProjectHandler.java` imports
  `com.rinke.solutions.pinball.api.BinaryExporter` and obtains it from `BinaryExporterFactory`, but the
  `com.rinke.solutions.pinball.api` package does not exist in the source tree; the POM declares custom
  Maven repositories (`go-dmd.de/maven`, `sker65/mvn-repo`) from which it is resolved as a binary
  artifact. So the editor is public while the component that actually serialises PAL, VNI and FSQ is
  not.

## PAC: the encrypted container

### What it is

PAC is a container holding PAL and VNI payloads, each gzip-compressed, then AES-128-CBC encrypted, in
a chunked wrapper. The inner payloads are parsed by the same PAL and VNI readers used for the
unencrypted files, unchanged.

```
Offset  Size      Field
0       4         Magic: "PAC " (ASCII, note the trailing space)
4       1         Version byte (1 or 2; see PAC v2 below)
5       ...       Chunk sequence

Each chunk:
  +0    2         Type, uint16 big-endian   (1 = PAL, 2 = VNI)
  +2    4         Length, uint32 big-endian
  +6    Length    Ciphertext (v2: bit-permuted, see below)
```

On chunk length, the C# reference applies no length check on the v1 path; on the v2 path it requires a
multiple of 4, enforced inside `DecodePacV2` rather than at the header. On chunk count, it reads at
most two chunks.

Per chunk (v1): decrypt AES-128-CBC, then gunzip the plaintext (standard gzip, `1f 8b`), then hand the
result to **the ordinary PAL or VNI reader, unmodified**. The inner formats are byte-identical to
their unencrypted counterparts.

**The IV equals the key.** The same 16 bytes are passed as both key and initialisation vector. The C#
reference does so explicitly: `aes.Key = key; aes.IV = key;`, with `PaddingMode.Zeros`.

### PAC v2

**Two container versions exist.** A second version appeared in 2026 and adds a transform applied on
top of the v1 ciphertext.

Handling differs by implementation, so the version byte matters:

| Implementation | Version byte | v2 |
|---|---|---|
| dmd-extensions `master` ([`e54b2397`](https://github.com/freezy/dmd-extensions/commit/e54b2397cedfbf69240872d5f5b53de6c9e21259)) | read, unused except in a log line | not handled |
| dmd-extensions [`core`](https://github.com/freezy/dmd-extensions/tree/core) ([`f8f9791`](https://github.com/freezy/dmd-extensions/commit/f8f97915099860c20c81240fc5a06c49a77e5a02)) | read and **validated**: `if (version > LatestPacVersion) throw` | handled |

So the version byte is never validated on `master`, but on `core` it is, where
`LatestPacVersion = 2` and anything higher is rejected.

The v2 transform, from `DecodePacV2` in `VniLoader.cs` on `core`:

- Requires the encrypted chunk length to be **a multiple of four bytes**, else
  `InvalidDataException`.
- Walks the chunk in four-byte words. For each word it reverses the bit order of each byte *and*
  reverses the byte order within the word, so `data[i] = ReverseBits(data[i+3])`,
  `data[i+1] = ReverseBits(data[i+2])`, and so on. `ReverseBits` is a standard nibble/pair/single
  swap on a byte.
- Runs **before** AES decryption, restoring the v1 ciphertext.

Two properties are evident from the signature and body: `DecodePacV2(byte[] data)` **takes no key**,
and the operation is its own inverse. The source comment states both. It is a fixed, keyless bit
permutation, so it adds no key material and no additional secret. The same published `vni.key` still
decrypts the AES layer underneath.

The `core` version of `LoadPac` also wraps the `BinaryReader` in a `using` block and reads chunk
payloads with `ReadBytesRequired(len)` rather than `ReadBytes(len)`.

Only dmd-extensions `core` handles v2. `master` reads the version byte but does nothing with it, so a
PAC v2 file fed to `master` would reach AES with permuted ciphertext.

### The key

The key is 16 bytes, supplied as 32 hex characters. It is **a single global constant, not per-user
and not per-file.** One value decrypts every PAC colorization ever published.

It is not secret. freezy published the value himself, in the body of the
[dmdext v2.2.0 release announcement](https://vpuniverse.com/forums/topic/9051-new-release-v220-final/),
as the `vni.key` line users must add to `DmdDevice.ini` for dmdext's built-in PAC support to work. The
same value is what every dmdext installation has used since. Configuration surfaces upstream:

- `DmdDevice.ini`, `[global]` section, `vni.key = <32 hex chars>` (the shipped template in
  `PinMameDevice/DmdDevice.ini` has the field present and blank)
- `dmdext` CLI flag `--pac-key`, described upstream as the key to decrypt PAC files, in hex

This document does not reproduce the value; the citation above locates it. There is no PAC code path
in this repository that would consume it.

Two consequences that follow directly from the above, without inference: the decryption key is
published, and a GPL implementation of the decoder exists. The v2 transform does not change this.
Being keyless, it introduces no new secret to distribute.

### Why it exists, per the participants

Everything in this subsection is attributed. These are positions stated by named people in public
threads, not independently verified events. **Exact post dates were not verified** except where noted;
the ordering below rests on internal cross-references within the threads.

**Lucky1's stated reasons** ([topic 7306](https://vpuniverse.com/forums/topic/7306-pac-files-why-use-the-new-export-format-for-v-pins/)),
introducing `pac` as the new single-file V-Pin export replacing the `pal`/`vni` pair:

- Easier to upload, and ensures only a matching PAL/VNI combination is installed.
- Addresses unspecified "technical drawbacks" of the VNI format, which he says should lead to quicker
  processing.
- Prevents real-pin `pal` files being mixed up with vpin `pal` files.
- States that after "clever businessmen" sold displays bundled with colorizations without crediting
  authors, he was asked by authors to act, and that he and Steve45 first introduced a **real-pin export
  bound to the Pin2DMD device's hardware ID**. He then cites attempts to use vpin exports together with
  freezy's GPL code on real machines as the trigger for `pac`.
- Lists PAC as supported on virtual DMD, pindmdV3, pixelcade, PuPlayer and Pin2DMD via his
  `dmddevice.dll`.

**freezy's account** ([topic 7318](https://vpuniverse.com/forums/topic/7318-end-of-an-era/),
[topic 8416](https://vpuniverse.com/forums/topic/8416-beginning-of-a-new-era/)):

- PIN2DMD's first firmware was open source; after someone loaded the code onto a device they built and
  sold while claiming credit, the firmware became closed source and had to be purchased, with revenue
  donated to a charity of Lucky1's choice.
- The `DmdDevice.dll` interface predates both: written by Russ for VirtuaPin's PinDMDv3, and later used
  by Lucky1 for PIN2DMD. freezy's dmdext grew from screen-grabbing other simulators plus a virtual DMD
  renderer. He notes `@vbousquet` later improved that shader.
- Lucky1 approached him to port the colorization code into dmdext so LCD and PinDMD3 owners could use
  it, on the understanding it would be open source; real-pin owners paid for colorizations while vpin
  colorizations were free.
- He states PAL/VNI were removed from VPUniverse in favour of PAC, and objects that monitor support for
  PAC was delivered as what he calls a hostile fork of dmdext distributed together with the proprietary
  colorizer, which he characterises as a GPL violation.
- He quotes his own compromise proposal, dated in-thread to **20 May 2022**: a coloring-only API
  supporting all frame formats, implemented by both sides, loaded at runtime, shipped separately to
  respect the GPL. He states he received a pull request in **November 2022** implementing it RGB24-only.
- He gives two official reasons for PAC as he understood them, removing original frame data to avoid
  IP infringement and protecting authors, and argues the first was achievable without DRM.

**zedrummer's frame-size argument** ([topic 8430](https://vpuniverse.com/forums/topic/8430-why-serum-for-colorization-authors-and-others/)),
on why RGB24 output was a problem: a 128x32 frame in 64 indexed colours is 64*3 bytes of palette plus
128*32*6/8 bytes of image, which he computes as 3264 bytes, against 128*32*3 = 12288 bytes as RGB24. Over
a 115200 byte/s serial link he gives roughly 35 frames per second for the indexed form against roughly
9 for RGB24. freezy separately states Lucky1 added a driver in the plugin bypassing dmdext so PIN2DMD
received a non-RGB24 format, while dmdext continued to receive RGB24.

**dmdext v2.2.0** ([topic 9051](https://vpuniverse.com/forums/topic/9051-new-release-v220-final/), post
carries an edit stamp of **21 September 2023**): freezy states PAC files were by then banned on
VPUniverse, and that he had had internal PAC support working for months without intending to publish
it. That release ships it, GPL, with plugin-takes-precedence and fallback-to-internal behaviour
described in the post. The commit dates above are consistent with this.

**PAC v2, August 2026.** Commit [`f8f9791`](https://github.com/freezy/dmd-extensions/commit/f8f97915099860c20c81240fc5a06c49a77e5a02) on [`core`](https://github.com/freezy/dmd-extensions/tree/core) adds v2 support, dated 2026-08-01. What is
verifiable from the repository: the commit exists, its subject is "vni: Support PAC v2 files,", and it
introduces the keyless bit-permutation step described above plus version validation. A community report
associates this with a Simpsons colorization that would not play on ZeDMD, and with a new `pin2color`
release; **neither of those points was verified here.** A GitHub Actions run circulated alongside that
report ([`30705735989`](https://github.com/freezy/dmd-extensions/actions/runs/30705735989)) is a `core` branch build dated 2026-08-01 that postdates `f8f9791`
on the same branch rather than being the v2 commit itself.

For comparison, VPX's `dmdutil` plugin forwards frames through both `UpdateRGB24Data` and
`UpdateRGB16Data`. No connection between that and the dispute above has been established.

Serum's origin, as
[recounted by its own author](https://vpuniverse.com/forums/topic/8430-why-serum-for-colorization-authors-and-others/),
his account and not an independent reconstruction: he had released ZeDMD, an ESP32-based DMD that could
display VNI/PAL but not PAC; he contacted Lucky1 asking for PAC support for ZeDMD; he was told Lucky1
was not ready to answer because ZeDMD was a competitor to Pin2DMD; after further exchanges he decided
to write Serum and to keep it open source.

### The GPL reference implementation

The authoritative open implementation is **`LibDmd/Converter/Vni/VniLoader.cs`** in
[freezy/dmd-extensions](https://github.com/freezy/dmd-extensions/blob/master/LibDmd/Converter/Vni/VniLoader.cs)
(GPL, C#). Every structural claim in the layout above is visible there:

- Magic compared against `"PAC "`, then a version value read and used only for logging.
- `private enum DataType : ushort { Pal = 1, Vni = 2 }`.
- `ReadInt16BE()` for type, `ReadInt32BE()` for length, explicit big-endian.
- `Decompress(Decrypt(...))` order, with `GZipStream` for the former.
- `aes.KeySize = 128`, `aes.BlockSize = 128`, `aes.Padding = PaddingMode.Zeros`, then
  `aes.Key = key; aes.IV = key;`.
- Reads at most two chunks: one `NextChunk`, then an EOF check that logs a "PAC without animations"
  case, otherwise a second `NextChunk`. It does not loop to EOF.
- Its `LoadPac` runs and returns early, so `pal_path` and `vni_path` are not consulted when a PAC is
  present.

Whether any PAC file contains more than two chunks was not determined.

Two commits date this file's PAC support:

| Commit | Authored | Committed | Subject |
|---|---|---|---|
| [`70b3697`](https://github.com/freezy/dmd-extensions/commit/70b36975354f8d7d94a0bc69388c8c497d20b146) | 2023-05-06 | 2023-08-13 | Add PAC support. |
| [`f8f9791`](https://github.com/freezy/dmd-extensions/commit/f8f97915099860c20c81240fc5a06c49a77e5a02) | 2026-08-01 | 2026-08-01 | vni: Support PAC v2 files, |

The first pair of dates corroborates freezy's statement in the v2.2.0 announcement that he had had PAC
support working for some time before publishing it.

**Branch caveat.** As checked, v2 support is on the `core` branch, not `master`. `master` is at
[`e54b2397`](https://github.com/freezy/dmd-extensions/commit/e54b2397cedfbf69240872d5f5b53de6c9e21259) ("release: Beginning of v2.5.1", 2026-06-22) and has no v2 handling. [`core`](https://github.com/freezy/dmd-extensions/tree/core) is the head of
PR #563 into `master`. Read `master` for the v1-only behaviour and `core` for v2.

Relationship to libvni: libvni's README describes it as a C++ conversion of the VNI converter of
LibDmd, which is the component `VniLoader.cs` belongs to. PPUC's port carries the PAL and VNI readers
and retains `pac_path` and `vni_key` as accepted-but-unused parameters.

### The AES code already ships

`PPUC/libvni` mainline lists `src/vni_aes.cpp` in `VNI_SOURCES`, so an AES-128-CBC decryptor is
compiled into every `vni64.dll` / `libvni.so` VPX links against. But mainline `vni.cpp` never
includes `vni_aes.h`, and `Vni_LoadFromPaths` explicitly refuses a `pac_path` with an error, keeping
`vni_key` only for API compatibility:

```c
// Loads PAL/VNI data from the provided paths. Any path may be null.
// pac_path and vni_key are accepted for API compatibility, but encrypted PAC
// files are not supported. If pac_path is provided, an error is logged and it
// is ignored.
```

So the crypto is compiled in but not called. No statement of intent for this arrangement was found.

## The Serum lineage

Authoring tool: [SerumColor/ColorizingDMD](https://github.com/SerumColor/ColorizingDMD), by zedrummer
(who identifies himself as the developer of the format in topic 8430). Decoder: `PPUC/libserum`, GPLv2.
Repo creation dates: libserum December 2022, the ColorizingDMD repo March 2023.

Two format generations, both handled by `plugins/serum`:

- **`cRZ`.** The original.
- **`cROMc`.** Current. The dmd-extensions release notes describe cROMc as using an order of
  magnitude fewer resources, with cRZ still supported but converted internally to cROMc, and new
  colorizations distributed in the newer format.

Features stated by the format's author in topic 8430: colour rotation applied automatically while a
frame is displayed, linear and radial gradients, and sprites that are detected and colorized in real
time. Serum v2, per VPUniverse release descriptions, permits per-frame RGB565 colour rather than a
64-colour limit, and adds automatic shading.

On encryption and platform scope, a statement from topic 9487: the format makes no difference between a
real and a virtual pinball machine, there is no encryption, and the decoding library is open source and
available for every OS.

Size interaction with this repo: Serum v2 output can be 256x64, and `plugins/dmdutil` rejects sources
above 256x64 (`DMDUtilPlugin.cpp:202`, `maxPixels = 256 * 64`), so v2 output sits at the limit rather
than under it.

`libvni`'s README states its purpose includes producing RGB565 dumps of colorized frames as a
jump-start for a VNI author converting the project to a Serum colorization.

## SmartDMD: patched-ROM colorization

"SmartDMD" names two related but distinct things that share an author and a history, and conflating
them is easy. This section separates them.

### SmartDMD the hardware product

SmartDMD is a Raspberry Pi-based LCD display replacement for plasma DMDs, created by Pinside user
**oga83** (who also authored Pinball Browser). The earliest publicly available software image
dates to [2014](https://pinside.com/pinball/forum/topic/smartdmd-dmd-interface-with-colors-upscaling-network-and-more)
(v2014-10-06), with continued updates through at least late 2015. It ran on a Raspberry Pi Model A/B
and intercepted the DMD signal through either a custom SmartDMD adaptor board, a "DMD Extender"
board, or a hand-wired cable connected to the 14-pin DMD ribbon header.

The hardware product was a general-purpose DMD replacement, not solely a colorization tool. Its
feature set included:

- Multiple display modes: raw, 2× upscaling, 16× upscaling, anti-aliasing.
- Network broadcasting of the DMD image for remote viewing in Pinball Browser.
- Background bitmaps and custom dot shapes.
- Colorization: 16 colours per image, with a different palette specifiable per image.

Platform support for the **hardware product** was broader than just Stern. The Pinside thread lists
compatibility with:

- Stern SAM (native, from launch)
- Data East (added by Pinside contributor `Winteriscoming`)
- Williams/Bally (added by Pinside contributor `Tatanka1961`)

The [Pinside setup guide](https://pinside.com/pinball/forum/topic/smartdmd-color-display-setup-guide)
describes it as supporting "the most popular Bally, Williams, Data East, Sega, Capcom, and Stern
games," though that claim covers the hardware's ability to *display* the DMD signal from those
platforms, not necessarily to *colorize* all of them via patched ROM.

Ready-to-use kits were sold by PinballMikeD (a complete package including LCD panel, Raspberry Pi,
adaptor, and software). The product predates PIN2DMD and appears to have been the first community
hardware to support in-ROM palette switching for colorization.

### SmartDMD the colorization method

The colorization method that carries the SmartDMD name is technically independent of the hardware
product: it is supported by PIN2DMD, SmartDMD hardware, and (via the VNI plugin) VPX.

The principle is simple compared to keyframe-based colorization: instead of an external database that
pattern-matches frames, **the ROM itself is patched** to emit palette-switching commands. This
eliminates the need for keyframe matching, masks, or a VNI animation file. A bare `pal` containing
only palettes (no keyframes) is sufficient. The display controller switches palette when instructed by
the ROM rather than when it recognises a frame.

This technique is **limited to Stern SAM and Stern Spike ROMs.** [pin2dmd.com](https://pin2dmd.com/pinball-browser/)
states explicitly that Pinball Browser "can be used to modify Stern SAM and Stern Spike system ROMs."
The restriction exists because the method depends on Pinball Browser's ability to:

1. Parse and patch the Stern firmware binary (expanding memory where needed for the additional code).
2. Inject palette-switching instructions that execute alongside the game's normal DMD rendering.
3. For real-pin side-channel: inject a serial communication patch ("commpatch") that outputs palette
   indices over the SAM board's DB9 connector. This patch is unique per machine because it uses the
   machine's serial number for integrity verification.

Other platforms (WPC, Data East, Sega, Gottlieb, Capcom) cannot use this approach because their
firmware architectures differ fundamentally from the ARM-based Stern SAM/Spike systems. Those
platforms rely on keyframe matching (PAL+VNI, PAC) or Serum instead.

### Delivery mechanisms

Pinball Browser offers two methods to pass palette information from the patched ROM to the display
controller. Both are selectable under the "SmartDMD" tab in Pinball Browser:

**In-frame.** The palette index is embedded directly into the DMD frame data by the patched ROM. The
display controller (Pin2DMD, SmartDMD hardware, or in VPX the VNI plugin via libvni) detects and
extracts it from the frame. This requires no additional wiring.

In VPX, the in-frame mechanism is handled inside libvni. The `pin2dmd.dat` specification includes a
`CustomSmartDMDSig` field (8 bytes) that the device uses as a recognition signature for in-frame
palette commands.

**Side-channel (serial).** The patched ROM sends palette indices over USART2 on the SAM board, which
appears on the DB9 connector. A TTL-to-RS232 level converter (built into Pin2DMD V3+ shields)
connects this to the display controller's RS232 input.

In VPX, the VNI plugin implements this via `OnConsoleData`: it subscribes to
`PMPI_EVT_ON_CONSOLE_DATA` and runs a 4-byte sliding window looking for an ASCII `'P'` followed by
two hex digits, then calls `Vni_SetPalette(pVni, (hi << 4) | lo)`. On a real cabinet this is a
physical cable; in emulation it is the PinMAME console stream forwarded through the plugin API.

Community reports indicate that **side-channel is more reliable** than in-frame for SAM machines. A
user on [VPUniverse topic 2327](https://vpuniverse.com/forums/topic/2327-colorize-stern-roms-with-pinball-browser/page/3/)
states that for Metallica "you must use the side channel (serial cable). InFrame would not work." For
Spike ROMs the constraint is different: a post on
[topic 3551](https://vpuniverse.com/forums/topic/3551-ghostbusters-just-testing/) states that "spike
roms only support 3 methods to store palette information" including in-frame.

### Relationship to Pin2DMD Editor colorizations

SmartDMD-method colorizations and Pin2DMD Editor colorizations are **mutually complementary
approaches to the same display hardware**, not competing formats. In the Pin2DMD ecosystem:

- **Pin2DMD Editor** produces PAL+VNI (or PAC) files that use keyframe matching. No ROM
  modification needed, and it works with any platform that PinMAME emulates.
- **Pinball Browser SmartDMD** produces a patched ROM plus a bare `pal`. Simpler palette-only
  colorization, but requires a Stern SAM or Spike ROM.

Both produce `pal` files consumed by the same Pin2DMD firmware and the same VNI plugin. The
[VPUniverse thread on Pin2DMD](https://vpuniverse.com/forums/topic/2251-pin2dmd-fullcolor-dmd-display-for-virtual-and-real-pinballs/)
describes the distinction succinctly: "SmartDMD — same features like ColorDMD but only some Stern
pinball machines are supported with modified ROM."

The methods can also be combined: a post on
[topic 5536](https://vpuniverse.com/forums/topic/5536-problem-with-stern-colorisation-with-pinball-browser-mixed-with-standard-editor/)
discusses mixing Pinball Browser SmartDMD palettes with Pin2DMD Editor keyframe scenes on the same
game, noting that "SideChannel commands do not interrupt pin2dmd editor scenes."

### Known SmartDMD-method colorizations

The following list is drawn from [Terranigma's complete colour file list](https://vpuniverse.com/forums/topic/5391-complete-pin2dmd-serum-colour-file-list-for-virtual-real-pins/)
on VPUniverse (the "Pinball Browser & Patch Pin2dmd Files" section) and the
[ROM Remixes and Mods Chapter 2](https://vpuniverse.com/forums/topic/9084-list-of-vpm-rom-remixes-and-mods-chapter-2/)
thread. **All are Stern SAM titles.** The list header on VPU notes these require "PB Software,
Original FW, Macro and Serial Cable" and states "Consider all of these files abandoned or no longer
supported."

| Game | ROM | Author | Notes |
|------|-----|--------|-------|
| AC/DC Pro | `acd_170c` | pinballmike | VPin download on VPU |
| AC/DC Premium & LE | `acd_170hc` | pinballmike | VPin download on VPU |
| The Avengers | `avs_170` | sharkky | |
| Big Buck Hunter Pro | `bbh_170` | sharkky | |
| CSI | unknown | unknown | Status unknown |
| Metallica Pro | unknown | pinballmike | |
| Metallica LE | `mtl_180hc` | pinballmike (credited as j_m_) | VPin download on VPU |
| Mustang Pro | `mt_145hc` | sharkky | |
| Mustang LE | unknown | sharkky | |
| Pirates of the Caribbean | `potc_600af` | Sironzolot | |
| Sharkey's Shootout | unknown | unknown | Status unknown |
| Shrek | `shr_141` | Toon | |
| Spider-Man VE | `smanve_101c` | sharkky | |
| Star Trek Pro | unknown | sharkky | |
| Star Trek Premium & LE | `st_161hc` | sharkky | |

No Stern Spike SmartDMD-method colorizations were found publicly available. While Pinball Browser
supports Spike ROM patching (and the Ghostbusters WIP thread confirms it is technically possible),
all community-released SmartDMD colorizations identified are for SAM-era games. Spike-era games
that have been colorized (Ghostbusters 2016, etc.) have used the Pin2DMD Editor or Serum instead.

### Current status

The SmartDMD colorization method is largely superseded. The community has moved to Pin2DMD Editor
keyframe colorizations (PAL+VNI/PAC) and Serum, both of which work across all platforms without ROM
modification. Terranigma's list explicitly marks the Pinball Browser section as "abandoned or no
longer supported." Several of the games above now have full Pin2DMD Editor or Serum colorizations
that cover far more scenes than the original SmartDMD palette swaps.

The SmartDMD hardware product also appears inactive. The last referenced software update is from
2015, and all current community discussion centres on Pin2DMD and ZeDMD hardware.

What remains live in this codebase is the **side-channel decoder** in `plugins/vni/vni.cpp`, which
will correctly apply palette changes from any PinMAME SAM ROM that has been patched with Pinball
Browser's serial communication patch. The in-frame mechanism is handled inside libvni and requires
no code in this repo.

## Practical notes for this repo

- **Bumping a colorizer means bumping `LIBDMDUTIL_SHA`.** `libserum` and `libvni` are not pinned in
  `platforms/config.sh`. Their `vni64`/`serum64` binaries and headers are copied out of libdmdutil's
  own `third-party/` tree.
- **`plugins/vni/plugin.cfg` pointed at a dead URL.** It previously named `vpinball/libvni`, which
  404s; the real upstream is [PPUC/libvni](https://github.com/PPUC/libvni). Corrected.
- **The pinned `LIBVNI_SHA` is not on upstream `main`.** libdmdutil pins
  [`cef652e8`](https://github.com/PPUC/libvni/commit/cef652e8e543ced5ec9af7663014b240a2a99ebd), which GitHub reports as *diverged* from
  `PPUC/libvni` main ([`eb910403`](https://github.com/PPUC/libvni/commit/eb910403834184e1d098bcc310054ac17a00b53d)), one ahead and one behind. Both commits have the identical tree
  `7b1f5cc8`, so the content is the same. The pinned commit is the pre-PR direct push and main's
  head is the squashed PR #9 merge of the same change. Builds are unaffected, but `git log main`
  will not show the pinned commit, and it is not guaranteed to survive garbage collection. Prefer
  repinning to the commit that is actually on `main`.
- **`pac` has no code path in this repo.** `plugins/vni/vni.cpp:124` calls
  `Vni_LoadFromPaths(m_palPath..., m_vniPath.empty() ? nullptr : m_vniPath..., nullptr, nullptr)`,
  with both `pac_path` and `vni_key` hard-coded `nullptr`. Enabling PAC would require changes in libvni,
  libdmdutil and this plugin, plus a key setting.

*Verified against (VPX-side code claims only): `plugins/vni/vni.cpp` (`Vni_LoadFromPaths` args, `OnConsoleData` side-channel), `plugins/serum/serum.cpp` (16666 us tick), `plugins/dmdutil/DMDUtilPlugin.cpp` (`maxPixels = 256 * 64`), `platforms/config.sh` + libdmdutil `config.sh` at `LIBDMDUTIL_SHA` (`LIBVNI_SHA`/`LIBSERUM_SHA`). Format and history material is sourced to the repos and threads below.*

## Sources

Code, read directly at the commits named in-text:

- [lucky01/PIN2DMD](https://github.com/lucky01/PIN2DMD), the hardware project and format origin
- [sker65/go-dmd-clock](https://github.com/sker65/go-dmd-clock), the Pin2DMD Editor, writes PAL/VNI/FSQ
- [freezy/dmd-extensions](https://github.com/freezy/dmd-extensions), C# `LibDmd` reader, ancestor
  of libvni
- [PPUC/libvni](https://github.com/PPUC/libvni), C++ port, GPLv2
- [PPUC/libserum](https://github.com/PPUC/libserum), Serum decoder, GPLv2
- [SerumColor/ColorizingDMD](https://github.com/SerumColor/ColorizingDMD), Serum authoring tool
- [vpinball/libdmdutil](https://github.com/vpinball/libdmdutil), the gateway VPX actually pins
- [pin2dmd.com](https://pin2dmd.com/), editor and workflow documentation

The PAC container layout is documented from the GPL reference implementation,
[`LibDmd/Converter/Vni/VniLoader.cs`](https://github.com/freezy/dmd-extensions/blob/master/LibDmd/Converter/Vni/VniLoader.cs)
(C#) in dmd-extensions.

Community history comes from the VPUniverse threads linked inline; opening posts were read directly
rather than summarised from search results. They are forum posts, not specifications, cited to
establish the sequence of events and the positions the participants took, and paraphrased rather than
reproduced. Where a claim is contested, both framings are given. Every format and code detail in this
document comes from reading source.
