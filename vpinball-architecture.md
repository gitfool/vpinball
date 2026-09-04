---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball Architecture Reference

Architecture map of the Visual Pinball X (VPX) repository, verified against the
code. Read it as a map, not a substitute for the code. Every load-bearing claim
cites the file it was checked against.

This doc complements the repo's own [`docs/`](../vpinball/docs/README.md), it does
not repeat it. Those are user- and creator-facing (how to configure a flavor,
where files go, what a script command does); this goes to the code level (how the
loader works, why the plugin bus is shaped this way, where the debt is). Where a
repo doc already states a fact well, this links to it and goes deeper rather than
paraphrasing. Repo-doc links are relative to a checkout sibling to this worktree
(`../vpinball/`), so they resolve locally but not as GitHub links.

## How to use these docs

**Audience: a coder, human or AI, about to change this code.** The value here is
what the source does not tell you on its own: why the code is shaped the way it
is, the history that explains present-day oddities, the traps that will bite an
edit that assumes the obvious, and precise anchors to jump to.

- This file is the **hub**. It gives the shape of the system, the map, the build,
  and the cross-cutting history, enough to orient before you dive.
- Each subsystem has its own **deep-dive** (see [Subsystems](#subsystems)) with
  the low-level detail, the change history, and the traps for that area. Grab the
  one for the code you are touching.
- **Anchors are `file` and `symbol`, with a line number where it aids a jump.**
  Line numbers drift; treat them as a hint and trust the symbol. The
  `verified_against` commit is the ground truth for any line reference.
- **Confidence is marked.** A claim is either verified in code (with an anchor),
  attributed to a commit or PR, or labelled inference. Do not upgrade an inference
  to a fact when acting on it.
- **Not a feature guide.** For how to use or configure something, follow the
  linked repo `docs/`; these docs stay on the mechanism.

> Provenance. The front matter records the commit this doc was verified against
> (`verified_against`). Each major section ends with a `Verified against:` line
> naming the files its claims lean on. To check a section for staleness, diff its
> files between that commit and current `master`, then re-read the section. Files
> live next to the claims they back so the mapping cannot silently drift.

Version at this commit is **10.8.1** (`src/core/vpversion.h`: major 10, minor 8,
rev 1). The 10.8.1 line is the cross-platform prerelease.

## How to re-verify this doc

Each section names its own files. To check the whole doc at once, diff every file
named in a `Verified against:` line between the recorded commit and `master`:

```bash
git diff --stat c321a1812..HEAD -- <files named in the section you care about>

# Read a file as it was when the doc was verified
git show c321a1812:src/parts/pintable.cpp
```

## Historical context: COM to plugins

- **10.8.0 (stable, Windows-only)** used COM/ActiveX for its subsystems. VPinMAME
  was a COM object; B2S.Server wrapped it and fanned data out to its own plugins
  (DOF among them).
- **10.8.1+ (prerelease, cross-platform)** replaces that with a portable plugin
  system. PinMAME, B2S, and DOF are independent plugins that share data through
  VPX. Any number of consumers can read machine state without consuming it.

The plugin system is the defining change of this line. It has its own deep-dive:
[vpinball-plugin-system.md](vpinball-plugin-system.md). The single-consumer
rationale for the old B2S-as-hub design is plausible but not confirmed in the
commit record; the deep-dive marks it as inference.

## Repository layout

```
vpinball/
  src/             Core engine
    audio/         Runtime audio (AudioPlayer, SoundPlayer, AudioStreamPlayer; miniaudio + SDL3)
    core/          App core (VPApp, Player, PinTable, Settings, scripting, plugin bridge)
    input/         Input (SDL-based; OpenPinDev, plunger, sensor mapping)
    math/          Vectors, matrices, mesh, bbox
    meshes/        Static mesh data
    parts/         Table elements (Ball, Flipper, Light, Ramp, Primitive, ...)
    physics/       Collision, spatial trees, cabinet nudge/plumb (physics/cabinet/)
    renderer/      Render abstraction (RenderDevice, Renderer, Shader, Window, VRDevice)
    shaders/       Shader source (bgfx/*.sc, hlsl_glsl/*)
    ui/            UI: live/ (ImGui LiveUI), win/ (Win32 editor)
    utils/         BIFF reader/writer, logging, timers, OBJ loader
  plugins/         Plugin implementations + core plugin API
    plugins/       Core plugin API headers + host manager (MsgPluginManager)
    pinmame/ dof/ b2s/ b2slegacy/ flexdmd/ altsound/ serum/ vni/ dmdutil/
    alphadmd/ upscaledmd/ pup/ wmp/ scoreview/ remote-control/ inspector/
    helloworld/ helloscript/
  standalone/      Non-Windows / MinGW support (COM shim, storage, IDL)
  platforms/       config.sh (pinned dependency SHAs) + per-platform external.sh
  lib/             Shared-library wrapper for mobile (iOS/Android)
  scripts/         VBScript support files for ROM-driven tables
  make/            VS solution, CMake source/plugin lists, batch scripts
  third-party/     Dependency drop zone + vendored sources
  tests/  docs/  bin/
```

The `src/` and `plugins/` layouts above were confirmed by directory listing at
this commit. The plugin API headers now live under `plugins/plugins/`; they were
moved out of the VPX source tree in [`9f33a1516`](https://github.com/vpinball/vpinball/commit/9f33a1516)
("Plugin: Move shared code out of vpx src tree").

*Verified against: `src/`, `plugins/` (directory listing).*

## Key source files

| File | Purpose |
|------|---------|
| `src/core/VPApp.h/.cpp` | Application singleton: settings, file locator, platform init |
| `src/core/player.h/.cpp` | Runtime orchestrator: owns physics, renderer, script, plugins, input, audio |
| `src/core/main.h` | Precompiled header / platform abstraction |
| `src/core/vpversion.h` | Version constants, file format version |
| `src/parts/pintable.h/.cpp` | Central table data model; also the table loader |
| `src/core/ScriptInterpreter.h/.cpp` | VBScript host (ActiveScript on MSVC / libwinevbs elsewhere) |
| `src/core/ScriptGlobalTable.h/.cpp` | The `Global` scripting object |
| `src/core/VPXPluginAPIImpl.h/.cpp` | Host side of the plugin API |
| `src/physics/PhysicsEngine.h/.cpp` | Physics simulation |
| `src/renderer/Renderer.h/.cpp` | High-level render orchestration |
| `src/renderer/RenderDevice.h/.cpp` | Backend abstraction (BGFX / GL / DX9) |
| `plugins/plugins/MsgPlugin.h` | Plugin transport API (C interface) |
| `plugins/plugins/MsgPluginManager.h/.cpp` | Plugin host manager |
| `plugins/plugins/VPXPlugin.h` | VPX events, textures, rendering API |
| `plugins/plugins/ControllerPlugin.h` | Shared controller state, displays, audio |
| `plugins/plugins/ScriptablePlugin.h` | Scriptable-object contribution + COM override |

## Subsystems

Each subsystem below has an overview here (enough to orient) and a deep-dive doc
with the low-level detail, history, and traps. Grab the deep-dive for the area you
are about to change.

| Subsystem | Overview | Deep-dive |
|-----------|----------|-----------|
| Configuration | property registry, global/table-override, plugin settings | [vpinball-config.md](vpinball-config.md) |
| Plugin system | the 10.8.1 message bus and controller model | [vpinball-plugin-system.md](vpinball-plugin-system.md) |
| Table loading | reading the `vpx` file, the load pipeline | [vpinball-loading.md](vpinball-loading.md) |
| Renderer | backends, render thread, windows, VR | [vpinball-renderer.md](vpinball-renderer.md) |
| Audio | miniaudio + SDL3, plugin audio sources | [vpinball-audio.md](vpinball-audio.md) |
| Input | devices, actions, nudge/plunger | [vpinball-input.md](vpinball-input.md) |
| Physics | collision, spatial trees, cabinet | [vpinball-physics.md](vpinball-physics.md) |
| Scripting | VBScript hosting, the script objects | [vpinball-scripting.md](vpinball-scripting.md) |

Each section below is an overview. The low-level detail, history, and traps live
in the linked deep-dive.

### Topic deep-dives

Some docs are not `src/` subsystems but standalone topics, often about external
projects or history rather than VPX code. They have no hub section; go straight to
the deep-dive.

| Topic | Covers | Deep-dive |
|-------|--------|-----------|
| DMD colorization | Serum/VNI formats, the PAC container, SmartDMD, and the community history | [vpinball-dmd-colorization.md](vpinball-dmd-colorization.md) |

## Player and game loop

`Player` (`src/core/player.h`) is the runtime orchestrator that owns the
subsystems below, so it is the way into all of them. It holds the physics engine
(`PhysicsEngine* m_physics`), the renderer (`std::unique_ptr<Renderer>`), the
script interpreter, the plugin manager and host bridge
(`MsgPI::MsgPluginManager m_pluginManager` + `VPXPluginAPIImpl m_pluginAPI`), the
input manager (`InputManager m_pininput`), and the audio player
(`std::unique_ptr<VPX::AudioPlayer>`).

Frame methods: `GameLoop()` and `UpdateGameLogic()` are public; `PrepareFrame()`,
`SubmitFrame()`, `FinishFrame()` are private.

Sync modes. The default is `VideoSyncMode::VSM_FRAME_PACING`. The separate
render/physics thread path (`MultithreadedGameLoop()`, `CallbackSteppedGameLoop()`)
is **BGFX-only** (`#ifdef ENABLE_BGFX`). Under GL or DX9 the game runs
single-threaded through `FramePacingGameLoop()` or `GPUQueueStuffingGameLoop()`.

*Verified against: `src/core/player.h`.*

The subsystem sections that follow are in the order of the
[Subsystems](#subsystems) index.

## Configuration

Settings are registered typed properties, not free-form ini reads. `Settings`
(`src/core/Settings.h/.cpp`) over a property registry declares static properties
in `Settings_properties.inl` via `Prop*` macros, with the `Dyn` suffix marking a
property table-overridable. Plugin `Enable` keys are registered dynamically at
load; every other plugin key comes from the plugin itself.

Full detail, the X-macro registry, the global vs table-override layering, the
build-conditional defaults, and where plugin settings actually come from, is in the
[configuration deep-dive](vpinball-config.md).

*Verified against: `src/core/Settings.h`, `src/core/Settings_properties.inl`. See the deep-dive for full anchors.*

## Plugin system

The defining change of the 10.8.1 line. An in-process C message bus
(`MsgPluginManager`, `plugins/plugins/`) lets PinMAME, B2S, DOF, colorizers, and
others share machine state as peers, readable by any number of consumers without
consuming it, replacing the old COM/ActiveX model where B2S was a mandatory hub.

Full detail, the message transport and endpoint model, the plugin lifecycle, the
layered APIs (controller state, displays, audio, scriptable), the two conventions
(Vulkan-style sizing, thread affinity), and the history, is in the
[plugin-system deep-dive](vpinball-plugin-system.md).

*Verified against: `plugins/plugins/MsgPluginManager.cpp`. See the deep-dive for full anchors.*

## Table loading

A `vpx` file is an OLE/CFB compound file, read through **POLE on every platform** (a
change from the old Windows-uses-`StgOpenStorage` split; that Win32 path now only
saves). `PinTable::LoadGameFromFilename` (`src/parts/pintable.cpp`) reads the
table record, then loads every asset stream in physical-offset order, forcing a
single reader on network paths. Almost the whole file is read at load.

The loaded elements are `IEditable` **table parts** under `src/parts/` (ball,
bumper, flipper, light, ramp, primitive, and so on). Each part implements
`ISelect` / `IEditable` / `IHitable` / `IRenderable` / `IScriptable` /
`IFireEvents` and serializes through the BIFF `IObjectReader`/`IObjectWriter`
abstraction (`BiffReader`/`BiffWriter` in `src/utils/`), reading fields via
`LoadToken`.

Full detail, the load pipeline, the offset-sort and network-single-reader design
and their history, the pre-read that was drafted and never shipped (PR #3817), the
Windows-only integrity hashing, and the O(n²) post-load bookkeeping still in the
tree, is in the [table-loading deep-dive](vpinball-loading.md).

*Verified against: `src/parts/pintable.cpp` (`LoadGameFromFilename`), `src/parts/ieditable.h`, `src/parts/flipper.h`, `src/utils/BiffReader.h`. See the deep-dive for full anchors.*

## Renderer

`Renderer` (`src/renderer/Renderer.h`) is the high-level scene and post-processing
orchestrator; `RenderDevice` (`src/renderer/RenderDevice.h`) is the low-level
backend abstraction over three mutually-exclusive compile-time backends (BGFX
primary, OpenGL and DX9 legacy). Rendering uses a retained command-buffer
(`RenderFrame` / `RenderPass` / `RenderCommand`) with automatic
render-target-dependency sorting. Under BGFX the render loop runs on its own
thread for latency; GL and DX9 render on the logic thread. Windows are SDL3-based
and multi-window is a BGFX capability.

Full detail, the render-thread handoff and its four sync primitives, the teardown
race trap, the backward-compatibility-shaped pass sorter, multi-window, VR, and
the shader layout, is in the [renderer deep-dive](vpinball-renderer.md).

BGFX shaders live in `src/shaders/bgfx/*.sc` (compiled by `shaderc`); legacy GL
`*.glfx` and DX9 `*.hlsl` shaders live in `src/shaders/hlsl_glsl/`.

*Verified against: `src/renderer/RenderDevice.h`, `src/renderer/Renderer.h`. See the deep-dive for full anchors.*

## Audio

`AudioPlayer` (`src/audio/AudioPlayer.h`, namespace `VPX`, held by `Player` as
`m_audioPlayer`) runs two miniaudio engines, playfield and backglass, often on
separate devices, with SDL3 on the backglass device side. It handles three paths:
table sound effects (`SoundPlayer`), a single backglass music player, and streamed
audio (`AudioStreamPlayer`) for plugins. Plugin audio sources mix in as
`Player` audio lanes via the controller audio messages, with `overrideId`
supersession.

Full detail, the two-engine split, the three audio paths, the playfield
spatialization modes (SSF and friends), and the plugin audio-lane mixing, is in the
[audio deep-dive](vpinball-audio.md).

*Verified against: `src/audio/AudioPlayer.h`, `src/core/player.h`. See the deep-dive for full anchors.*

## Input

`InputManager` (`src/input/InputManager.h`, held by `Player` as `m_pininput`)
routes physical input through four layers: devices (keyboard, joystick, mouse,
VR controller, Open Pinball Device, all via SDL except OpenPinDev and XR),
raw button/axis events, per-device mappings, and named `InputAction`s with stable
ids. It also owns the nudge and plunger handlers, whose conditioning lives in
physics.

Full detail, the device/event/mapping/action layering, the map verbs, the
nudge/plunger input-physics seam, touch, and rumble, is in the
[input deep-dive](vpinball-input.md).

*Verified against: `src/input/InputManager.h`. See the deep-dive for full anchors.*

## Physics engine

`PhysicsEngine` (`src/physics/PhysicsEngine.h`) runs continuous collision
detection on a fixed 1000 Hz step, with a catch-up loop that skips time forward
rather than stalling when it falls behind. Static objects sit in a quadtree
(despite the member being named `m_hitoctree`), dynamic balls in a KD-tree, and
collision order is deliberately randomized to avoid bias. Cabinet nudge, tilt, and
accelerometer input live in a subsystem under `src/physics/cabinet/`.

Full detail, the 1000 Hz vs historical VPT time units, the collision cycle and its
randomization traps, the mover model, the misnamed tree member, the DJRobX
latency-loop code, and the cabinet subsystem, is in the
[physics deep-dive](vpinball-physics.md).

*Verified against: `src/physics/PhysicsEngine.h`. See the deep-dive for full anchors.*

## Scripting

Table scripts are VBScript, hosted (not implemented) by `ScriptInterpreter`
(`src/core/ScriptInterpreter.h`), which implements the Active Script *site*
interfaces. Which VBScript engine `CoCreateInstance(CLSID_VBScript)` resolves to is
a link-time choice, the Windows Scripting Engine on MSVC desktop, libwinevbs on
standalone/lib builds via `__LIBWINEVBS__`, not an `#ifdef` in the interpreter.
`ScriptGlobalTable` is the `Global` object, `PinTable` is `Table`, parts are named
objects, and a `DynamicScript` runtime-typed `IDispatch` lets plugin objects appear
to script.

Full detail, the host-vs-engine split, the link-time selection trap, the object
model, and the `DynamicDispatch`/`DynamicTypeLibrary` machinery behind plugin
scriptable objects, is in the [scripting deep-dive](vpinball-scripting.md).

*Verified against: `src/core/ScriptInterpreter.h`, `src/core/ScriptInterpreter.cpp`. See the deep-dive for full anchors.*

## Build variants (preprocessor defines)

All verified in `CMakeLists.txt` at this commit.

| Define | Meaning | Where set |
|--------|---------|-----------|
| `ENABLE_BGFX` | BGFX renderer backend (default) | desktop BGFX, all standalone/lib targets |
| `ENABLE_OPENGL` | OpenGL backend | desktop `RENDERER=GL`, standalone GL |
| `ENABLE_DX9` | DirectX 9 backend | desktop Windows only (the CMake `else` branch) |
| `__STANDALONE__` | Non-Windows build, or Windows MinGW | all non-MSVC-desktop targets |
| `__LIBVPINBALL__` | Building the shared library for mobile | lib target only |
| `__LIBWINEVBS__` | Route VBScript through libwinevbs | all standalone/lib targets |
| `__OPENGLES__` | OpenGL ES variant | non-x64 GL standalone |
| `ENABLE_XR` | OpenXR VR support | CMake option (default off; forbidden on iOS), lib target |

The three renderer backends are **mutually exclusive** compile-time selections
(`#if defined(ENABLE_BGFX) / #elif ENABLE_OPENGL / #elif ENABLE_DX9`, see
`src/renderer/RenderDevice.h`). A given binary has exactly one. DX9 source is
still present and buildable, but only on desktop Windows.

*Verified against: `CMakeLists.txt`, `src/renderer/RenderDevice.h`.*

## Build system

### CMake (primary)

A single `CMakeLists.txt` drives every platform via cache variables:
`-DRENDERER=BGFX|GL|DX9`, `-DPLATFORM=...`, `-DARCH=...`. It selects the backend
define and the per-platform library set from there.

Runtime configuration (the property registry, the global/table-override layers,
and where plugin settings come from) is a subsystem of its own; see
[vpinball-config.md](vpinball-config.md). This section covers the build, not the
settings.

### Dependencies

`platforms/config.sh` is the single source of truth for pinned dependency
versions. It defines `*_SHA` variables (plus `BGFX_CMAKE_VERSION`, a release tag)
and defaults `BUILD_TYPE=Release`. It downloads nothing itself; each
`platforms/<platform>-<arch>/external.sh` sources it, fetches and builds each
dependency, and deposits artifacts into `third-party/`.

At this commit `config.sh` pins the following. The upstream column is the repo
each `external.sh` actually fetches from (verified against the `curl` lines, not
carried over from prior notes):

| Define | Upstream |
|--------|----------|
| `SDL_SHA` / `SDL_IMAGE_SHA` / `SDL_TTF_SHA` | [libsdl-org/SDL](https://github.com/libsdl-org/SDL) (+ `_image`, `_ttf`) |
| `FREEIMAGE_SHA` | [toxieainc/freeimage](https://github.com/toxieainc/freeimage) (VPX fork) |
| `BGFX_CMAKE_VERSION` + `BGFX_PATCH_SHA` | [bkaradzic/bgfx.cmake](https://github.com/bkaradzic/bgfx.cmake) + [vbousquet/bgfx](https://github.com/vbousquet/bgfx) patch |
| `PINMAME_SHA` | [vpinball/pinmame](https://github.com/vpinball/pinmame) |
| `OPENXR_SHA` | [KhronosGroup/OpenXR-SDK-Source](https://github.com/KhronosGroup/OpenXR-SDK-Source) |
| `LIBDMDUTIL_SHA` | [vpinball/libdmdutil](https://github.com/vpinball/libdmdutil) (gateway to the DMD stack) |
| `LIBALTSOUND_SHA` | [vpinball/libaltsound](https://github.com/vpinball/libaltsound) |
| `LIBDOF_SHA` | [vpinball/libdof](https://github.com/vpinball/libdof) (gateway to the USB/HID stack) |
| `FFMPEG_SHA` | [FFmpeg/FFmpeg](https://github.com/FFmpeg/FFmpeg) |
| `LIBWINEVBS_SHA` | [vpinball/libwinevbs](https://github.com/vpinball/libwinevbs) |
| `LIBZIP_SHA` | [nih-at/libzip](https://github.com/nih-at/libzip) |

Every mapping above was checked against the `curl` line in `external.sh` at this
commit, not carried from prior notes. One had moved since the earlier doc:
PinMAME is now fetched from `vpinball/pinmame`, not the old `vbousquet/pinmame`
fork. `BGFX_CMAKE_VERSION` is a release-asset tarball from `bgfx.cmake`, not a
git archive; the `vbousquet/bgfx` patch replaces the bundled bgfx after unpacking.
The SDL stamp is composite (`SDL_SHA-SDL_IMAGE_SHA-SDL_TTF_SHA`), and the bgfx
stamp is `BGFX_CMAKE_VERSION-BGFX_PATCH_SHA`.

### Transitive pins

`config.sh` only pins the direct deps. The DMD and USB/HID stacks are pinned one
or two levels up, in each gateway's own `platforms/config.sh`. Verified by
fetching each gateway's `config.sh` at its pinned SHA and reading its
`external.sh` `curl` URLs (macos/arm64 as the canonical source; SHAs are shared
across platforms, only build steps differ):

```
libdmdutil (vpinball/libdmdutil)          gateway to the DMD stack
├── libusb        -> libusb/libusb
├── libzedmd      -> PPUC/libzedmd         gateway
│   ├── cargs         -> likle/cargs
│   ├── libserialport -> sigrokproject/libserialport
│   ├── libframeutil  -> ppuc/libframeutil
│   └── sockpp        -> fpagliughi/sockpp
├── libserum      -> PPUC/libserum
├── libpupdmd     -> PPUC/libpupdmd
└── libvni        -> PPUC/libvni           gateway
    └── libframeutil  -> ppuc/libframeutil (pinned separately from libzedmd's)

libdof (vpinball/libdof)                   gateway to the USB/HID stack
├── libserialport -> sigrokproject/libserialport
├── hidapi        -> libusb/hidapi
├── libftdi       -> jsm174/libftdi        (fork)
└── libusb        -> libusb/libusb

libaltsound (vpinball/libaltsound)         no nested externals (no platforms/config.sh)
```

Consequences worth remembering:

- **Bumping a colorizer means bumping `LIBDMDUTIL_SHA`.** libserum, libvni,
  libzedmd, and libpupdmd have no knob in this repo's `config.sh`.
- **`libframeutil` is pinned twice at different SHAs**, once under libzedmd and
  once under libvni. They are the same repo but not the same commit, so they can
  drift apart.
- **`libusb` and `libserialport` fan in** from more than one gateway at the same
  SHA. Consistent today, but two pins to keep aligned on a bump.
- `libdof`'s `external.sh` echo block omits `libusb`, but it is still pinned and
  built. Do not read the echo list as the full dependency set.

*Verified against: `platforms/config.sh`, `platforms/*/external.sh`, and each
gateway's upstream `platforms/config.sh` + `external.sh` at its pinned SHA
(libdmdutil `3485e2e0`, libdof `afc2be6e`, libzedmd `e8466d25`, libvni `cef652e8`).*

## Contributors

By [all-time](https://github.com/vpinball/vpinball/graphs/contributors?all=1) commit
count on GitHub's contributor graph, the leaders are Carsten Waechter aka "toxie"
([toxieainc](https://github.com/toxieainc)), Vincent Bousquet
([vbousquet](https://github.com/vbousquet)), Jason Millard
([jsm174](https://github.com/jsm174)), then "Fuzzel"
([fuzzelhjb](https://github.com/fuzzelhjb)). Over the
[last 18 months](https://github.com/vpinball/vpinball/graphs/contributors) the
leaders are Vincent Bousquet, Carsten Waechter, Jason Millard, then Francis De
Brabandere ([francisdb](https://github.com/francisdb)).

Names are shown with the GitHub handle in parentheses. toxie commits under a
handle in git, but his real name is Carsten Waechter. fuzzelhjb has no confirmed
full name here; his git commit email (`chschmidt9@gmail.com`) hints at the surname
Schmidt, but that is an inference from the email local-part, not a confirmed name.

*Verified against the GitHub contributor graph, reproducible via the
[contributors stats](https://docs.github.com/en/rest/metrics/statistics#get-all-contributor-commit-activity)
endpoint.*
