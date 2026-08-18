# Winder

A macOS file manager with a built‑in terminal and side‑by‑side folder panes.

내장 터미널과 좌우 2분할 창을 갖춘 macOS 파일 관리자입니다.

> **Requires macOS 26 or later.** / **macOS 26 이상 필요.**

---

## English

### Why Winder instead of Finder?

Winder covers the everyday Finder workflow, but adds three things Finder does not have —
and deliberately differs from Finder in one behaviour you should know about up front.

#### 1. A real terminal inside the window

Press the terminal button and the file list splits horizontally to reveal a **real shell on a
PTY** — not a command box. It starts in the folder you are looking at, and when you navigate
elsewhere it `cd`s along with you (it stays out of the way while a command is running).

Finder has no terminal at all. The usual workaround is to keep Terminal.app in another window
and re‑type paths; here the shell is already in the right folder.

#### 2. Two folders side by side in one window

The rightmost toolbar button splits the window into **two independent file panes**. Each pane
has its own folder, its own view mode, its own history, and its own terminal. Drag files
straight from one pane to the other.

Finder gives you tabs — you can only see one folder at a time per window. For copying between
two folders you end up arranging two windows by hand.

#### 3. The sidebar is a real, expandable tree

Every folder in the sidebar has a disclosure triangle. You can drill from `홈` down through
`Project → winder → Views` without leaving the sidebar, and volumes and discovered network
servers sit in the same tree.

Finder's sidebar is a flat list of favourites and locations; folders in it cannot be expanded.

#### ⚠️ One deliberate difference: drag copies by default

| | Winder | Finder |
|---|---|---|
| Drag a file to another folder | **Copy** | Move (same volume) |
| Hold ⌘ while dragging | **Move** | — |
| Hold ⌥ while dragging | — | Copy |

This is the one place Winder will surprise a Finder user. The safer default was chosen on
purpose: an accidental drag duplicates a file instead of relocating it.

### What Finder has that Winder does not

Being upfront so you are not hunting for them:

- Column view (Winder has icon / list / detail / gallery)
- Tabs (use ⌘N for a new window, or split the window)
- Tags, smart folders, Quick Look on the space bar
- Search
- iCloud/Trash management beyond opening the folder

### Features

- **View modes** — icon, list, detail (columns), gallery (large preview + filmstrip)
- **Per‑folder view memory** — each folder reopens in the mode you last used
- **File operations** — copy, cut, paste, rename, move to trash, permanent delete, undo
- **Favourites** — drag folders into the sidebar, reorder them by dragging
- **Network** — SMB servers discovered on the local network appear in the sidebar
- **Full Disk Access guidance** — a dedicated screen when a folder needs the permission

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘[ / ⌘] | Back / Forward |
| ⌘↑ | Enclosing folder |
| ⌘R | Refresh |
| ⌘C / ⌘X / ⌘V | Copy / Cut / Paste |
| ⌘Z | Undo last file operation |
| ⌘A | Select all |
| Return / Double‑click | Open |
| F2 | Rename |
| Delete | Move to trash |
| ⇧Delete | Delete permanently |
| ⌘N / ⌘W | New window / Close window |

### Build

Requires Xcode with the macOS 26.5 SDK. (Built against 26.5, deployed to 26.0 —
the app uses no API newer than macOS 26.0.)

```bash
xcodebuild -project winder.xcodeproj -scheme winder -configuration Debug build
```

### Packaging a zip to share

```bash
./scripts/release.sh
```

Produces `dist/winder-<version>.zip`. The script builds Release, checks the result and packages
it, stopping if anything is wrong:

1. Builds with `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`. These must be passed on the command
   line — without them the build comes out Apple‑Silicon‑only despite the project settings, and
   will not launch on an Intel Mac.
