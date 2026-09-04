---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball Renderer

How VPX renders a frame: the two-layer split, the three compile-time backends, the
BGFX render thread and its handoff, the retained command-buffer, and the traps
around teardown and cross-thread ownership. This is the deep-dive behind the
[architecture hub](vpinball-architecture.md). Audience is a coder about to
change rendering code, so it stays on the mechanism and the sharp edges.

> Provenance. Front matter records the verified commit. Each section ends with a
> `Verified against:` line. Confidence is marked inline: verified in code (with an
> anchor), from a commit, or inference. Line numbers are jump hints; trust the
> symbol.

For the user-facing side, what each flavor is and how to configure rendering, see
the repo's [`docs/Build Differences.md`](../vpinball/docs/Build%20Differences.md),
[`docs/Latency.md`](../vpinball/docs/Latency.md), and
[`docs/Stereo.md`](../vpinball/docs/Stereo.md). This doc covers how those play out
in code.

## Two layers

`Renderer` (`src/renderer/Renderer.h`) is the high-level scene orchestrator: what
to draw and where, the view/MVP, scene lighting, ball rendering, and the whole
post-processing graph (ambient occlusion, bloom, tonemapping, screen-space
reflection, motion blur, FXAA/SMAA, sharpening, upscaling, stereo). It holds a
`RenderDevice*` and drives it per frame from `RenderFrame()`.

`RenderDevice` (`src/renderer/RenderDevice.h`) is the low-level backend
abstraction: how a frame is submitted to the GPU. Renderer decides the passes;
RenderDevice encodes and submits them.

*Verified against: `src/renderer/Renderer.h`, `src/renderer/RenderDevice.h`.*

## Three backends, chosen at compile time

`RenderDevice` is one `final` class whose implementation is selected
mutually-exclusively by `#if defined(ENABLE_BGFX) / #elif ENABLE_OPENGL / #elif
ENABLE_DX9`. A given binary has exactly one. The split is not just method bodies:

- **`PrimitiveTypes` is per-backend** (`RenderDevice.h:78-107`): an abstract enum
  under BGFX, aliased to `GL_*` under OpenGL, to `D3DPT_*` under DX9.
- **The entire private member block is per-backend** (`RenderDevice.h:270-390`):
  BGFX carries the render thread, semaphores, mutex, and BGFX callback; GL carries
  the `SDL_GLContext` and VAO caches; DX9 carries `IDirect3DDevice9*` and NVAPI
  state.
- Capabilities fork inline too, e.g. `SupportLayeredRendering()` queries BGFX caps,
  is always true on GL, always false on DX9 (`RenderDevice.h:159-167`).

**BGFX is the primary backend** (inference from code shape and commit weight, not a
single config line). BGFX itself dispatches to Direct3D 11/12, Vulkan, Metal, or
OpenGL under the hood and falls back if the requested one fails to init
(`RenderDevice.cpp` `RenderThread`). DX9 and OpenGL/GLES are legacy: DX9 is a
Windows-only reference build with no layered rendering and no multi-window, and
GLES has been explicitly deprecated (commit `dbd2a00aa`). Direct3D 12 was promoted
to fully supported recently (`fea593ed9`). For the flavor rationale from the user's
side, see `docs/Build Differences.md`.

*Verified against: `src/renderer/RenderDevice.h` (backend `#if` blocks, per-backend enums/members), `src/renderer/RenderDevice.cpp` (`RenderThread` backend select/fallback).*

## The render thread (BGFX only)

This is the defining feature and the riskiest area. **Under BGFX, rendering runs on
its own thread**; under GL and DX9 it runs synchronously on the logic/main thread
(there is no thread member in their private blocks, and `RenderFrame::Execute`
calls `glFlush` / `BeginScene`/`EndScene` inline). The split exists for latency:
prepare each frame as late as possible against the freshest game state, targeting
one frame in flight (`maxFrameLatency` clamped 1..3, default 1). The rationale is
documented at length atop `RenderDevice::RenderThread` (`RenderDevice.cpp` ~339).

Four sync primitives coordinate the logic thread and the render thread (all
declared in the BGFX block, `RenderDevice.h:282-285`):

- **`m_rendererInitialized`** (binary semaphore). Startup handshake: the render
  thread releases it once BGFX is up (`RenderDevice.cpp` ~509); the constructor
  spins on `try_acquire` until then. Reused at shutdown to let the thread reach
  `bgfx::shutdown`.
