---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball Scripting

How table VBScript is hosted and executed, how the engine is selected across
platforms, and how C++ objects (parts, the global table, plugin contributions) are
exposed to script. This is the deep-dive behind the
[architecture hub](vpinball-architecture.md). It covers the hosting
mechanism, not the script command surface; for that, see the repo's
[`docs/Script API Reference.md`](../vpinball/docs/Script%20API%20Reference.md) and
the bundled machine scripts documented in
[`docs/Scripts.txt`](../vpinball/docs/Scripts.txt).

> Provenance. Front matter records the verified commit. Each section ends with a
> `Verified against:` line. Confidence is marked inline. Line numbers are jump
> hints; trust the symbol.

## The host, not the engine

VPX does not implement a VBScript engine. It hosts the Microsoft **Active Script**
engine and implements the *site* side of that COM contract. `ScriptInterpreter`
(`src/core/ScriptInterpreter.h:20`) inherits `IActiveScriptSite`,
`IActiveScriptSiteDebug`, `IActiveScriptSiteWindow`,
`IInternetHostSecurityManager`, and `IServiceProvider`. The engine calls back into
these to resolve named items, report errors, get the owner window, and enforce
security.

The interpreter creates the engine with
`CoCreateInstance(CLSID_VBScript, ...)` (`ScriptInterpreter.cpp:30`), then
`QueryInterface`s for `IActiveScript` / `IActiveScriptParse` and calls `InitNew`.
On non-standalone builds it also wires a `ProcessDebugManager` for script
debugging (falling back to plain errors if none is installed) and sets
`IObjectSafety` security options.

*Verified against: `src/core/ScriptInterpreter.h` (site interfaces), `src/core/ScriptInterpreter.cpp` (`CoCreateInstance`, debug/security setup).*

## Engine selection is link-time, not `#ifdef`

This is the trap. There is **no `#ifdef` in the interpreter that picks an engine**.
`ScriptInterpreter` unconditionally calls `CoCreateInstance(CLSID_VBScript, ...)`.
The choice of *which* VBScript implementation that resolves to is made at **link
time**:

- On MSVC desktop Windows, it resolves to the real Windows Scripting Engine.
- On standalone and library builds, the `__LIBWINEVBS__` compile definition (set in
  `CMakeLists.txt` for those targets) routes `CoCreateInstance` to the
  **libwinevbs** VBScript implementation through a filtered import library.

So `__LIBWINEVBS__` is real and means "use libwinevbs", but grepping the
interpreter for it as an engine switch finds nothing. A code comment in
`ScriptInterpreter.cpp` notes the alternative of calling libwinevbs's factory
directly, avoiding reliance on import-library symbol ordering; the shipped path
uses the filtered import library. See
[Build variants](vpinball-architecture.md#build-variants-preprocessor-defines) for
what `__LIBWINEVBS__` selects.

*Verified against: `src/core/ScriptInterpreter.cpp` (unconditional `CoCreateInstance`, the libwinevbs comment), `CMakeLists.txt` (`__LIBWINEVBS__`).*

## The script objects

Table code sees named objects. The two globals:

- **`Global`** is `ScriptGlobalTable` (`src/core/ScriptGlobalTable.h`), the object
  carrying engine-wide methods (`PlaySound`, `Nudge`, `GameTime`, and so on).
- **`Table`** is the `PinTable`.

Each part is exposed as a named scriptable object by its table name. Objects are
registered with the engine via `AddNamedItem` (`ScriptInterpreter.cpp:198`), and
the interpreter's `AddItem`/`RemoveItem` (`:125`, `:166`) manage the set, adding
the `ScriptGlobalTable` as a global-members item so its methods are callable
unqualified. The scriptable base machinery is in `Scriptable.{h,cpp}`.

*Verified against: `src/core/ScriptInterpreter.cpp` (`AddNamedItem`, `AddItem`/`RemoveItem`), `src/core/ScriptGlobalTable.h`, `src/core/Scriptable.h`.*

## DynamicScript: runtime-typed IDispatch

Static parts have compiled COM type info. Plugin-contributed objects do not, they
are described at runtime, so VPX needs a way to present an arbitrary C++ object to
VBScript as a COM `IDispatch` without a compiled typelib. That is `DynamicScript`
(`src/core/DynamicScript.h`):

- **`DynamicTypeLibrary`** holds runtime type definitions: a name-to-type-id map,
  and per type a DispID-to-members map (with overload lists), all case-insensitive.
- **`DynamicDispatch`** is a hand-rolled `IDispatch` (`DynamicScript.h:69`) over a
  native object plus a `ScriptClassDef`. It implements `GetIDsOfNames` / `Invoke`
  against the `DynamicTypeLibrary`, so a script member access resolves through the
  runtime type info rather than a compiled interface. Note DISPID 0 is reserved for
  the default member, so member DispIDs are offset by one.

This is the machinery that makes plugin scriptable objects work, and it is what the
plugin system's COM-object override uses: `CreateObject("VPinMAME.Controller")` in
a table script can be rewritten to build a `DynamicDispatch` wrapping a
plugin-provided object. The plugin-side contract (`ScriptablePlugin`,
`SetCOMObjectOverride`, the `CreateObject` to `CreatePluginObject` rewrite) is
covered in the [plugin system deep-dive](vpinball-plugin-system.md); this doc owns
the `DynamicDispatch` mechanism it builds on.

*Verified against: `src/core/DynamicScript.h` (`DynamicTypeLibrary`, `DynamicDispatch`).*

## Shutdown

The interpreter shuts the engine down cleanly so the script's `Exit` event can
fire: it calls `IActiveScript::Close` and waits up to 5 seconds for the engine to
reach `SCRIPTSTATE_CLOSED`, then force-interrupts the script thread with a raised
exception if it has not terminated (`ScriptInterpreter.cpp`, destructor). Worth
knowing if you are debugging a table whose script hangs on exit: there is a 5s
grace window before the forced interrupt.

*Verified against: `src/core/ScriptInterpreter.cpp` (destructor close/wait/interrupt).*
