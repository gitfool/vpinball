---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball Configuration

How settings work at the code level: how properties are declared, how the global
and table-override layers combine, and where plugin settings actually come from.
This is the deep-dive behind the [architecture hub](vpinball-architecture.md). It
complements the repo's user-facing docs and a third-party config reference (both
linked below); it goes to the mechanism, not the exhaustive key list.

> Provenance. Front matter records the verified commit. Each major section ends
> with a `Verified against:` line naming its files. Confidence is marked inline
> where it matters.

## Sources this complements

- The repo's [`docs/FileLayout.md`](../vpinball/docs/FileLayout.md) describes the
  user-facing model: `VPinballX.ini` for globals, a per-table override file, and
  the F12 in-game UI that writes either layer.
- The [`docs/RegistryKeys.txt`](../vpinball/docs/RegistryKeys.txt) and
  [`docs/CommandLineParameters.txt`](../vpinball/docs/CommandLineParameters.txt)
  cover legacy registry keys and command-line overrides.
- A **third-party fork** maintains a topic-by-topic config reference for 10.8.1 at
  [Le-Syl21/vpinball `docs/10.8.1/`](https://github.com/Le-Syl21/vpinball/tree/master/docs/10.8.1)
  (bilingual; input, view, windows, rendering, audio, plugins, files, VR, removed
  settings). It is a useful catalog of individual keys and per-plugin sections.
  Treat it as unofficial: it is a fork, not pinned by anything this repo builds,
  it may drift from `master`, and at least one of its mechanism claims is wrong at
  our commit (see [Plugin settings](#plugin-settings)). Cite it for the key
  catalogs, verify any mechanism claim against the code.

## The property registry

Settings are not free-form ini reads. Every setting is a registered *property*
with an id, a type, a group, a label, a default, and a contextual flag. The core
is `Settings` (`src/core/Settings.h`, `src/core/Settings.cpp`) over a
`PropertyRegistry` and a `LayeredINIPropertyStore`.

Static properties are declared in `src/core/Settings_properties.inl` through a set
of `Prop*` macros, one line per setting:

```
PropBool(Editor, EnableLog, "Enable Log"s, "Enable general logging ..."s, true);
PropInt(Player, MusicVolume, "Backglass Volume"s, "..."s, 0, 100, 100);
PropStringDyn(Player, PlayfieldDisplay, "Display"s, "..."s, ""s);
```

The `inl` file is an X-macro table: it is `#include`d more than once
(`Settings.h:198` and `Settings.cpp:268`), each time with the `Prop*` macros
redefined to emit a different thing, the per-property id members and typed
accessors from the header pass, the registry registration from the `cpp` file pass.
The macro bodies differ by compiler (`__GNUC__` vs MSVC), which is why they are
defined in both `Settings.h` and `Settings.cpp`. The accessor names are generated,
`PropInt(Player, MusicVolume, ...)` yields `GetPlayer_MusicVolume()` and
`SetPlayer_MusicVolume(v, asTableOverride)`.

*Verified against: `src/core/Settings.h`, `src/core/Settings.cpp`, `src/core/Settings_properties.inl`.*

## Global versus table override

The `Dyn` suffix on a macro is the whole story of table overrides. It sets the
property's `isContextual` flag:

- `PropBool` / `PropInt` / `PropEnum` / `PropString` declare a **global-only**
  setting (`isContextual = false`).
- `PropBoolDyn` / `PropIntDyn` / ... declare a **contextual** setting
  (`isContextual = true`), one a table may override.

At the code level this is why every generated setter takes an `asTableOverride`
bool: `Set##group##_##prop(v, asTableOverride)` routes the write to either the
global layer or the table-override layer of the `LayeredINIPropertyStore`. The
store is layered so a read falls back from the table override to the global value.
This is the mechanism under the user-facing "save as global or as table override"
choice in the F12 UI that `FileLayout.md` describes.

So a contextual (`Dyn`) property such as `Player.PlayfieldDisplay` can be pinned
per table, while a plain global such as `Editor.EnableLog` cannot. The macro
suffix in `Settings_properties.inl` is the source of truth for which is which.

*Verified against: `src/core/Settings.h` (macro bodies, `Set...` signatures), `src/core/Settings_properties.inl`.*

## Build-conditional defaults

Some property lines vary by build. `Settings_properties.inl` contains `#ifdef`
branches, for example `PlayfieldFullScreen` offers a "Fullscreen" mode on non-BGFX
builds but only "Windowed / Borderless Fullscreen" under `ENABLE_BGFX`.

Defaults can also key off `g_isStandalone`, a compile-time constant in
`src/core/def.h` (a `#define`/`constexpr` set to `true` under `__STANDALONE__`,
`false` otherwise). Standalone builds are the ones cabinets and mobiles run, so
they default several things on that a plain desktop editor build leaves off. See
[Build variants](vpinball-architecture.md#build-variants-preprocessor-defines) for
what `__STANDALONE__` selects.

*Verified against: `src/core/Settings_properties.inl`, `src/core/def.h`.*

## Plugin settings

This is where the third-party fork's reference is wrong at our commit, and where
verifying against the code matters.

**Only `Enable` is owned by VPX, and it is registered dynamically, not in the
`inl` file.** When `Player` loads plugins it registers a `"Plugin.<id>" / "Enable"`
bool per discovered plugin, in the load loop:

```cpp
// src/core/player.cpp
if (auto existing = Settings::GetRegistry().GetPropertyId("Plugin." + plugin->m_id, "Enable"s); existing.has_value())
   enableId = existing.value();
else
   enableId = Settings::GetRegistry().Register(std::make_unique<VPX::Properties::BoolPropertyDef>(
      "Plugin." + plugin->m_id, "Enable"s, "Enable"s, "Enable/Disable plugin '" + plugin->m_name + '\'', true, false));
```

The fork states these `Enable` keys "are declared in `src/core/Settings_properties.inl`".
At `c321a1812` they are not; grepping the `inl` file for `Plugin.PinMAME` (or any
of them) finds nothing. They are registered at runtime in `player.cpp`, keyed off
the plugin id discovered from `plugin.cfg`. The count of plugins is not fixed in
the `inl` file either; it is whatever is discovered on the plugin path.

**Every other key in a plugin's section is registered by the plugin itself**, at
load time, through the message API's `RegisterSetting` with the `MSGPI_*_SETTING`
macros. This half the fork gets right. So `[Plugin.PinMAME] Sound` and `Cheat`
live in `plugins/pinmame/`, not in any VPX property file. See the
[plugin system deep-dive](vpinball-plugin-system.md) for how `RegisterSetting`
rides the message bus.

Two consequences, both real and both worth knowing:

- **A disabled plugin declares nothing.** Its non-`Enable` keys never register,
  so they do not appear in the ini or the F12 UI. An empty-looking
  `[Plugin.<name>]` section is a plugin that has not loaded, not a broken install.
- **The authoritative key list for a plugin is its own source**, under
  `plugins/<name>/`, not any central VPX file.

*Verified against: `src/core/player.cpp` (dynamic `Enable` registration), `src/core/Settings_properties.inl` (absence of plugin keys), and the plugin sources under `plugins/`.*
