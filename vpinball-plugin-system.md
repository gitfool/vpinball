---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball Plugin System

The plugin system is the defining architectural change of the 10.8.1 line. It
replaces the 10.8.0 COM/ActiveX subsystem model with a portable, in-process
message bus that lets PinMAME, B2S, DOF, colorizers, and others share data as
peers. This doc explains how it works now and why it is shaped this way. It is
the deep-dive behind the [architecture hub](vpinball-architecture.md).

> Provenance. Front matter records the commit this was verified against. Each
> major section ends with a `Verified against:` line naming its files, so
> staleness is checked per-section. Confidence is marked inline: verified in code,
> from a commit message, or inference. The distinction is deliberate; the intent
> record for this subsystem is thin, so a plausible story is not a documented one.
>
> High-churn area. `plugins/plugins/` is one of the most actively changing parts
> of the repo, and the API headers carry an explicit "this will evolve and may
> break" banner. Expect this doc to go stale faster than the others.
> Re-check the per-section files against `master` before relying on a detail.

## The core: a message bus of function pointers

The transport is a C struct of function pointers, `MsgPluginAPI`
(`plugins/plugins/MsgPlugin.h`), implemented in C++ by `MsgPI::MsgPluginManager`
(`plugins/plugins/MsgPluginManager.cpp`). C, not C++, at the boundary so plugins
built by any toolchain can link against it. The manager is a process singleton:
its constructor asserts no other instance exists and stores `this` in a static.

A message is identified by a `(namespace, name)` pair. `GetMsgID` (line 122)
interns that pair into a small dense integer, the index into a
`std::vector<MsgEntry>`, and reference-counts it. Every caller that wants the same
message gets the same id; `ReleaseMsgID` drops the count and trims dead trailing
entries. Each entry holds a list of `(endpointId, callback, context)` subscribers.

The four operations on that bus:

- `SubscribeMsg(endpointId, msgId, callback, userData)` registers interest.
- `BroadcastMsg(endpointId, msgId, data)` fans out to every subscriber.
- `SendMsg(endpointId, msgId, targetEndpointId, data)` delivers to one endpoint.
- `UnsubscribeMsg(msgId, callback, userData)` removes one subscription.

Namespaces keep message names from colliding across plugins. The ones in the tree
are `"MsgPlugin"` (transport), `"VPX"` (host events and API), `"Controller"`
(shared machine state), `"Scriptable"` (script contribution), and `"Login"` for
logging. That last one is a literal `"Login"` in `LoggingPlugin.h`, almost
certainly a typo for "Logging", but it is the real namespace string and changing
it would break the wire contract, so it stays.

### The endpoint model

Every plugin gets a 1-based `endpointId`. Endpoint 0 means "none". VPX itself is
an endpoint: `VPXPluginAPIImpl` registers a `"vpx"` plugin and hands out
`GetVPXEndPointId()`. So the host and every plugin are peers on one bus, which is
the property that makes the whole design work: N subscribers can each receive the
same broadcast and read the same state, and nobody's read consumes it.

*Verified against: `plugins/plugins/MsgPlugin.h`, `plugins/plugins/MsgPluginManager.cpp`, `src/core/VPXPluginAPIImpl.cpp`.*

## Plugin lifecycle

**Discovery.** `MsgPluginManager::ScanPluginFolder` (line 373) walks
subdirectories of the plugin folder, reads a `plugin.cfg` INI from each, computes
a platform library key (`windows.x64`, `linux.aarch64`, `macos.arm64`, and so
on), validates the referenced library exists, and registers a `MsgPlugin` with
`endpointId = plugins.size() + 1`. The cfg also supplies name, description,
author, version, and link.

**Where it is driven.** `Player` runs discovery in `src/core/player.cpp`. On
desktop it wraps SDL's `SDL_LoadObject` / `SDL_LoadFunction` in an
`SDLModuleLoader` and calls `ScanPluginFolder` on the app's plugin path. On
`__LIBVPINBALL__` (mobile) builds it instead calls `SetupStaticPlugins`, because
those platforms link plugins statically.

**Enable and load.** After scanning, `Player` loops the plugins in registration
order and, for each, reads a per-plugin `"Plugin.<id>" / "Enable"` bool setting
(default true). Enabled plugins get `Load`, disabled ones are logged and skipped.
So load order is discovery order, and enable/disable is a setting. Live toggling
happens from the in-game plugin settings page.

**The export contract.** A dynamic plugin exports two C symbols,
`xxxPluginLoad(endpointId, MsgPluginAPI*)` and `xxxPluginUnload()`, where `xxx` is
the plugin id (the id prefix avoids clashes under static linking). `MsgPlugin::Load`
(line 504) resolves them by concatenating `m_id + "PluginLoad"` / `"PluginUnload"`,
calls load, then broadcasts `MsgPlugin.OnPluginLoaded`. `Unload` mirrors it.

