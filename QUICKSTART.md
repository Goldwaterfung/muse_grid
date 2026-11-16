# MuseGrid Quick Start Guide

Welcome! This guide walks you through setting up and running **MuseGrid** from a clean **Windows**, **macOS**, or **Linux** machine with **no Flutter SDK, no C++ tools, no Xcode, and no Android Studio** installed yet.

Follow the steps below for your operating system (**Windows**, **macOS**, or **Linux**).

---

## 0. Choose Your Path First (Save Time!)

You do **not** need to install every mobile or desktop SDK just to try MuseGrid. Pick the path that matches what you want to run today:

| Goal | What You Need to Install | Needs Xcode / Android Studio? | Difficulty |
| :--- | :--- | :--- | :--- |
| **Option A: Run in Web Browser (Chrome / Edge)** | Git + Flutter SDK + Chrome/Edge | **No** *(prebuilt WebAssembly audio/DB files are already in `web/`)* | **Easiest (Recommended First)** |
| **Option B: Run as a Desktop App (Windows / macOS / Linux)** | Git + Flutter SDK + CMake + OS C++ compiler | **macOS:** Xcode needed<br>**Windows:** Visual Studio C++ needed<br>**Linux:** `clang` / GTK / ALSA dev packages | Moderate |
| **Option C: Run on Phone/Tablet (Android / iOS)** | Option A/B tools + Android SDK/NDK *(or Xcode on Mac for iOS)* + manual CMake cross-compile | **Yes** | Advanced *(Prototype)* |

> **Recommended Starting Point:** Start with **Option A (Web Browser)** first. It works on Windows, macOS, and Linux, avoids downloading gigabytes of mobile SDKs, and lets you test notation, Piano Roll, SoundFont playback, and microphone recording right away.

---

## 1. Install Git and the Flutter SDK (All Paths)

First, open a terminal:
- **Windows:** Open **PowerShell** (or **Command Prompt**) from the Start Menu.
- **macOS:** Open **Terminal** (press `Cmd + Space`, type `Terminal`, press Enter).
- **Linux:** Open your **Terminal** app.

