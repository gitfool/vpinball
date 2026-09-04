---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball Input

How physical input (keyboard, joystick, mouse, VR controllers, Open Pinball
Device) reaches game actions and physics sensors. This is the deep-dive behind the
[architecture hub](vpinball-architecture.md). It covers the code model; the
user-facing setup for the specialized input paths is in the repo's
[`docs/Open Pinball Device User Guide.md`](../vpinball/docs/Open%20Pinball%20Device%20User%20Guide.md),
[`docs/Plunger Velocity Input User Guide.md`](../vpinball/docs/Plunger%20Velocity%20Input%20User%20Guide.md),
and the accelerometer/plunger tech notes.

> Provenance. Front matter records the verified commit. Each section ends with a
> `Verified against:` line. Confidence is marked inline. Line numbers are jump
> hints; trust the symbol.

## The layered model

`InputManager` (`src/input/InputManager.h`, held by `Player` as `m_pininput`) sits
at the center of four layers. Reading bottom-up:

1. **Devices.** Physical devices register with `RegisterDevice(settingsId, type,
   name)` returning a device id. `DeviceType` is keyboard, joystick, mouse,
   VR controller, or Open Pinball Device (`InputManager.h`, the `DeviceType`
   enum). SDL is the source for keyboard/joystick/mouse (`SDLInputHandler.h`),
   OpenPinDev has its own handler (`OpenPinDevHandler`), and VR has
   `XRInputHandler`. There is no separate "HID" layer; HID arrives through SDL and
   OpenPinDev.
2. **Events.** Devices push raw events through `PushButtonEvent` /
   `PushAxisEvent` / `PushTouchEvent`. `InputManager` derives from
   `ButtonMapping::ButtonInputEventManager` and `SensorMapping::AxisInputEventManager`,
   so button and axis routing are two event buses it implements.
3. **Mappings.** A device declares its default bindings via
   `SetDeviceDefaultMapping` and a `MappingSetupHandler` with three verbs:
   `MapAction` (button(s) to a game action), `MapPlunger` (an axis to a
   `PlungerSensor`), and `MapNudge` (an axis to a `NudgeSensor`). So a device does
   not hardcode what its inputs do; it declares candidate mappings and the manager
   binds them.
4. **Actions.** `InputAction` (`InputAction.h`) is a named game action with a
   stable id. `InputManager` owns `vector<unique_ptr<InputAction>>` and exposes an
   id getter per action (`GetLeftFlipperActionId`, `GetTiltActionId`,
   `GetLaunchBallActionId`, and dozens more). This is the id set the plugin bridge
   maps into `VPXACTION_*` at game start (see the plugin deep-dive's `OnGameStart`).

`ProcessInput()` is the per-frame pump; `HandleSDLEvent` feeds it from the SDL
event stream. Actions can opt into per-update callbacks via `RegisterOnUpdate`.

*Verified against: `src/input/InputManager.h` (device/event/mapping/action layers), `src/input/InputAction.h`, `src/input/SDLInputHandler.h`, `src/input/OpenPinDevHandler.h`, `src/input/XRInputHandler.h`.*

## Nudge and plunger straddle input and physics

`InputManager` owns the `NudgeHandler` and `PlungerHandler`
(`m_nudgeHandler`, `m_plungerHandler`), but the nudge handler's implementation
lives in the physics cabinet subsystem (`VPX::Physics::NudgeHandler`). This is the
seam between input and physics: the device layer maps an axis to a
`NudgeSensor` / `PlungerSensor` via `MapNudge` / `MapPlunger`, and the handler
(input-owned) feeds the physics simulation.

So the ownership is split on purpose: input owns the handler objects and the
device-to-sensor binding; physics owns the sensor conditioning and how it enters
the simulation (the Kalman/harmonic-oscillator filters). The physics side is in the
[physics deep-dive](vpinball-physics.md#cabinet-physics). The plunger's own filter
is local to input (`PlungerKalmanFilter.h`), while the cabinet nudge motion filters
are in `src/physics/cabinet/`.

*Verified against: `src/input/InputManager.h` (`m_nudgeHandler`, `m_plungerHandler`, `MapNudge`/`MapPlunger`), `src/input/PlungerHandler.h`, `src/input/PlungerKalmanFilter.h`, `src/input/PhysicsSensor.h`, `src/input/SensorMapping.h`.*

## Other capabilities

- **Touch** input maps screen regions to actions (`TouchRegionDef`,
  `GetTouchState`), for mobile and touchscreen cabinets.
- **Rumble** feedback, including flipper-contact rumble scaled by impact velocity
  (`PlayFlipperContactRumble`), routed to devices that support it.
- **Button capture** (`StartButtonCapture`) is the mechanism behind the
  "press a key to bind it" mapping UI.
- **VR** adds an `XRInputHandler` through `AddInputHandler` / `RemoveInputHandler`,
  with VR-specific actions (view centering, view up/down).

*Verified against: `src/input/InputManager.h` (touch, rumble, button capture, VR handler).*