**Cleanup is enforced by assertion.** `UnloadPlugin` checks the plugin left no
dangling timers and no leaked message callbacks, and the manager destructor checks
no message leaked a refcount. A well-behaved plugin pairs every `GetMsgID` with
`ReleaseMsgID` and every `SubscribeMsg` with `UnsubscribeMsg`. These are asserts;
see the threading caveat below for what that means in release builds.

*Verified against: `plugins/plugins/MsgPluginManager.cpp`, `src/core/player.cpp`, `plugins/plugins/MsgPlugin.h`.*

## The layered APIs

Each layer above the raw transport is a convention: a namespace, a set of message
names, and usually a "GetAPI" broadcast that returns a struct of function
pointers.

**MsgPlugin** is the transport itself: the four bus operations, endpoint lookup,
settings registration (`MsgSettingDef` plus the `MSGPI_*_SETTING` helper macros),
and `RunOnMainThread` / `FlushPendingCallbacks`.

**VPXPlugin** (`VPXPlugin.h`) carries VPX events and a host API fetched via
`VPXPI_MSG_GET_API`. Events include `VPXPI_EVT_ON_GAME_START` / `..._ON_GAME_END`,
`..._ON_PREPARE_FRAME`, `..._ON_UPDATE_PHYSICS`, `..._ON_ACTION_CHANGED`. The API
struct exposes table info, notifications, view setup, input state (with the
`VPXACTION_*` enum), game time, texture management, ancillary-window rendering,
and `RunScript`. The host side is `src/core/VPXPluginAPIImpl.cpp`.

**ControllerPlugin** (`ControllerPlugin.h`) is the largest layer and carries
shared machine state. Its design is service discovery: for each feature there is
a `GetSource` message and a matching `OnSourceChanged` event. The pairs:

| Feature | Get / OnChange | Notes |
|---------|----------------|-------|
| Controllers | `GetControllers` / `OnControllersChanged` | `ControllerDef {endpointId, gameId}` |
| Game state | `GetStateSrc` / `OnStateSrcChanged` | solenoids, lamps, GI, switches; typed `StateDef` with `GetState`/`SetState` hooks |
| Matrix/DMD displays | `GetDisplays` / `OnDisplaysChanged` | `overrideId` lets one source supersede another |
| Segment displays | `GetSegDisplays` / `OnSegDisplaysChanged` | 7/9/14/16-segment layouts |
| Audio streams | `GetAudioSrc` / `OnAudioSrcChanged` + `AudioUpdate` | a null buffer destroys a stream |

The `overrideId` chain is how colorization works: a Serum or VNI source advertises
the raw PinMAME display as the source it overrides, and the host prefers the
override. Displays and audio both use this. The colorization formats those plugins
consume, and their history, are in the
[DMD colorization deep-dive](vpinball-dmd-colorization.md).

**ScriptablePlugin** (`ScriptablePlugin.h`) lets a plugin contribute typed objects
to the VBScript engine. Its key trick is `SetCOMObjectOverride`. The host stores
the class definition, and `ApplyScriptCOMObjectOverrides` (in `VPXPluginAPIImpl.cpp`)
rewrites `CreateObject("X")` in the table script to `CreatePluginObject("X")` when
`X` is overridden, then `CreateCOMPluginObject` builds a `DynamicDispatch` wrapping
the plugin's object. This is how a plugin can transparently stand in for a legacy
`CreateObject("VPinMAME.Controller")` call without the table script changing.

**LoggingPlugin** (`LoggingPlugin.h`) routes plugin logs into VPX's shared PLOG,
with levels debug/info/warn/error.

*Verified against: `plugins/plugins/VPXPlugin.h`, `plugins/plugins/ControllerPlugin.h`, `plugins/plugins/ScriptablePlugin.h`, `plugins/plugins/LoggingPlugin.h`, `src/core/VPXPluginAPIImpl.cpp`.*

## Two conventions worth knowing

**Two-pass array sizing, Vulkan style.** Every `GetSource` message is answered
twice. First the caller broadcasts with `maxEntryCount = 0` to learn the total
`count`; then it allocates and broadcasts again with the buffer. Responders always
increment `count` past `maxEntryCount` so the caller learns the true total even
when the first pass copies nothing. `GetCtrlItems<T>` in `ControllerPlugin.h`
wraps this for C++ callers, and the `CtrlItemProvider` / `CtrlItemConsumer`
helpers implement the producer and consumer sides with automatic
subscribe/unsubscribe and a `With()` accessor for thread-safe reads.

**Thread affinity by assertion.** The bus is single-threaded. Data from a
`GetSource` message must stay valid until the matching `OnSourceChanged`, and the
API must be called on the plugin API thread (the one that called `Load`/`Unload`).
`MsgPluginManager::AssertAPIThread()` (line 89) guards the entry points, but it is
a plain `assert`, so it compiles out under `NDEBUG`. In a release build a plugin
that calls the API off-thread races silently rather than failing. The only
sanctioned cross-thread calls are `RunOnMainThread` and the getters explicitly
marked thread-safe (state, display, and audio getters).

