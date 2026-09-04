---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball Physics

How the physics engine simulates a table: the time model, the collision search,
the spatial trees, and the cabinet-input subsystem. This is the deep-dive behind
the [architecture hub](vpinball-architecture.md). It stays on the
mechanism and the traps; for recommended per-element tuning values see the repo's
[`docs/PhysicValues.txt`](../vpinball/docs/PhysicValues.txt) and the physics model
notes in [`docs/PhysicsPM5.txt`](../vpinball/docs/PhysicsPM5.txt).

> Provenance. Front matter records the verified commit. Each section ends with a
> `Verified against:` line. Confidence is marked inline: verified in code (with an
> anchor), from a commit, or inference. Line numbers are jump hints; trust the
> symbol.

## Two clocks: 1000 Hz physics and the historical VPT unit

Physics runs at a **fixed 1000 Hz step**: `PHYSICS_STEPTIME 1000` microseconds
(`src/physics/physconst.h:8`). Everything about the simulation loop is built on
that constant tick.

There is a second time unit that trips people up. VPX carries a historical unit,
**VPT** (Visual Pinball Time), where `DEFAULT_STEPTIME 10000` microseconds = 10 ms
= 1 VPT (`physconst.h:11`, commented "custom time unit used for historical
reason"). Velocities and accelerations in the codebase are expressed per-VPT, not
per-second or per-tick. `PHYS_FACTOR` (`physconst.h:14`) is the conversion
`PHYSICS_STEPTIME_S / DEFAULT_STEPTIME_S`. So when you read a velocity or a force
in the physics code, it is in VPU-per-VPT, not SI. Gravity is
`GRAVITYCONST 1.81751f` (`physconst.h:45`), which is 9.81 m/s² expressed in
VP-units-per-VPT² (the header shows the derivation).

**Trap.** Deriving forces from velocities in the loop is done by a plain subtract
with no delta-time scaling, which is only correct because the step is constant.
`UpdatePhysics` even asserts `physics_diff_time` equals the fixed step. If you ever
make the step variable, that subtract breaks silently.

*Verified against: `src/physics/physconst.h`, `src/physics/PhysicsEngine.cpp` (`UpdatePhysics`).*

## The update loop and catch-up

`PhysicsEngine::UpdatePhysics(targetTimeUs)` advances the simulation in fixed
steps until it reaches the target wall-clock time, so physics catches up to real
time across a variable frame rate.

It has an **anti-hang bail-out**: if one update spends over 200 ms in the loop, or
the iteration count exceeds `m_physicsMaxLoops` (derived from the table's
`PhysicsMaxLoops` setting), it skips physics time forward ("slip cycles") rather
than freezing the frame. So on an overloaded machine physics slows down instead of
stalling the render thread.

Two latency-related wrinkles live here:

- **DJRobX's loop-lengthening code** (`PhysicsEngine.cpp` ~line 402, non-BGFX
  only). When `m_minphyslooptime > 0` it artificially pads the physics loop with
  `uSleep` to create more chances to read input, and fires a controller-sync timer
  (interval `-2`) partway through so PinMAME can react. The code carries a
  `FIXME ... remove?` noting the idea is "somewhat defeated" in single-threaded
  mode because the main thread is mostly stalled waiting on the GPU anyway. BGFX's
  multithreaded loop is the real fix, which is why this is `#if !defined(ENABLE_BGFX)`.
- The BGFX build decouples render from physics on separate threads; see the
  [renderer deep-dive](vpinball-renderer.md) and the repo's
  [`docs/Latency.md`](../vpinball/docs/Latency.md) for the latency model.

*Verified against: `src/physics/PhysicsEngine.cpp` (`UpdatePhysics`, catch-up, `m_minphyslooptime`).*

## The collision cycle

`PhysicsEngine::PhysicsSimulateCycle(dtime)` is the continuous-collision-detection
core. Per iteration:

1. **Find the earliest flipper-stop hit first** (`PhysicsEngine.cpp:509-512`,
   looping `m_vFlippers` and `GetHitTime()`), seeding `hittime` before the general
   search. Flippers are special-cased because their fast rotation needs the
   tightest time bound.
2. **For each ball, search for the earliest hit** against static and dynamic
   objects, clamping `hittime` down to the soonest collision.
3. **Move everything to `hittime`** via the mover list (below).
4. **Resolve collisions and fire script events** for balls at that hit time.
5. Repeat until `dtime` is consumed.