- **`m_frameReadySem`**. Logic-to-render "a frame is ready". The render loop blocks
  on `acquire()`; the logic thread `release()`s it in `SubmitRenderFrame`.
- **`m_frameMutex`**. Guards the retained `m_renderFrame` shared between the two
  threads. The render thread holds it while encoding a frame and while queuing
  texture uploads.
- **`m_renderThreadStopped`**. Render-to-main "I have left the loop", so resources
  are not freed while a frame is in flight.

**Frame handoff is a reentrant, cross-thread function.** `SubmitRenderFrame`
(`RenderDevice.cpp` ~2596) behaves differently by caller:

- On the **logic thread**: assert `!m_framePending`, set `m_framePending = true`,
  unlock `m_frameMutex`, release `m_frameReadySem`, then busy-wait
  (`while (m_framePending || !m_frameMutex.try_lock()) ProcessOSMessages(); Sleep(0)`)
  until the render thread has consumed the frame. A blocking mutex ping-pong.
- On the **render thread** (the normal in-loop path, already holding the lock): it
  actually runs `m_renderFrame->Execute(...)`.

Two loops: `BGFXDesktopRenderLoop` (synced on the playfield display, with three
pacing modes, managed VSync, waitable-swapchain pacing, and a frames-in-flight
flushing heuristic) and `BGFXOpenXRRenderLoop` (`#ifdef ENABLE_XR`, synced on the
headset via `xrWaitFrame` and predicted display time instead of VSync).

*Verified against: `src/renderer/RenderDevice.cpp` (`RenderThread`, `BGFXDesktopRenderLoop`, `BGFXOpenXRRenderLoop`, `SubmitRenderFrame`), `src/renderer/RenderDevice.h:282-285`.*

### Trap: teardown races the render thread

The render thread only re-checks `m_renderDeviceAlive` **between frames**, so
anything freed while it is mid-frame is a use-after-free. This has bitten twice and
both fixes are recent:

- `511493549` "fix shutdown crash from freeing renderer while render thread runs"
  added the `m_renderThreadStopped` wait to `~RenderDevice`.
- `bebc84b0d` "stop the render thread before freeing render targets on exit"
  (2026-06-24): `Player::~Player` freed render targets (via `RenderProbe`) before
  `~RenderDevice` stopped the thread, so an in-flight frame dereferenced a freed
  target. The stop-wait had to move earlier.

The rule for anyone touching teardown, in this exact order (`RenderDevice.cpp`
~1819-1826): set `m_renderDeviceAlive = false`, release `m_frameReadySem`, acquire
`m_renderThreadStopped`, and only then free any GPU resource. The destructor
comment flags this explicitly.

Related: texture uploads under BGFX do not touch the GPU on the logic thread. They
queue the sampler under `m_frameMutex` into `m_pendingTextureUploads` and hand off
to the render thread, and those samplers own BGFX textures, so they must be cleared
before `bgfx::shutdown` (commit `978307e4d`).

*Verified against: `src/renderer/RenderDevice.cpp` (`~RenderDevice`, `UploadTexture`), commits `511493549`, `bebc84b0d`, `978307e4d`.*

## The retained command-buffer

Rendering is not immediate; it builds a retained frame and executes it in one go.
The hierarchy is `RenderFrame` owns `RenderPass`es, each targeting one
`RenderTarget` and owning `RenderCommand`s (`RenderFrame.h`, `RenderPass.h`,
`RenderCommand.h`). Commands are a tagged union over clear / copy / draw-mesh /
draw-quad. Frames, passes, and commands are pooled and recycled.

**Building** goes through the RenderFrame API on `RenderDevice`
(`RenderDevice.h:108-140`). `SetRenderTarget` reuses the current pass or adds one,
and wires dependencies automatically: a pass that reads a target's existing content
inherits that target's `m_lastRenderPass` as a precursor. Draw/Clear/Blit allocate
a pooled `RenderCommand` and `Submit` it to the current pass.

**Scheduling** is the clever part (`RenderFrame::Execute`, `RenderFrame.cpp:135`):

1. `SortPasses` walks dependencies backward from the final pass, drops passes that
   do not contribute, and inserts each as late as possible before its first
   consumer while respecting dependency and render-target-overwrite constraints,
   preferring to land next to a same-target pass so they can merge.
