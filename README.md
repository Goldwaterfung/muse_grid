<div align="center">

# MuseGrid

### Cross-Platform Sheet Music, Dynamic Piano Roll, SoundFont Playback & Live Recording

<p align="center">
  <b>Write traditional 5-line notation, fine-tune expressive timing on a Piano Roll, audition with SoundFonts, and record live audio takes—all on one synchronized musical timeline.</b>
</p>

[![Status: Prototype](https://img.shields.io/badge/Status-Functional%20Prototype-blue)](#overview)
[![Timing: 960 PPQN](https://img.shields.io/badge/Timing-960%20PPQN-green)](#how-notation--piano-roll-stay-in-sync)
[![Formats: MusicXML / MXL / WAV / SF2](https://img.shields.io/badge/Formats-MusicXML%20%7C%20MXL%20%7C%20WAV%20%7C%20SF2-orange)](#what-you-can-do-in-musegrid)
[![Platforms: Web / Desktop / Mobile](https://img.shields.io/badge/Platforms-Web%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20iOS%20%7C%20Android-lightgrey)](QUICKSTART.md)

---

<p align="center">
  <a href="#overview">Overview</a> •
  <a href="#who-musegrid-is-built-for">Who It's For</a> •
  <a href="QUICKSTART.md">Quick Start Guide</a> •
  <a href="#what-you-can-do-in-musegrid">Features</a> •
  <a href="#how-notation--piano-roll-stay-in-sync">Notation + Grid Sync</a> •
  <a href="#soundfonts-recording--export">Audio &amp; Recording</a> •
  <a href="#technical-architecture--developer-resources">Developer Resources</a>
</p>

</div>

---

## Overview

Musicians, music annotators, and tutors are usually forced to split their work across two separate kinds of software:
- **Notation programs** engrave clean 5-line sheet music, but often feel rigid when you want to adjust expressive timing, edit note velocities, or record a live acoustic take next to the score.
- **DAWs** excel at piano-roll editing and microphone recording, but struggle to produce clean, readable 5-line notation and MusicXML files.

**MuseGrid** brings both worlds into one workspace. Every note you enter on the **5-line staff** or draw on the **Piano Roll (Dynamic Grid)** lives on a single shared musical timeline (`960 PPQN`), plays back through a built-in **SoundFont (`.sf2`) synthesizer**, and stays locked to the same clock when you record live audio from your microphone.

> **Current Stage:** MuseGrid is a **functional cross-platform prototype**. Core notation, piano-roll editing, SoundFont playback, live WAV recording, MusicXML/MXL import & export, and local project storage are implemented and ready to build and test locally.

---

## Who MuseGrid Is Built For

| If You Are A... | Common Frustration | How MuseGrid Helps |
| :--- | :--- | :--- |
| **Music Tutor** | Switching between a notation editor for worksheets, a separate player for backing tracks, and another recorder to capture student takes. | Prepare a score, assign instruments from the bundled SoundFont, enable **Count-In** and **Loop**, and record live student or reference takes directly alongside the sheet music. |
| **Music Annotator / Transcriber** | Re-entering notes twice or losing enharmonic spellings, ties, and slurs whenever you inspect expressive performance timing. | Keep one unified score where each note carries both its **Quantized** sheet-music timing and its **Raw** performance timing, while preserving spelling (`♭`/`♮`/`♯`), voices, ties, slurs, and beams. |
| **Composer / Arranger** | Sketching ideas in a DAW piano roll and then manually cleaning up a broken MIDI import in a notation app. | Edit side-by-side in **5-Line Staff** and **Piano Roll** views—transposing, changing clefs/keys/time signatures, and tweaking per-note velocity without leaving the project. |

---

## Quick Start (Clean-Machine Setup)

Never installed Flutter, Xcode, or Android Studio before? Follow the step-by-step **[QUICKSTART.md](QUICKSTART.md)** guide for a clean **Windows**, **macOS**, or **Linux** setup.

- **Fastest way to try MuseGrid:** Run the **Web version in Chrome or Edge** (`flutter run -d chrome`). Because the Web audio engine and database WebAssembly files are already included in `web/`, you do **not** need Xcode, Android SDK/NDK, or C++ compilers.
- **Want a native desktop app or mobile build?** [QUICKSTART.md](QUICKSTART.md) walks through **Windows**, **macOS**, **Linux**, **Android**, and **iOS** setup step by step.

---

## What You Can Do in MuseGrid

<table width="100%">
  <tr>
    <td width="50%" valign="top">
      <h3>🎼 Standard 5-Line Staff Notation</h3>
      <p>Engrave and edit multi-part sheet music rendered with the <b>Bravura (SMuFL)</b> music font. Insert notes at the cursor, select chords, transpose by semitone (<code>±1</code>) or octave (<code>±12</code>), respell enharmonics (<code>♭</code>, <code>♮</code>, <code>♯</code>), attach ties, slurs, and beams, insert clefs/keys/time signatures/tempos, toggle <i>Hide Empty Staves</i>, and inspect measure events.</p>
    </td>
    <td width="50%" valign="top">
      <h3>🎹 Dynamic Grid (Piano Roll)</h3>
      <p>Switch between <b>Select</b>, <b>Draw</b>, <b>Erase</b>, and <b>Pan</b> tools on a smooth zoomed canvas. Drag notes, resize durations, marquee-select groups, shape per-note MIDI velocity in the bottom velocity lane, audition pitches on the 128-key keyboard gutter, and drag loop ranges right on the bar ruler.</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🎛️ Multi-Part Mixer &amp; SoundFonts</h3>
      <p>Add, rename, reorder, and delete instrument parts. Adjust per-part <b>Gain (dB)</b>, <b>Pan</b>, <b>Mute</b>, <b>Solo</b>, and MIDI channel. Play back right away with the bundled <b>GeneralUser GS</b> SoundFont, or import your own <code>.sf2</code> files and choose Bank/Program presets per part.</p>
    </td>
    <td width="50%" valign="top">
      <h3>🎙️ Live Microphone Recording &amp; Calibration</h3>
      <p>Record-arm any part, toggle <b>Count-In</b> and <b>Loop</b>, adjust live input monitoring gain, watch real-time <b>L / R / In</b> peak &amp; RMS meters and the live recording waveform strip, calibrate hardware round-trip latency, and export recorded takes as <code>.wav</code> files.</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>📄 MusicXML &amp; MXL Import / Export</h3>
      <p>Open existing scores from <code>.musicxml</code>, <code>.xml</code>, or compressed <code>.mxl</code> files, or start from a blank score with custom tempo, time signature, and staves—and export your edited score back out as <code>.musicxml</code> or <code>.mxl</code>.</p>
    </td>
    <td width="50%" valign="top">
      <h3>💾 Local Project Library &amp; Storage</h3>
      <p>Manage multiple projects from the Project Catalog (create, rename, open, delete, purge audio takes, and clean up unused cached binary files). Projects persist locally using SQLite and deduplicated binary storage (native disk on desktop/mobile, OPFS in the browser).</p>
    </td>
  </tr>
</table>

---

## How Notation & Piano Roll Stay in Sync

MuseGrid stores musical time at **960 pulses per quarter note (PPQN)** (`3840` ticks per whole note), giving exact integer support for:
- **Straight subdivisions:** `1/1`, `1/2`, `1/4`, `1/8`, `1/16`, `1/32`, `1/64`
- **Dotted subdivisions:** `1/2.`, `1/4.`, `1/8.`, `1/16.`, `1/32.`
- **Triplets:** `1/2T`, `1/4T`, `1/8T`, `1/16T`, `1/32T`

Each note keeps a stable ID linking the Piano Roll and the 5-line staff together, along with two timing representations:
- **Quantized Timing (`Timing: quantized`):** Snaps playback to clean notation subdivisions.
- **Raw Timing (`Timing: raw`):** Plays back unquantized, expressive note timing while keeping your sheet-music notation readable.

---

## SoundFonts, Recording & Export

- **Included SoundFont:** MuseGrid ships with `GeneralUser_GS_MuseScore_v1.442.sf2` (`assets/sf2/`) so playback works immediately after launch. You can also import additional `.sf2` SoundFonts from the **SoundFonts** library dialog.
- **Browser Audio Note:** When running on Web, browsers pause audio until you click inside the page. Click the **"Click to Enable Web Audio Engine"** banner at the top of the window to start playback and microphone access.
- **Export Formats:**
  - **Sheet Music:** `.musicxml` and compressed `.mxl`
  - **Recorded Audio Takes:** Raw `.wav` audio

---

## Technical Architecture & Developer Resources

<details>
<summary><b>For Software Engineers &amp; Contributors (Architecture, Specs &amp; Flutter Resources)</b></summary>
<br>

MuseGrid separates Pure Dart/Flutter notation and UI from a unified C/C++ + WebAssembly audio engine (`FluidSynth` + `miniaudio` / Web `AudioWorklet`) using a strict **5-layer + Middle Bridge** architecture:

- **Composition Root (`lib/app/`):** Platform wiring (`NativeAudioBridge` / `WebAudioWorkletBridge`, SQLite/OPFS storage) and lifecycle management.
- **Layer 5 — Presentation (`lib/presentation/`):** Adaptive workspace shell, `crisp_notation` staff engraving panel, custom Piano Roll `CustomPainter`, and mixer/transport UI.
- **Layer 4 — Musical & Notation Domain (`lib/domain/`):** Pure Dart (`WasmGC`-compatible) `960 PPQN` timeline calculator, undo/redo command bus, `DualModelScoreService`, and MusicXML/MXL mapping via `crisp_notation_core`.
- **Middle Bridge & Storage (`lib/bridge/`, `lib/storage/`):** `dart:ffi` native bridge, `package:web` `AudioWorklet` + `MessagePort` bridge, and SQLite + Content-Addressed Storage (`CAS`).
- **Layers 1–3 — Audio Engine (`packages/muse_audio_engine/`):** Lock-free SPSC queues, `FluidSynth v2.6.2` (SF2-only), `miniaudio 0.11.26` full-duplex HAL + WAV encoder, `PicoSHA2`, and Emscripten WebAssembly build.

### Project Documentation
- [QUICKSTART.md](QUICKSTART.md) — Step-by-step setup & build instructions from a clean machine for Windows, macOS, Linux, Web, Android, and iOS
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 5-layer architecture, threading, and data flow
- [docs/requirements.md](docs/requirements.md) — Technology stack rationale and scope
- [docs/database.md](docs/database.md) — SQLite schema and Content-Addressed Storage (`CAS`)
- [docs/interfaces_classes.md](docs/interfaces_classes.md) — Cross-layer contracts and C ABI
- [docs/toolchain_and_dependencies.md](docs/toolchain_and_dependencies.md) — Pinned SDKs, toolchains, and dependency rules

### Verification Commands (after native setup)
```bash
flutter analyze
flutter test
flutter build web --wasm
```

### Original Flutter Getting Started Resources
This project was scaffolded with Flutter. Useful references if you are new to Flutter:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

</details>