2. Fails the build if `lipo` does not report both architectures, and verifies the code signature.
3. Packages with `ditto -c -k --sequesterRsrc --keepParent`, not `zip -r`: `--keepParent` keeps
   the `.app` bundle intact, and once the app contains frameworks `zip -r` flattens their
   symlinks and breaks the signature. (Finder's right‑click → *Compress* is also fine.)

The version in the filename comes from `CFBundleShortVersionString`, so bump **Version** in
Xcode's General tab and the name follows.

### Handing it to someone else

| Delivery | What they see |
|---|---|
| **USB drive** | No quarantine flag is set — the app just opens |
| Mail, chat, AirDrop, download link | Gatekeeper blocks it on first launch |

If it is blocked, tell them: double‑click the app once, then open **System Settings › Privacy &
Security**, scroll to the bottom and press **Open Anyway**. Only needed once. (Since macOS 15
the old right‑click → *Open* bypass no longer works.)

On first launch macOS will ask for local network access, Photos library access, and file access
per folder. Some system folders additionally need Winder enabled under **Privacy & Security ›
Full Disk Access**.

---

## 한국어

### Finder 대신 Winder를 쓰는 이유

Finder로 하던 일은 그대로 하면서, Finder에 **없는 세 가지**를 더합니다.
그리고 Finder와 **일부러 다르게 만든 동작**이 하나 있으니 먼저 알아두세요.

#### 1. 창 안에 진짜 터미널

터미널 버튼을 누르면 파일 목록 아래가 갈라지며 **PTY 위에서 도는 실제 셸**이 열립니다.
명령 입력칸이 아니라 진짜 셸입니다. 지금 보고 있는 폴더에서 시작하고, 폴더를 옮기면
`cd`로 따라옵니다(명령이 돌고 있는 중에는 끼어들지 않습니다).

Finder에는 터미널이 아예 없습니다. 보통은 터미널 앱을 따로 띄워 두고 경로를 다시
입력하게 되는데, 여기서는 셸이 이미 그 폴더에 있습니다.

#### 2. 한 창에서 두 폴더를 나란히

도구 막대 맨 오른쪽 버튼을 누르면 창이 **독립된 파일 목록 창 두 개**로 나뉩니다.
각 창이 자기 폴더·보기 모드·이동 기록·터미널을 따로 갖습니다. 한쪽에서 다른 쪽으로
파일을 바로 끌어다 놓을 수 있습니다.

Finder는 탭만 제공해서 한 창에 한 폴더만 보입니다. 두 폴더 사이에서 복사하려면
창 두 개를 직접 배치해야 합니다.

#### 3. 사이드바가 펼쳐지는 실제 트리

사이드바의 모든 폴더에 펼침 삼각형이 있습니다. `홈 → Project → winder → Views`처럼
사이드바를 벗어나지 않고 깊이 들어갈 수 있고, 볼륨과 발견된 네트워크 서버도 같은
트리 안에 있습니다.

Finder 사이드바는 즐겨찾기와 위치를 나열한 평평한 목록이라 폴더를 펼칠 수 없습니다.

#### ⚠️ 일부러 다르게 만든 것: 그냥 끌면 복사

| | Winder | Finder |
|---|---|---|
| 다른 폴더로 끌기 | **복사** | 이동 (같은 볼륨) |
| ⌘ 누른 채 끌기 | **이동** | — |
| ⌥ 누른 채 끌기 | — | 복사 |

Finder를 쓰던 분이 유일하게 놀랄 지점입니다. 실수로 끌었을 때 파일이 옮겨지는 대신
복제되도록, 더 안전한 쪽을 기본으로 골랐습니다.

### Finder에는 있고 Winder에는 없는 것

찾다가 헤매지 않도록 미리 밝힙니다:

- 열 보기 (Winder는 아이콘 / 목록 / 자세히 / 갤러리)
- 탭 (⌘N으로 새 창을 열거나 창을 나누세요)
- 태그, 스마트 폴더, 스페이스바 빠른 보기
- 검색
- 폴더를 여는 것 이상의 iCloud·휴지통 관리

### 기능

- **보기 모드** — 아이콘, 목록, 자세히(열), 갤러리(큰 미리보기 + 필름스트립)
- **폴더별 보기 기억** — 폴더마다 마지막에 쓴 모드로 열립니다
- **파일 작업** — 복사, 잘라내기, 붙여넣기, 이름 바꾸기, 휴지통, 영구 삭제, 실행 취소
- **즐겨찾기** — 폴더를 사이드바로 끌어 추가하고, 끌어서 순서를 바꿉니다
- **네트워크** — 같은 네트워크에서 찾은 SMB 서버가 사이드바에 나타납니다
- **전체 디스크 접근 안내** — 권한이 필요한 폴더에서 전용 안내 화면을 보여줍니다

### 단축키

| 단축키 | 동작 |
|---|---|
| ⌘[ / ⌘] | 뒤로 / 앞으로 |
| ⌘↑ | 상위 폴더 |
| ⌘R | 새로 고침 |
| ⌘C / ⌘X / ⌘V | 복사 / 잘라내기 / 붙여넣기 |
| ⌘Z | 마지막 파일 작업 실행 취소 |
| ⌘A | 전체 선택 |
| Return / 더블클릭 | 열기 |
| F2 | 이름 바꾸기 |
| Delete | 휴지통으로 |
| ⇧Delete | 영구 삭제 |
| ⌘N / ⌘W | 새 창 / 창 닫기 |

### 빌드

macOS 26.5 SDK가 있는 Xcode가 필요합니다. (26.5 SDK로 빌드하고 배포 대상은 26.0입니다 —
macOS 26.0보다 새로운 API는 쓰지 않습니다.)

```bash
xcodebuild -project winder.xcodeproj -scheme winder -configuration Debug build
```

### 공유용 zip 만들기

```bash
./scripts/release.sh
```

`dist/winder-<버전>.zip`이 만들어집니다. Release 빌드 → 검증 → 압축을 한 번에 하고,
잘못된 게 있으면 거기서 멈춥니다:

1. `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`로 빌드합니다. 이 값을 명령줄에 꼭 넘겨야
   합니다 — 프로젝트 설정에 같은 값이 있어도 빼면 **arm64만** 나와서 인텔 맥에서
   켜지지 않습니다.
2. `lipo`가 두 아키텍처를 보고하지 않으면 중단하고, 서명도 확인합니다.
3. `zip -r`이 아니라 `ditto -c -k --sequesterRsrc --keepParent`로 압축합니다.
   `--keepParent`가 `.app` 묶음을 유지하고, 나중에 프레임워크가 들어가면 `zip -r`은
   심볼릭 링크를 풀어버려 서명이 깨집니다. (Finder에서 우클릭 → **압축하기**도 괜찮습니다.)

파일 이름의 버전은 `CFBundleShortVersionString`에서 읽으므로, Xcode General 탭의
**Version**만 올리면 이름도 따라갑니다.

### 다른 사람에게 건네기

| 전달 방법 | 받는 사람이 겪는 것 |
|---|---|
| **USB 메모리** | 격리 표시가 안 붙어 **바로 실행됩니다** |
| 메일·메신저·AirDrop·다운로드 링크 | 처음 열 때 Gatekeeper가 막습니다 |

막혔다면 이렇게 안내하세요. 앱을 한 번 더블클릭한 뒤 **시스템 설정 › 개인정보 보호 및 보안**을
열고 맨 아래로 내려 **"그래도 열기"**를 누릅니다. 처음 한 번만 하면 됩니다.
(macOS 15부터 예전의 우클릭 → *열기* 우회는 막혔습니다.)

처음 실행하면 로컬 네트워크, 사진 보관함, 폴더별 파일 접근 권한을 차례로 묻습니다.
일부 시스템 폴더는 **개인정보 보호 및 보안 › 전체 디스크 접근 권한**에서 Winder를 직접
켜야 합니다.