*Verified against: `plugins/plugins/ControllerPlugin.h`, `plugins/plugins/MsgPluginManager.cpp`.*

## Two newer pieces

Both of these are recent and pre-alpha; both carry the "will evolve, may break"
banner the whole API carries.

**ResURIResolver** (`ResURIResolver.h`) is a URI façade over the controller state,
display, and segment APIs, so a caller can name a source with a string instead of
running the GetSource/OnChange dance itself. The scheme is
`ctrl://authority/path?query`, for example `ctrl://pinmame/state?group=1&io=11`
for solenoid 11, or `ctrl://flexdmd/display`. It is backed by `CtrlItemConsumer`
members and per-link caches. Several query features are still unimplemented, and a
recent fix ([`98c424c29`](https://github.com/vpinball/vpinball/commit/98c424c29),
"Fix use-after-destroy in ResURIResolver destructor") shows its lifecycle has been
fragile.

**B2SPluginEventStream** (`B2SPluginEventStream.h`) is a compatibility adapter. It
synthesizes the old B2S letter-coded event stream (W for a switch, L for a lamp,
S for a solenoid, G for GI, and so on) out of the new pull-based controller state,
by polling on a thread and diffing successive frames. It exists because the new
API is pull-based and non-consuming, so something has to manufacture the
edge-triggered event feed that B2S-era consumers were written against. That
edge-vs-poll bridge being its purpose is inference from its structure, not a
stated design note.

*Verified against: `plugins/plugins/ResURIResolver.h`, `plugins/plugins/B2SPluginEventStream.h`.*

## Why it is shaped this way

**The COM-to-plugins move landed between 10.8.0 and 10.8.1.** The foundational
commit is [`31661ff47`](https://github.com/vpinball/vpinball/commit/31661ff47)
("Initial plugin API skeleton", Vincent Bousquet
([vbousquet](https://github.com/vbousquet)), May 2024). `git describe` places
it after the 10.8.0 release and before 10.8.1, which corroborates the version
framing. The transport/VPX split came later, in
[`443fe32ad`](https://github.com/vpinball/vpinball/commit/443fe32ad)
("Plugin: split base MSG API from VPX API", Sep 2024). There is no PR number on the
skeleton commit; it was a direct commit, not a squashed merge.

**Non-consuming multi-consumer reads are a real, verified property.** The bus
broadcasts to all subscribers and state is exposed through `GetState` hooks and
`GetSource` discovery, with the contract that data stays valid until the next
change event. `CtrlItemConsumer` lets any number of independent consumers track
the same source list. So the headline benefit over the COM model, that many
consumers can read the same machine state without draining it, is verifiable in
the code.

**The old B2S-as-hub rationale is inference, not a cited fact.** The story is that
the 10.8.0 COM `VPinMAME.Controller` interface returned only deltas from
`ChangedLamps` / `ChangedSolenoids`, so the first reader drained them and B2S had
to be the single hub that read once and re-fanned. That is architecturally
consistent with how VPinMAME's COM interface is known to behave, but no commit
message at this commit states it. Searching the history for `ChangedSolenoids`
surfaces only plumbing commits, not a design note. Treat it as well-founded
inference carried over from prior knowledge, not as documented intent.

**Controller discovery replaced an earlier game-state-change scheme.** The
`GetControllers` / `OnControllersChanged` discovery model replaced an older
`CtlOnGameStateChgMsg` broadcast, in
[`2157f4ea4`](https://github.com/vpinball/vpinball/commit/2157f4ea4)
("Plugin: refactor controller enumeration"). That commit body cites two reasons
and links the issues: let a plugin activate after a controller has already
started, and disambiguate multiple simultaneous controllers, fixing
[#3670](https://github.com/vpinball/vpinball/issues/3670) and
[#3671](https://github.com/vpinball/vpinball/pull/3671). This is documented
history, not inference. Note that these `Controller`-namespace game-start/end
concepts are distinct from the `VPX`-namespace `VPXPI_EVT_ON_GAME_START/END`
events, which are unrelated and current.

*Verified against: git history (`31661ff47`, `443fe32ad`, `2157f4ea4`), `plugins/plugins/` (code).*

## Known debt

- **`AssertAPIThread` is unenforced in release.** As above, thread affinity is an
  assert that compiles out, so the single-thread guarantee is honor-system in
  shipping builds.
- **`RunOnMainThread` blocking path spins.** The negative-delay blocking call
  waits with a `sleep_for(100ns)` loop and carries a `// FIXME block cleanly`.
- **Script type libraries are not separated per plugin.** `CreateCOMPluginObject`
  carries a `// FIXME ... collision may occur`: two plugins registering the same
  class name would collide.
- **Whole surface is explicitly unstable.** Every API header carries a warning
  that the interface will change and may break plugins. Any plugin work should
  expect churn here.