2. Consecutive same-target mergeable passes are merged.
3. Per pass, `SortCommands` (`RenderPass.cpp:63`) stable-sorts draw commands with a
   large hand-written comparator that preserves pre-10.8 ordering: clears first,
   kickers before balls, opaque before transparent, old-table playfield (very high
   depth bias) first, then by shader technique, depth, mesh buffer, and state.
4. A command with an unmet pass dependency splits its pass in two and inserts the
   dependency between (the refraction screen-copy case).

**Trap: the pass sorter is backward-compatibility-shaped, not clean.** The comment
block in `RenderPass::SortCommands` spells out the pre-10.8 order it must reproduce,
and it is full of deliberate hacks: kickers disable depth test and are force-sorted
before balls (with a note that the "right fix" is stencil/CSG and that the hack
breaks kicker rendering in VR); the old-table playfield is identified by a
depth-bias magnitude over 50000; flasher DMDs are shifted by -10000 to land between
opaque and transparent. These magic biases are enforced elsewhere (`pintable.cpp`,
`flasher.cpp`). Do not "tidy" the comparator without understanding it encodes a
compatibility contract with tables authored years ago.

*Verified against: `src/renderer/RenderFrame.cpp` (`Execute`, `SortPasses`), `src/renderer/RenderPass.cpp` (`SortCommands`, `Execute`, `Submit`), `src/renderer/RenderDevice.cpp` (`SetRenderTarget`, draw/clear/blit).*

## Windows and outputs

`VPX::Window` (`src/renderer/Window.h`, namespace `VPX`) wraps one `SDL_Window`
(`GetCore()`), tracking logical vs pixel units and pixel density, window mode,
refresh rate, and HDR/WCG display properties, and owning one backbuffer render
target. `VPX::RenderOutput` wraps a window-or-embedded output per `VPXWindowId`
(playfield, backglass, score, topper) with modes disabled / window / embedded.

`RenderDevice` holds `vector<VPX::Window*> m_outputWnd`, with `m_outputWnd[0]` the
primary playfield swapchain (the only non-stereo one). `AddWindow`
(`RenderDevice.cpp` ~1973) builds a BGFX swapchain from the SDL native handle (per
platform: X11/Wayland/Metal layer/HWND/Android), and `RemoveWindow` erases it.
**Multi-window is effectively a BGFX capability**; GL and DX9 support only one
output window (noted at `RenderDevice.h:228`). The desktop loop handles per-window
swapchain resize by remove, `bgfx::frame(BGFX_FRAME_FLUSH)`, re-add.

*Verified against: `src/renderer/Window.h`, `src/renderer/RenderDevice.cpp` (`AddWindow`, `RemoveWindow`, `m_outputWnd`).*

## VR

`VRDevice` (`src/renderer/VRDevice.h`) integrates OpenXR and its **entire body is
`#if defined(ENABLE_XR)`**. It is an optional path selected at runtime: the render
thread picks `BGFXOpenXRRenderLoop` when `g_pplayer->m_vrDevice` is set. Per-backend
XR graphics shims exist (`XRD3D11Backend`, `XRD3D12Backend`, `XRVulkanBackend`). The
old OpenVR path was removed (`6524789e3`, `f9410f415`); VR is OpenXR-only now. VR
preview under Vulkan is a known gap (a `FIXME` and a "should still render to the
preview window" note).

*Verified against: `src/renderer/VRDevice.h` (`ENABLE_XR` gating), `src/renderer/RenderDevice.cpp` (loop selection), commits `6524789e3`, `f9410f415`.*

## Other known debt

- **The latency pre-sleep is written but hard-disabled** behind `if (false)` in the
  desktop loop, pending a robust stability-margin estimate. A real un-landed
  feature, not dead code to delete.
- **Exclusive fullscreen is effectively dead under BGFX** (asserted against; the
  comment calls it "somewhat deprecated").
- Assorted `Renderer.cpp` FIXMEs: Gaussian-blur kernel size is not
  resolution-scaled, exposure is stubbed, tonemapping does not yet handle mixed
  HDR/SDR multi-display, visual nudge scales non-uniformly in clip space.

*Verified against: `src/renderer/RenderDevice.cpp` (`if (false)` pre-sleep, fullscreen assert), `src/renderer/Renderer.cpp` (FIXMEs).*