Check if `git` or `flutter` is already installed:
```bash
git --version
flutter --version
```
If both print version numbers (Flutter `3.50.0` or newer / Dart `3.14.0` or newer), skip ahead to **[Step 2](#2-open-the-project-and-fetch-packages)**. Otherwise, follow your OS instructions below.

### Windows Setup (Git + Flutter)

1. **Install Git:**
   - Download and run the installer from [git-scm.com/download/win](https://git-scm.com/download/win) (default options are fine).
2. **Install Flutter SDK:**
   - Go to [docs.flutter.dev/get-started/install/windows](https://docs.flutter.dev/get-started/install/windows) and download the **Flutter Windows ZIP** (stable channel).
   - Extract the ZIP into a simple folder without spaces or special permissions, such as `C:\dev\flutter` (do **not** put it inside `C:\Program Files` or OneDrive).
3. **Add Flutter to your Windows PATH:**
   - Press the Windows key, type `env`, and open **"Edit environment variables for your account"**.
   - Under **User variables**, select **Path** → **Edit** → **New**, and add:
     ```text
     C:\dev\flutter\bin
     ```
   - Click **OK** on all windows, then **close and reopen** PowerShell.
4. **Verify:**
   ```powershell
   git --version
   flutter --version
   ```

### macOS Setup (Git + Flutter)

1. **Install Git / Command Line Tools:**
   Run this in Terminal (if Git isn't installed yet, macOS will pop up an installer):
   ```bash
   xcode-select --install
   ```
2. **Install Flutter SDK:**
   - Go to [docs.flutter.dev/get-started/install/macos](https://docs.flutter.dev/get-started/install/macos) and download the Flutter macOS ZIP matching your Mac chip:
     - **Apple Silicon** (`M1` / `M2` / `M3` / `M4`) → `arm64`
     - **Intel Mac** → `x64`
   - Move/extract the `flutter` folder to `~/development/flutter` (for example in Terminal):
     ```bash
     mkdir -p ~/development
     unzip ~/Downloads/flutter_macos_*.zip -d ~/development
     ```
3. **Add Flutter to your macOS PATH:**
   Run these commands in Terminal, then **close and reopen** Terminal:
   ```bash
   echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.zshrc
   source ~/.zshrc
   ```
4. **Verify:**
   ```bash
   git --version
   flutter --version
   ```

### Linux Setup (Ubuntu / Debian Example)

1. **Install base tools & Git:**
   ```bash
   sudo apt update
   sudo apt install -y curl git unzip xz-utils zip libglu1-mesa
   ```
2. **Install Flutter SDK:**
   - Download the **Flutter Linux archive** (`.tar.xz`, stable channel) from [docs.flutter.dev/get-started/install/linux](https://docs.flutter.dev/get-started/install/linux).
   - Extract it into `~/development/flutter`:
     ```bash
     mkdir -p ~/development
     tar -xf ~/Downloads/flutter_linux_*.tar.xz -C ~/development
     ```
3. **Add Flutter to your Linux PATH:**
   Add Flutter to `~/.bashrc` (or `~/.zshrc` if you use Zsh):
   ```bash
   echo 'export PATH="$HOME/development/flutter/bin:$PATH"' >> ~/.bashrc
   source ~/.bashrc
   ```
4. **Verify:**
   ```bash
   git --version
   flutter --version
   ```

### About `flutter doctor` Warnings

If you run `flutter doctor`, you may see `[!]` or `[X]` warnings for **Android toolchain**, **Xcode**, or **Visual Studio**.
- If you are only following **Option A (Web Browser)**, you can **safely ignore** Android, Xcode, and Visual Studio warnings as long as **Flutter** and **Chrome** (or **Edge**) show checkmarks (`[✓]`).

---

## 2. Open the Project and Fetch Packages

If you already cloned `muse_grid`, move into the project folder. (If not, clone it first and `cd` into it.)

```bash
cd muse_grid
flutter pub get
```

What `flutter pub get` does:
- Downloads the Dart and Flutter libraries MuseGrid uses (notation engraving, SQLite database, file picker, etc.) as locked in `pubspec.lock`.

---

## 3. Option A: Run in Your Web Browser (Fastest — No Native SDKs Needed)

Because MuseGrid already ships pre-built WebAssembly files in `web/` (`muse_audio_engine.wasm`, `muse_audio_engine.js`, `sqlite3.wasm`, and the AudioWorklet/OPFS worker scripts), **you do not need CMake, a C++ compiler, Emscripten, Xcode, or Android Studio** to run the Web app.

1. Make sure **Google Chrome** (or **Microsoft Edge** on Windows) is installed.
2. From the `muse_grid` folder, run:
   ```bash
   flutter run -d chrome
   ```
   *(On Windows, if you prefer Edge: `flutter run -d edge`.)*
3. Wait for the build to finish and open the browser window.
4. **Turn on sound in the browser:**
   - Modern browsers block audio until you interact with the page.
   - Click the **"Click to Enable Web Audio Engine"** button in the banner at the top of the MuseGrid window.
   - When your browser asks for **Microphone** permission, click **Allow** if you want to test live audio recording.

### Optional: Build a Static Web Folder (`build/web/`)
If you want a production Web build to host on a server:
```bash
flutter build web --wasm
```
> **Web Hosting Note:** MuseGrid works in standard `AudioWorklet` mode over `https://` or `http://localhost`. If you want `SharedArrayBuffer` mode on a hosted web server, configure your web server to send `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`.

---

## 4. Option B: Build & Run as a Native Desktop App

To run MuseGrid as a standalone desktop application (**Windows**, **macOS**, or **Linux**), Flutter compiles MuseGrid's built-in C/C++ audio engine (`FluidSynth` + `miniaudio`) for your computer. This requires **CMake (`>= 3.24`)**, your OS's C/C++ tools, and running MuseGrid's one-time setup script.

### 4.1 Install Desktop Build Tools for Your OS

#### Windows
1. Enable **Developer Mode** in Windows Settings (Flutter requires this for plugin symlinks):
   - Open **Settings → System → For developers** (or press `Win + R` and run `ms-settings:developers`) and turn **Developer Mode** **On**.
2. Install **Visual Studio 2022** (Community Edition is free) or **Visual Studio Build Tools 2022**:
   - During installation, check **"Desktop development with C++"**.
   - This installs the MSVC C++ compiler, Windows SDK, and CMake.
3. Make sure `cmake` is available in your terminal:
   - Either open **"Developer Command Prompt for VS 2022"** / **"x64 Native Tools Command Prompt for VS 2022"**, **or** install standalone CMake (`>= 3.24`) from [cmake.org/download](https://cmake.org/download/) and select **"Add CMake to the system PATH"**.

#### macOS
1. Install **Xcode** from the Mac App Store (required by Flutter for macOS desktop apps).
2. Open Xcode once to accept the license agreement, then run in Terminal:
   ```bash
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   ```
3. Install **CMake (`>= 3.24`)**:
   - Download the macOS `.dmg` from [cmake.org/download](https://cmake.org/download/), drag `CMake.app` into `/Applications`, and add its command-line tools to PATH:
     ```bash
     sudo "/Applications/CMake.app/Contents/bin/cmake-gui" --install
     ```
     *(Or if you already use Homebrew: `brew install cmake`.)*
4. Verify:
   ```bash
   cmake --version
   make --version
   ```

#### Linux (Ubuntu / Debian)
Install Flutter's Linux desktop prerequisites and ALSA audio development headers:
```bash
sudo apt update
sudo apt install -y clang cmake ninja-build pkg-config make libgtk-3-dev liblzma-dev libasound2-dev
```
Verify:
```bash
cmake --version
make --version
```

### 4.2 Run the One-Time Audio Engine Setup Script

From the `muse_grid` folder, run:
```bash
dart tool/setup_audio_engine.dart --skip-wasm
```

What this does automatically:
- Downloads and compiles pinned C/C++ audio libraries (`FluidSynth v2.6.2`, `miniaudio 0.11.26`, `PicoSHA2 v1.0.1`, and `Catch2 v3.16.1`) into `packages/muse_audio_engine/.build/` (plus `.build_macos_arm64/` and `.build_macos_x64/` on macOS).
- Runs offline C++ self-tests (`ctest`) to verify the audio engine compiled cleanly.
- `--skip-wasm` skips downloading Emscripten (`emsdk`), because the pre-compiled WebAssembly files are already included in `web/`. *(Omit `--skip-wasm` only if you want to recompile `web/muse_audio_engine.wasm` from C++ source; that additionally requires `python3`, and on Windows a `make`/`mingw32-make`/`nmake`/`ninja` tool.)*

### 4.3 Launch the Desktop App

- **Windows:**
  ```powershell
  flutter run -d windows
  ```
  *(To create a release build: `flutter build windows`)*
- **macOS:**
  ```bash
  flutter run -d macos
  ```
  *(To create a release build: `flutter build macos`)*
- **Linux:**
  ```bash
  flutter run -d linux
  ```
  *(To create a release build: `flutter build linux`)*

### 4.4 Create macOS and Windows Installers

Build the release app for the target operating system first, then package it:

- **macOS:** After `flutter build macos --release`, create a compressed disk image:
  ```bash
  tool/package_macos_dmg.sh \
    build/macos/Build/Products/Release/muse_grid.app \
    {version_number}
  ```
  This creates `build/installer/muse-grid-macos-{version_number}.dmg`. Users can open the
  image and drag MuseGrid into Applications.
- **Windows:** Install [Inno Setup 6](https://jrsoftware.org/isinfo.php), then
  run in PowerShell after `flutter build windows --release`:
  ```powershell
  .\tool\package_windows_installer.ps1 -AppVersion {version_number}
  ```
  This creates `build\installer\muse-grid-windows-{version_number}-setup.exe`, with
  Start Menu and optional desktop shortcuts and an uninstaller.

Both packaging commands accept the app version explicitly. Versioned Git tags
also make the release workflow attach a DMG and Windows setup executable to the
GitHub release, with generated release notes and a listing of every commit
since the previous tag. The generated packages are not code-signed or notarized.

---

## 5. Option C: Mobile Builds (Android & iOS)

`tool/setup_audio_engine.dart` also supports automating Android NDK (`--android`) and iOS (`--ios`) cross-compilation into the target-specific build directories expected by [`hook/build.dart`](hook/build.dart).

### Android (from Windows, macOS, or Linux)

1. Install **Android Studio** ([developer.android.com/studio](https://developer.android.com/studio)).
2. Open **Android Studio → Settings / SDK Manager → SDK Tools** and install:
   - **Android SDK Platform** (latest stable; `android/app/build.gradle.kts` targets `compileSdk = 37`, `targetSdk = 37`, `minSdk = 30`)
   - **Android SDK Command-line Tools (latest)**
   - **NDK (Side by side)**
   - **CMake** *(required on Windows if Ninja is not already on `PATH`)*
3. Accept Android licenses in your terminal:
   ```bash
   flutter doctor --android-licenses
   ```
4. **Cross-compile the audio engine static archives for Android:**
   Run the automated setup script with `--android` (defaults to API `30` matching `minSdk = 30`, building `arm64-v8a`, `armeabi-v7a`, and `x86_64` into `packages/muse_audio_engine/.build_android_<arch>/`):
   ```bash
   dart tool/setup_audio_engine.dart --skip-wasm --android
   ```
   *(If you already completed Step 4.2, you can add `--skip-native` to skip rebuilding the desktop host engine. You can also pass `--android-abis=arm64-v8a`, `--android-ndk=<path>`, or `--android-api=<level>` to customize the build.)*
5. Connect an Android device (with USB Debugging enabled) or start an emulator, then run:
   ```bash
   flutter run
   ```
   Or build an APK:
   ```bash
   flutter build apk
   ```

### iOS (macOS Only)

1. Requires a **Mac** with **Xcode** installed (see macOS setup in Step 4.1).
2. **Cross-compile the audio engine static archives for iOS:**
   Run the automated setup script with `--ios` to build `iphoneos` (`arm64`) and `iphonesimulator` (`arm64` and `x86_64`) static archives into `packages/muse_audio_engine/.build_ios_<sdk>_<arch>/`:
   ```bash
   dart tool/setup_audio_engine.dart --skip-wasm --ios
   ```
   *(Add `--skip-native` if you already built the host macOS engine in Step 4.2.)*
3. Run on a connected iPhone/iPad or iOS Simulator, or build without codesigning:
   ```bash
   flutter build ios --no-codesign
   flutter build ios --simulator
   ```

---

## 6. Troubleshooting Common Setup Issues

- **`flutter: command not found` / `'flutter' is not recognized`**
  - Your terminal doesn't see Flutter on `PATH` yet. Double-check Step 1's `PATH` instructions and **open a brand-new terminal window** after editing `PATH`.
- **`Missing prebuilt audio engine static archives for ...`**
  - You ran a desktop/native `flutter run`, `flutter build`, or `flutter test` before preparing the C/C++ audio libraries. Run:
    ```bash
    dart tool/setup_audio_engine.dart --skip-wasm
    ```
- **No sound when running in Chrome or Edge**
  - Click the **"Click to Enable Web Audio Engine"** button in the top banner inside MuseGrid. Browsers keep audio muted until you click.
- **Windows symlink / Developer Mode error during `flutter run`**
  - Turn on **Developer Mode** in Windows Settings (`Settings → System → For developers → Developer Mode`).
- **`CMake >= 3.24 is required`**
  - Your system has an older CMake installed. Download CMake 3.24+ from [cmake.org](https://cmake.org/download/) or run inside Visual Studio 2022's Developer Command Prompt.
- **Want to verify your setup passes code checks & tests?**
  *(Requires completing Step 4.2 first so the native audio engine archives exist for host tests.)*
  ```bash
  flutter analyze
  flutter test
  ```
