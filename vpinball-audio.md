---
verified_against: c321a1812
verified_date: 2026-09-04
---

# VPinball Audio

How VPX plays sound: the two-engine backglass/playfield split, the miniaudio and
SDL backends, sound effects vs music vs streamed audio, the playfield
spatialization modes, and how plugin audio sources (PinMAME, AltSound, PUP) mix in.
This is the deep-dive behind the [architecture hub](vpinball-architecture.md).

> Provenance. Front matter records the verified commit. Each section ends with a
> `Verified against:` line. Confidence is marked inline. Line numbers are jump
> hints; trust the symbol.

## Two engines: playfield and backglass

`AudioPlayer` (`src/audio/AudioPlayer.h`, namespace `VPX`, held by `Player` as
`m_audioPlayer`) runs **two independent miniaudio engines**: a playfield engine
(`m_playfieldEngine`) and a backglass engine (`m_backglassEngine`). `GetEngine`
picks between them by `SoundOutTypes` (`SNDOUT_TABLE` to playfield, else
backglass). The split exists because a cabinet typically routes table/mechanical
sounds to speakers in the cabinet body and backglass/emulation audio to the
backbox, often on separate audio devices, chosen at construction
(`AudioPlayer(backglassDevice, playfieldDevice, playfieldSoundMode)`).

Backends: miniaudio (`ma_engine` / `ma_context` / `ma_device_ex`) does the mixing
and spatialization; the backglass path also holds an `SDL_AudioDeviceID`. So it is
miniaudio primary with SDL3 involved on the device side, not one or the other.

*Verified against: `src/audio/AudioPlayer.h` (`m_playfieldEngine`, `m_backglassEngine`, `GetEngine`, `m_maContext`, `m_backglassDevice`, `m_backglassSDLDevice`).*

## Three kinds of audio

`AudioPlayer` handles three distinct paths (its own header comment enumerates
them):

1. **Sound effects** (`SoundPlayer`, `src/audio/SoundPlayer.h`): table `Sound`
   objects played with dynamic effects (SSF, panning). Keyed by `Sound*` in
   `m_soundPlayers`, so one sound can have several concurrent players.
2. **Music**: a single backglass music player (`m_music`), the target of the
   script `PlayMusic` command.
3. **Streamed audio** (`AudioStreamPlayer`, `src/audio/AudioStreamPlayer.h`): the
   plugin path. `OpenAudioStream` / `EnqueueStream` / `SetStreamVolume` /
   `CloseAudioStream` give an opaque `AudioStreamID` (a `shared_ptr<AudioStreamPlayer>`)
   that plugins feed. This is how PinMAME, AltSound, and PUP get their audio out.

Note the two `Sound` classes, easy to confuse: `src/audio/Sound.*` is the runtime
audio asset; `src/parts/Sound.*` is the table element. The loader reads the part;
the runtime plays through the audio one.

*Verified against: `src/audio/AudioPlayer.h` (the three paths, `AudioStreamID` API), `src/audio/SoundPlayer.h`, `src/audio/AudioStreamPlayer.h`.*

## Playfield spatialization modes

The `SoundConfigTypes` enum (`AudioPlayer.h`) is where a lot of cabinet-audio
nuance lives, and the names are not self-explanatory. Playfield sound rendering has
six modes:

- `SNDCFG_SND3D2CH` (0): 2 channels to the front of the selected device.
- `SNDCFG_SND3DALLREAR` (1): 2 channels to the rear, to move table audio into the
  cab without a second sound card.
- `SNDCFG_SND3DFRONTISREAR` (2) and `SNDCFG_SND3DFRONTISFRONT` (3): up to 6
  channels, differing in whether the cab front maps to the rear or front surround
  channels.
- `SNDCFG_SND3D6CH` (4): 4 channels on side/rear, leaving front channels free for
  backglass and PinMAME.
- `SNDCFG_SND3DSSF` (5): SSF (Surround Sound Feedback), like 6CH but with enhanced
  horizontal panning and vertical fading for a more physical result.

Backglass and streamed audio always play from the front channels; only playfield
sound is spatialized by this mode. The header comments are the authoritative
explanation of each mapping and are worth reading before touching panning.

*Verified against: `src/audio/AudioPlayer.h` (`SoundConfigTypes` enum + comments).*

## Plugin audio sources mix through Player

The streamed-audio path connects to the plugin bus in `Player`, not in
`AudioPlayer`. At game start `Player` subscribes to the controller audio messages
(`player.cpp` ~775): `CTLPI_AUDIO_ON_UPDATE_MSG`, `CTLPI_AUDIO_ON_SRC_CHG_MSG`,
`CTLPI_AUDIO_GET_SRC_MSG`, with handlers `OnAudioUpdated` / `OnAudioSrcChanged`.

Each plugin audio source becomes an **audio lane** (`Player::AudioLane`, tracked in
`m_audioLanes` keyed by lane id). A lane carries its source, an overridden flag,
a per-lane mixer volume (`GetAudioLaneMixerVolume` / `SetAudioLaneMixerVolume`),
and a map of active `AudioPlayer::AudioStreamID`s. When a plugin broadcasts an
`AudioUpdate`, `Player` routes the samples into the lane's stream on the
`AudioPlayer`; a null buffer destroys the stream. The `overrideId` in the
controller audio source is how one plugin (e.g. AltSound) supersedes another's
audio (e.g. raw PinMAME).

So the ownership is: the controller audio contract lives in the
[plugin system](vpinball-plugin-system.md) (`ControllerPlugin.h`, the
`GetAudioSrc` / `OnAudioSrcChanged` / `AudioUpdate` messages), `Player` is the host
mixer that turns lanes into streams, and `AudioPlayer` is the engine that plays
them. For the user-facing mixer and per-source gain, the third-party config
reference covers it in
[Le-Syl21 `docs/10.8.1/audio_eng.md`](https://github.com/Le-Syl21/vpinball/blob/master/docs/10.8.1/audio_eng.md)
(unofficial fork; verify against code before relying on specifics).

*Verified against: `src/core/player.cpp` (audio message subscribe ~775), `src/core/player.h` (`AudioLane`, `m_audioLanes`, lane mixer volume).*
