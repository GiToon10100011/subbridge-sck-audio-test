# sckaudio

macOS에서 재생 중인 소리만 캡처해 WAV 또는 M4A로 저장하는 Swift CLI. ScreenCaptureKit을 쓰고, 영상은 저장하지 않는다.

"브라우저나 OTT 재생 환경에서 시스템 오디오가 실제로 잡히는가"를 확인하려고 만든 **기술 검증용** 최소 구현이다.
DRM을 우회하는 기능은 없다. 막히면 막힌 대로 관찰해서 보여준다.

## 목차

- [개요](#개요)
- [프로젝트 상태](#프로젝트-상태)
- [기술 스택](#기술-스택)
- [요구 사항](#요구-사항)
- [시작하기](#시작하기)
- [사용법](#사용법)
- [동작 원리](#동작-원리)
- [권한](#권한)
- [테스트](#테스트)
- [문제 해결](#문제-해결)
- [알려진 한계](#알려진-한계)
- [책임 있는 사용](#책임-있는-사용)

## 개요

### 주요 기능

- **시스템 전체 또는 앱 단위 캡처** — `--app` 으로 특정 앱의 소리만 고를 수 있다.
- **오디오만 저장** — 화면 영상은 받는 즉시 버리고 어디에도 쓰지 않는다.
- **WAV(16-bit PCM) / M4A(AAC) 저장**
- **실시간 상태 표시** — 경과 시간, 캡처된 오디오 시간, 피크/RMS(dBFS), 입력 상태(`WAITING` / `ACTIVE` / `SILENT` / `STALLED`)를 0.5초마다 표시한다.
- **종료 요약** — 상태별 누적 시간, 받은 버퍼 수, 최대 피크, 저장된 파일 크기.
- **권한 점검** — 화면 녹화 권한 상태와 권한을 줄 터미널 앱을 알려준다.
- **권한 없이 돌리는 자가 검증** — 합성 신호로 계측과 파일 쓰기 경로를 확인한다 (`selftest`).

### 명령 한눈에 보기

| 명령 | 하는 일 |
|---|---|
| `sckaudio check [--request]` | 화면 녹화 권한 상태 확인. `--request` 는 권한 요청 창을 띄운다 |
| `sckaudio list` | 실행 중인 앱 목록 (`--app` 에 쓸 이름 · bundle id · pid) |
| `sckaudio record [옵션]` | 오디오 캡처 → 파일 저장. Ctrl-C 로 종료 |
| `sckaudio selftest` | 권한 없이 계측기 · WAV/M4A 쓰기 경로를 합성 신호로 검증 |

## 프로젝트 상태

**구조는 검증됐고, "실제 소리가 파일에 담기는가"는 아직 확인하지 못했다.**

| 항목 | 상태 | 근거 |
|---|---|---|
| 빌드 (debug · release) | ✅ | 2026-11-03 `swift build -c release` 성공 |
| `selftest` | ✅ 16/16 | WAV · M4A 각 8항목 (2026-11-03 재실행) |
| 권한 | ✅ 허용됨 (cmux) | `sckaudio check` (2026-11-03) |
| 캡처 시작, 버퍼 수신, 포맷 | ✅ | 초당 약 50개 버퍼, `48000Hz 2ch Float32 non-interleaved` (2026-11-02) |
| WAV · M4A 파일 생성 | ✅ | `afinfo` 로 길이 확인 (4.06초 / 3.02초) |
| `-3801` 권한 거부 안내 | ✅ | 실제 시스템 응답으로 확인 |
| **실제 소리가 담기는지** | ❓ 미확정 | 실측은 시스템 출력이 **음소거(볼륨 0)** 인 상태였고 전 구간 `SILENT` |
| 앱 단위 필터 (`--app`) | ❓ 미실행 | |
| 브라우저 소리 | ❓ 미실행 | |
| OTT 재생 중 오디오 | ❓ 미실행 | |

전 구간 `SILENT` 가 음소거 때문인지는 대조 실험(음소거를 풀고 재생)으로 가려야 한다.
그 전에는 "소리가 정상으로 잡힌다"고 말할 수 없다. 절차는 [테스트](#테스트)에 있다.

## 기술 스택

| 구분 | 내용 |
|---|---|
| 언어 | Swift (`swift-tools-version:5.9`, Swift 5 언어 모드) |
| 빌드 | Swift Package Manager, 실행 타깃 `sckaudio` |
| 캡처 | ScreenCaptureKit (`SCStream`, `SCContentFilter`, `SCShareableContent`) |
| 변환 · 저장 | AVFoundation (`AVAudioPCMBuffer`, `AVAudioFile`), CoreMedia |
| 권한 확인 | CoreGraphics (`CGPreflightScreenCaptureAccess`, `CGRequestScreenCaptureAccess`) |
| 동시성 | Dispatch 큐 · 신호 소스, `AsyncStream` |
| 외부 의존성 | 없음 |

## 요구 사항

- macOS 13.0 이상 (`Package.swift` 의 최소 배포 대상. `SCStreamConfiguration.capturesAudio` 가 13.0부터다)
- Xcode (또는 Swift 5.9 이상 툴체인과 macOS SDK)
- 화면 녹화 권한 — [권한](#권한) 참고

개발과 검증은 **macOS 26.6.2 · Swift 6.4.2 · Xcode SDK 27.2** 에서 했다. macOS 13~15에서는 돌려 보지 않았다.

## 시작하기

### 1. 빌드

```bash
cd ~/sck-audio-probe
swift build -c release
```

산출물은 `.build/release/sckaudio` 이다. 이후 예시는 아래 변수를 쓴다.

```bash
BIN=.build/release/sckaudio
```

### 2. 권한 없이 동작 확인

```bash
$BIN selftest
```

마지막 줄이 `selftest 통과` 이면 계측과 파일 쓰기 경로는 정상이다. 권한이 필요 없다.

### 3. 권한 확인

```bash
$BIN check
```

```
macOS 26.6.2
실행 호스트(권한을 줄 앱으로 추정): com.cmuxterm.app
화면 녹화 권한: 허용됨
```

`없음` 이면 [권한](#권한)의 설정 순서를 따른다.

### 4. 첫 캡처

소리가 나는 상태에서 10초간 시스템 전체를 캡처한다.

```bash
$BIN record -d 10
```

현재 디렉터리에 `capture-<yyyyMMdd-HHmmss>.wav` 가 생긴다.

## 사용법

### record 옵션

| 옵션 | 설명 | 기본값 |
|---|---|---|
| `--app <이름\|bundle id\|pid>` | 이 앱의 오디오만 캡처. 여러 번 지정 가능 | 시스템 전체 |
| `--out`, `-o <경로>` | 출력 파일. 확장자는 `.wav` 또는 `.m4a` | `./capture-<시각>.wav` |
| `--format wav\|m4a` | 파일 형식. `-o` 확장자와 다르면 오류 | `wav` |
| `--duration`, `-d <초>` | 지정 시간 뒤 자동 종료 | Ctrl-C 로 종료 |
| `--rate <Hz>` | 샘플레이트 | `48000` |
| `--channels 1\|2` | 채널 수 | `2` |
| `--include-self` | 이 프로세스의 오디오도 포함 | 제외 |

- `--app` 은 **pid 숫자 일치**, **bundle id 정확히 일치**, **앱 이름 부분 일치**(대소문자 무시)로 찾고, 일치하는 프로세스를 모두 포함한다.
  브라우저처럼 이름이 비슷한 헬퍼가 여럿이면 여러 개가 잡힐 수 있으니 시작 줄의 `대상:` 을 확인한다.
- 같은 이름의 출력 파일이 있으면 덮어쓰지 않고 중단한다.
- WAV 는 16-bit PCM, M4A 는 AAC (채널당 64 kbps) 이다.

### 예시

```bash
$BIN list                                        # 앱 이름 · bundle id · pid 확인
$BIN record                                      # 시스템 전체, Ctrl-C 로 종료
$BIN record -d 30 -o ~/Desktop/test.m4a          # 30초, M4A
$BIN record --app Safari --format wav            # Safari 소리만
$BIN record --app com.google.Chrome -d 20        # bundle id 로 지정
$BIN record --app 12345 -d 20                    # pid 로 지정
$BIN record -d 20 --channels 1 --rate 16000      # 모노 16kHz (지원 여부는 아래 참고)
```

### 상태 표시

실행 중 0.5초마다 한 줄이 갱신된다 (stderr).

```
[경과 00:12.5 | 오디오 00:12.4] ACTIVE   peak -12.3 dBFS  rms -24.1 dBFS  max -3.1 dBFS  | 버퍼 1203  48000Hz 2ch Float32 non-interleaved
```

| 필드 | 뜻 |
|---|---|
| 경과 | 캡처 시작 후 실제 시간 |
| 오디오 | 받은 프레임 수 ÷ 샘플레이트. 경과와 크게 벌어지면 버퍼가 빠지고 있다 |
| peak · rms | 직전 0.5초 구간의 레벨 (dBFS) |
| max | 시작 이후 최대 피크 |
| 버퍼 | 지금까지 받은 오디오 버퍼 수 |

| 상태 | 뜻 |
|---|---|
| `WAITING` | 오디오 버퍼가 아직 한 번도 안 왔다 |
| `ACTIVE` | 소리가 들어오는 중 |
| `SILENT` | 버퍼는 오지만 구간 피크가 -70 dBFS 미만이다 |
| `STALLED` | 버퍼가 1.5초 넘게 끊겼다 |

stderr 가 터미널이 아니면(파이프, 리다이렉트) 한 줄씩 1초 간격으로 출력한다.

### 종료 요약과 종료 코드

종료하면 stdout 에 요약이 나온다. 아래 값은 형식을 보여주는 예시이고 실측값이 아니다.

```
── 요약 ──
상태별 시간(초): ACTIVE 10.0 / SILENT 0.0 / STALLED 0.0 / WAITING 0.0
받은 버퍼 500개, 프레임 480000 (10.00초 분량), 포맷 48000Hz 2ch Float32 non-interleaved
최대 피크 -3.1 dBFS
파일: /path/to/capture.wav (1920044 bytes)
```

| 종료 코드 | 의미 |
|---|---|
| `0` | 정상 종료. 전 구간 무음이어도 파일이 만들어졌으면 0이고, 요약에 경고가 붙는다 |
| `1` | 오류 (권한 거부, 대상 앱 없음, 기존 파일 존재 등). `check` 는 권한이 없을 때, `selftest` 는 실패할 때도 1 |
| `2` | `record` 중 오디오 버퍼가 한 번도 도착하지 않음 (파일 없음) |
| `64` | 명령이나 옵션 형식 오류 (사용법을 함께 출력) |

## 동작 원리

### 디렉터리 구조

```
sck-audio-probe/
├── Package.swift                    SwiftPM 정의 (macOS 13+, 실행 타깃 sckaudio)
├── README.md
└── Sources/sckaudio/
    ├── main.swift                   진입점. CLI.run 호출 후 종료 코드로 exit
    ├── CLI.swift                    인자 파싱, check · list · record, 상태 표시와 요약(StatusReporter)
    ├── AudioCapture.swift           SCStream 래퍼. 샘플 버퍼 → AVAudioPCMBuffer 변환
    ├── AudioFileWriter.swift        AVAudioFile 로 WAV/M4A 쓰기
    ├── LevelMeter.swift             버퍼 수 · 프레임 수 · 피크 · RMS 계측
    └── SelfTest.swift               합성 사인파로 계측 · 파일 쓰기 경로 검증
```

### 데이터 흐름

```
SCShareableContent ──▶ SCDisplay (+ --app 으로 고른 SCRunningApplication)
        │
        ▼
SCContentFilter ──▶ SCStream ── 오디오: 48kHz Float32 / 영상: 2×2 픽셀, 1fps
                       │
                       ├─ .audio ─▶ [sckaudio.audio 큐] CMSampleBuffer ─▶ AVAudioPCMBuffer
                       │                                      ├─▶ LevelMeter.record   (계측)
                       │                                      └─▶ AudioFileWriter.write ─▶ .wav / .m4a
                       └─ .screen ─▶ [sckaudio.video-discard 큐] ─▶ 버림

[sckaudio.control 큐]
   0.5초 타이머 ─▶ StatusReporter.tick ─▶ LevelMeter.snapshot ─▶ stderr 상태 줄
   SIGINT · SIGTERM · --duration 타이머 · didStopWithError ─▶ AsyncStream<StopReason>
        └─▶ 종료 절차: stopCapture → 오디오 큐 비우기 → 파일 닫기 → 요약 출력
```

### 설계 결정

**디스플레이 필터를 쓰고 영상은 버린다.** SDK 헤더에 오디오 전용 스트림이 없다. `SCStream` 은 디스플레이나 윈도우 필터가 필요하므로,
영상은 2×2 픽셀 · 1fps 로 줄이고 `.screen` 출력은 받는 즉시 버린다. `.screen` 출력을 아예 붙이지 않으면 시스템이 프레임 전달 실패 로그를
남길 수 있어서 받아서 버리는 방식을 택했다 (붙이지 않았을 때의 대조 실험은 하지 않았다).

**앱 단위 선택은 `including` 필터다.** `--app` 을 주면 `SCContentFilter(display:including:exceptingWindows:)`, 생략하면
`SCContentFilter(display:excludingApplications: [], exceptingWindows: [])` 를 쓴다.

**오디오 포맷을 가정하지 않는다.** 샘플 버퍼의 `AudioStreamBasicDescription` 에서 포맷을 읽어 `AVAudioPCMBuffer` 로 복사한다.
첫 버퍼가 도착한 뒤에 그 포맷으로 `AVAudioFile` 을 연다(늦은 생성). 그래서 버퍼가 하나도 안 오면 파일도 만들어지지 않고 종료 코드 `2` 가 된다.

**`SCRecordingOutput` 은 쓰지 않는다.** macOS 15의 `SCRecordingOutput` 은 영상을 포함한 녹화용이라 오디오만 저장하는 목적과 맞지 않는다.

**스레드 규칙.**

| 큐 | 하는 일 | 접근하는 상태 |
|---|---|---|
| `sckaudio.audio` (직렬) | 샘플 버퍼 변환, 계측, 파일 쓰기 | `AudioFileWriter` 는 이 큐에서만 쓴다 |
| `sckaudio.video-discard` | 영상 프레임 폐기 | 없음 |
| `sckaudio.control` | 상태 타이머, 신호 · 시간 제한 이벤트 | `LevelMeter` 는 `NSLock` 으로 보호 |

종료 때는 `stopCapture()` 후 `audioQueue.sync {}` 로 큐에 남은 버퍼를 다 쓰고 나서 파일을 닫는다.

### SDK 헤더로 확인한 사실 (Xcode SDK 27.2)

| 사실 | 근거 |
|---|---|
| 오디오 캡처는 `SCStreamConfiguration.capturesAudio` (macOS 13.0+) | `SCStream.h` |
| 샘플레이트 · 채널 · 자기 소리 제외 설정: `sampleRate`, `channelCount`, `excludesCurrentProcessAudio` | `SCStream.h` |
| 오디오 전용 스트림은 없다. 디스플레이 또는 윈도우 필터가 필요하다 | `SCContentFilter` 이니셜라이저 목록 |
| 앱 단위 필터: `init(display:including:exceptingWindows:)` | `SCStream.h` |
| 출력 종류: `.screen`, `.audio`(13.0+), `.microphone`(15.0+) | `SCStream.h` |
| 권한 거부는 `SCStreamError.userDeclined` (-3801) | `SCError.h` |
| 권한 확인 · 요청: `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` | `CGWindow.h` |
| `AVAudioFile.close()` 는 macOS 15부터 (그 미만은 참조 해제로 마무리) | `AVAudioFile.h` |

## 권한

### 필요한 권한

- **화면 녹화 (TCC "Screen Recording")** — 오디오만 쓰더라도 ScreenCaptureKit 스트림이라 필요하다.
  시스템 설정의 항목 이름은 OS 버전에 따라 "화면 및 시스템 오디오 녹음" 등으로 보인다.
- 마이크 권한은 필요 없다 (마이크 캡처를 쓰지 않는다).
- Info.plist 와 엔타이틀먼트는 필요 없다 (번들 없는 CLI).

### 누구에게 권한을 주나

CLI 자신이 아니라 **실행한 터미널 앱**이 대상이다. `sckaudio check` 가 `__CFBundleIdentifier`(없으면 `TERM_PROGRAM`) 환경 변수로
"권한을 줄 앱"을 **추정**해서 보여준다. 이 Mac 에서는 `com.cmuxterm.app` 이었다.

### 설정 순서

1. `sckaudio check --request` 로 요청 창을 띄우거나, 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음 에서 위 터미널 앱을 켠다.
2. `sckaudio check` 를 다시 실행한다. `허용됨` 이면 준비 끝.
3. 계속 `없음` 이거나 `-3801` 이 나오면 터미널 앱을 완전히 종료(Cmd-Q)했다가 다시 실행한다.

이 Mac 에서는 권한을 켠 뒤 **터미널 앱을 재시작하지 않았는데도** 실행 중이던 세션에서 `허용됨` 으로 바뀌었다 (2026-11-02 관찰).
재시작이 항상 필요한 것은 아니지만, 반영되지 않으면 재시작이 일반적인 해결책이다.

macOS 15 이후 화면 녹화 권한을 주기적으로 다시 확인받는 동작이 알려져 있다 (이 프로젝트에서 재현하거나 검증하지는 않았다).
갑자기 `-3801` 이 나오면 설정에서 다시 켠다.

## 테스트

### 자동: `selftest`

```bash
$BIN selftest
```

합성 사인파(440 Hz, 진폭 0.5, 2초, 48 kHz 스테레오 Float32 non-interleaved)를 실제 코드 경로에 통과시키고 WAV · M4A 각각 8항목을 검사한다.

| 검사 | 기준 |
|---|---|
| 계측 버퍼 수 · 프레임 수 | 보낸 값과 일치 |
| 계측 최대 피크 | 0.5 (-6.0 dBFS) ± 0.01 |
| 구간 피크 초기화 | `snapshot(resetWindow:)` 뒤 0 |
| 파일 샘플레이트 · 채널 수 | 48000 · 2 |
| 파일 길이 | WAV 는 정확히 일치, M4A 는 AAC 프라이밍 때문에 ±4096 프레임 허용 |
| 읽어 온 피크 | WAV ±0.01, M4A ±0.1 |

**`selftest` 가 검증하지 못하는 것:** `SCStream` 자체(권한, 앱 필터, 실제 소리). 그것은 아래 수동 절차로 확인한다.

### 수동: 환경별 캡처 확인

**0. 기준 확인 (먼저)**
시스템 출력의 음소거를 풀고 볼륨을 올린다. 소리가 확실히 나는 로컬 파일(음악 앱 등)을 틀고 `record -d 10` 을 실행한다.
`ACTIVE` 로 나오고, 저장된 파일을 재생했을 때 들려야 한다. **이 기준이 통과해야 아래 비교가 의미가 있다.**

**1. 일반 브라우저 오디오**
1. 브라우저에서 DRM 없는 영상을 재생한다.
2. 시스템 전체: `record -d 15`
3. 앱 단위: `list` 에서 브라우저를 찾아 `record --app <이름> -d 15`
4. 시스템 전체는 `ACTIVE` 인데 앱 단위는 `SILENT`/`WAITING` 이면 소리를 내는 프로세스가 `--app` 대상과 다른 것이다. `list` 의 다른 항목(헬퍼 등)을 시도한다.

**2. OTT**
1. 같은 절차를 OTT 재생 중에 반복한다 (브라우저와 전용 앱을 따로).
2. 결과를 `ACTIVE` / `SILENT` / `WAITING` 중 무엇인지, 요약의 "최대 피크"와 함께 기록한다.
3. 소리가 들리는데 `SILENT` 이면 캡처는 되지만 오디오가 비어 있는 것이다. `WAITING` 이면 버퍼 자체가 안 오는 것이다. 이 도구는 어느 쪽도 우회하지 않는다.

**기록용 표**

| 환경 | 시스템 전체 | 앱 단위 | 최대 피크 | 메모 |
|---|---|---|---|---|
| 로컬 음악 (기준) | | | | |
| 브라우저 (DRM 없음) | | | | |
| 브라우저 (OTT) | | | | |
| OTT 전용 앱 | | | | |

이 표를 채우면 이 방식의 쓸모가 판가름난다.

## 문제 해결

### `화면 녹화 권한이 거부되었습니다 (SCStreamError -3801)`

권한이 없는 상태다. [권한](#권한)의 설정 순서를 따른다. `sckaudio check` 가 알려주는 호스트 앱이 설정에 켜져 있는지 확인한다.

### 계속 `SILENT` 이다

버퍼는 오지만 소리가 없다는 뜻이다. 순서대로 확인한다.

1. **시스템 출력이 음소거이거나 볼륨 0 인가?** 이 Mac 에서 음소거(`output muted:true`) 상태로 4초 캡처했을 때 전 구간 `SILENT` 였다. 원인이 음소거인지는 아직 대조 실험으로 확정하지 못했다.
2. 대상이 실제로 소리를 내고 있는가?
3. `--app` 을 썼다면 그 앱이 소리를 내는 프로세스가 맞는가? 시스템 전체로 같은 소리를 잡아 비교한다.
4. DRM 보호 재생인가? 서비스가 오디오를 막고 있을 수 있다.

### `WAITING` 이 계속되거나 종료 코드가 2다

오디오 버퍼가 한 번도 안 왔다. 권한을 확인하고(`check`), `--app` 대상이 목록에 있는지(`list`) 본다. 이 경우 파일은 만들어지지 않는다.

### `STALLED`

버퍼가 1.5초 넘게 끊겼다. 대상 앱이 종료됐거나 시스템이 스트림을 멈췄을 수 있다. 시스템이 멈췄다면 `스트림이 시스템에 의해 중지됨: ...` 메시지가 함께 나온다.

### `'X' 와 일치하는 앱이 없습니다`

앱을 먼저 실행한 뒤 `sckaudio list` 로 이름 · bundle id · pid 를 확인해 그대로 쓴다.

### `이미 존재하는 파일입니다`

같은 이름의 파일을 덮어쓰지 않는다. `-o` 로 다른 경로를 주거나 기존 파일을 지운다.

### `--format wav 와 출력 파일 확장자가 다릅니다`

`--format` 과 `-o` 의 확장자를 맞춘다. 확장자는 `.wav` 또는 `.m4a` 만 허용한다.

### `--rate` 가 거부된다

헤더에는 기본값 48000만 적혀 있어 지원 값 범위를 확인하지 못했다. 거부되면 48000으로 되돌린다.

### 빌드 실패

```bash
xcode-select -p                  # Xcode 경로 확인
swift --version                  # 5.9 이상인지 확인
swift package clean && swift build -c release
```

## 알려진 한계

- 디스플레이가 하나는 있어야 한다 (첫 번째 디스플레이를 쓴다).
- 채널은 1~2개만 지원한다.
- 앱 단위 필터는 그 앱이 낸 소리만 잡는다. 브라우저는 소리를 헬퍼 프로세스가 내는 경우가 있어 `--app` 에 여러 프로세스가 필요할 수 있다 (미검증).
- 실행 중이 아닌 앱은 `--app` 으로 지정할 수 없다.
- macOS 13~15 에서는 검증하지 않았다.
- 대안 경로로 Core Audio 프로세스 탭(`CATapDescription`)이 SDK 헤더에 존재하는 것까지만 확인했다. 권한 모델은 검증하지 않았다. ScreenCaptureKit 결과가 부족할 때 별도로 조사한다.

## 책임 있는 사용

- 이 도구는 DRM이나 콘텐츠 보호를 우회하지 않는다. 보호된 재생에서 오디오가 막혀 있으면 막힌 결과를 그대로 보고한다.
- 캡처한 콘텐츠의 이용은 해당 서비스의 약관과 저작권 법규를 따라야 한다.
- 화면 녹화 권한은 강력한 권한이다. 신뢰하는 터미널 앱에만 부여하고, 검증이 끝나면 설정에서 끈다.
# subbridge-sck-audio-test