**Trap: order is deliberately randomized to avoid bias.** Three places flip a coin
with `rand_mt_01() < 0.5f`: the order of static-vs-dynamic hit tests
(`PhysicsEngine.cpp:561`), the order of contact handling (`:678`), and a per-cycle
toggle `m_swap_ball_collision_handling` for ball-ball collision order (`:735`,
referencing an "RLC" comment block in `quadtree.cpp`). This is not noise to clean
up; the randomization exists so no ball or object gets a systematic advantage from
being processed first. Removing it to make physics "deterministic" would
reintroduce the bias it was added to kill.

The `STATICTIME`/`STATICCNTS` pair (`physconst.h:94-95`) is the anti-penetration
clamp: once more than `STATICCNTS` (10) intersections are found inside the tiny
`STATICTIME` (0.02) window, the search clamps to that minimum rather than chasing
ever-smaller time slices, trading a little penetration for loop termination.

*Verified against: `src/physics/PhysicsEngine.cpp` (`PhysicsSimulateCycle`), `src/physics/physconst.h`.*

## The mover model

Moving objects register themselves into `m_vmover`. Spinner, gate, flipper, and
plunger opt in via `MoverObject::AddToList()` during setup
(`PhysicsEngine.cpp:44-46`); balls are added separately on creation (`:140`) and
removed on destruction (`:156`). The loop drives them in two phases per cycle:

- `UpdateVelocities()` on every mover, on an integral physics-frame boundary
  (`:465-466`).
- `UpdateDisplacements(hittime)` to move objects to the collision time (`:610-611`).

So "a thing that moves under physics" is exactly "a `HitObject` whose
`GetMoverObject()` returns non-null and whose `AddToList()` is true", plus balls.

*Verified against: `src/physics/PhysicsEngine.cpp` (mover registration and the two update phases).*

## Spatial trees, and the misnamed member

Collision candidates come from spatial indexes. The naming here is a genuine trap
(`PhysicsEngine.h:88-96`):

- **Static objects use a quadtree.** The member is `m_hitoctree` and its type is
  `HitQuadtree`. The name is a fossil, it even carries a literal `/*HitKD*/`
  comment in front of the declaration. It is not an octree and not a KD-tree; it
  is a quadtree. An earlier version of this doc got the static/dynamic split
  backward by trusting the name.
- **Dynamic objects (balls) use a KD-tree.** `m_hitoctree_dynamic` is a `HitKD`,
  rebuilt as things move, **unless** `USE_EMBREE` is defined, in which case it is a
  `HitQuadtree` too. `USE_EMBREE` is an optional Intel Embree build path.
- **UI hit-testing uses a separate async quadtree**, `AsyncDynamicQuadTree*
  m_UIQuadTtree`, distinct from the dynamic ball tree and used by the editor, not
  the simulation.

The implementations are `quadtree.{h,cpp}` and `kdtree.{h,cpp}`; the hit primitives
are in `collide.{h,cpp}`, `collideex.{h,cpp}`, `hitball`, `hitflipper`,
`hitplunger`, `hittimer`.

*Verified against: `src/physics/PhysicsEngine.h` (tree members), `src/physics/` (file listing).*

## Cabinet physics

Real-cabinet input, nudge, tilt, and accelerometer, is a subsystem of its own under
`src/physics/cabinet/`, held by the engine as `PlumbHandler m_plumbHandler`. It
covers:

- **Nudge**: `NudgeHandler`, `CabinetNudgeSensor`, `GamepadNudge`, `KeyboardNudge`,
  and a `NudgeIntentHandler`.
- **Tilt**: `PlumbHandler` simulates the physical plumb-bob tilt sensor.
- **Motion filtering**: `DampedHarmonicOscillator`, `MotionKalmanAxis`,
  `MotionGainCalibratorAxis` condition raw sensor input.

This is where physics meets input; the sensor-side plumbing (how raw device axes
reach these handlers) is in the [input deep-dive](vpinball-input.md). The
user-facing setup and the velocity-input tech notes are in the repo's
[`docs/Accelerometer Velocity Input Tech Note.md`](../vpinball/docs/Accelerometer%20Velocity%20Input%20Tech%20Note.md)
and the plunger equivalent.

*Verified against: `src/physics/PhysicsEngine.h` (`m_plumbHandler`), `src/physics/cabinet/` (file listing).*
