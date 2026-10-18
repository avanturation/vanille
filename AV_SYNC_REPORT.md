# A/V Synchronization — 2026-10-18

> **소스 복구 수정 후 최신 사용자 확인:** 조작 전후 세 출력과 영상의 싱크는 맞지만, 반응 대기가 너무 깁니다. 응답성은 미통과이며 [현재 상태](VIDEO_MODE_STATUS.md)를 기준으로 판단하세요. 아래의 실패 기록은 수정 전 검사 이력도 포함합니다.

> **과거 비교 실험의 이력입니다.** 이후 드라이버 0.1.2와 물리 MR4 직접 출력으로 Safari 연속 재생의 세 출력 A/V 사용자 확인을 받았습니다. 후속 일시 정지·재개·탐색은 실패했습니다. 현재 상태와 새로운 자동 보정 경로는 [VIDEO_MODE_STATUS.md](VIDEO_MODE_STATUS.md)에 있습니다. 아래의 “미해결”은 당시 결과입니다.

**외부 앱의 다중 스피커 영상 싱크는 아직 해결되지 않았습니다.** 대신 네 가지 출력 경로를 실제 Mac에서 각각 90초 계측했고, Vanille가 직접 재생하는 테스트 영상의 시간을 오디오에 맞추는 보정을 구현했습니다. Full Group에서 사용자는 번쩍임과 짧은 소리가 **“대체로 맞음”**이라고 확인했습니다. 이 확인을 Safari·YouTube·DRM 영상의 성공으로 확대하지 않습니다.

브랜치: `experiment/av-synchronization`. 기존 `Vanille/` 제품 소스, EQ, 앱별 볼륨, HAL 라우팅은 `main`과 동일하게 보존했습니다. 변경은 별도 네이티브 AirPlay 실험 앱과 계측 도구에 있습니다.

## 실제 비교 결과

환경: Mac mini M4, arm64, macOS 27.0 (26A428), Swift 6.4 / SDK 27. 최소 빌드 대상 macOS 15. HomePod 기본 출력은 사용자가 제어 센터에서 연결했고, 나머지 세 검사는 MR4의 USB 출력이 macOS 기본 장치인 상태에서 실행했습니다.

테스트는 48 kHz 스테레오의 작은 비프와 자체 생성한 무음 H.264 영상입니다. 17초 주기의 불규칙한 네 지점에서 비프·흰 화면을 표시합니다. 일정한 메트로놈은 수초 지연이 한 주기와 우연히 맞을 수 있어 사용하지 않았습니다. 외부 영상이나 화면은 캡처하지 않았습니다.

| 경로 | 실행 명령→플레이어 타임라인 차이 중앙값 | 캡처→재출력 플레이어 타임라인 차이 중앙값 | 30–90초 관찰 |
|---|---:|---:|---|
| MR4 단독 | 154 ms | 해당 없음 | 큰 누적 증가 없음 |
| HomePod를 macOS 기본 출력으로 선택 | 757 ms | 해당 없음 | 큰 누적 증가 없음 |
| MR4 기본 출력, Vanille→HomePod 한 목적지 | 4,726 ms | 4,608 ms | 연결 전환 후 대체로 일정 |
| MR4 기본 출력, Vanille→HomePod 두 목적지 + MR4 | 3,745 ms | 3,690 ms | 대체로 일정 |

**표의 값은 마이크로 측정한 음향 지연이 아닙니다.** 첫 번째 수치는 명령 시각과 AVPlayer 미디어 시간이 진행한 정도의 차이로, 준비·시작 대기·버퍼링을 포함합니다. 두 번째는 캡처 PCM 진행 위치와 AVPlayer의 program-date 위치 차이입니다. 서로 다른 기준의 값을 단순히 빼서 물리적 스피커 지연으로 해석하면 안 됩니다. 두 브리지 검사 사이의 차이 역시 출력 수에 따른 일반 법칙이 아니라 각 연결 세션의 실제 버퍼 상태입니다.

각 검사에서 10 Hz로 수집했습니다. 원본 분석은 첫 15초를 제외하고, 별도 안정 구간 분석은 첫 30초를 제외합니다. 원본 분석도 함께 보존해 연결 전환을 숨기지 않았습니다. 수치는 [정리된 계측 JSON](Reports/AVSync/comparison-summary.json)에 있습니다.

### 고정 지연과 누적 지연

- HomePod 한 목적지로 전환할 때 초기 캡처→플레이어 차이가 약 3.30초에서 4.61초로 계단처럼 바뀌었습니다. 원본 구간에는 100 ms 초과 변화 네 번이 있습니다. 이 구간의 회귀 기울기를 클록 드리프트라고 해석하지 않습니다.
- 30–90초 구간에서 HomePod 한 목적지의 기울기는 +3.85 ms/분, R² 0.093, 앞/뒤 구간 중앙값 차이는 +2.59 ms였습니다. Full Group은 +0.95 ms/분, R² 0.0036, 앞/뒤 차이 −0.08 ms였습니다. 이 관찰에서는 수초 지연의 원인이 지속적인 클록 오차라는 증거보다 버퍼링에 의한 오프셋의 증거가 강합니다.
- MR4 하드웨어 sample clock과 host clock 사이에는 약 −0.22~−0.25 ms/분의 작은 상대 변화가 실제로 측정됐습니다. 오차가 정확히 0이라고 주장하지 않습니다. 이 정도의 변화로 수초의 A/V 오프셋을 설명할 수는 없습니다.
- 90초 검사는 장시간 네트워크 혼잡, 한 시간 이상의 드리프트, 잠자기 이후 동작을 보증하지 않습니다.

## Core Audio 지연 및 타임스탬프

| 항목 | MR4 USB 경로 | macOS 기본 HomePod 경로 |
|---|---:|---:|
| Sample rate | 48,000 Hz | 48,000 Hz |
| `kAudioDevicePropertyLatency` | 50 frames / 1.042 ms | 0 frames |
| `kAudioStreamPropertyLatency` | 0 frames | 9,840 frames / 205 ms |
| Safety offset | 50 frames / 1.042 ms | 0 frames |
| IO buffer | 512 frames / 10.667 ms | 128 frames / 2.667 ms |
| 실제 IO callback→`inOutputTime.mHostTime` 중앙값 | 약 11.63 ms | 약 2.67 ms |
| AU `deviceOutputLatency` | 1.042 ms | 0 ms |
| AV `presentationLatency` | 1.042 ms | 0 ms |

0으로 반환된 항목은 실제 네트워크·스피커 지연이 0이라는 뜻이 아닙니다. `mHostTime`은 HAL이 프레임을 하드웨어로 넘기는 시각이며 청취 위치에 소리가 도달하는 시각이 아닙니다. 스케줄링 lead에 buffer·safety·device·stream 값을 전부 다시 합치면 중복 계산할 수 있어 각각 기록했습니다.

`AudioDeviceGetCurrentTime`, `AudioDeviceTranslateTime`, IOProc의 now/input/output 타임스탬프, sample time, rate scalar, AVPlayer timebase를 함께 계측합니다. 시작 시 유효 플래그와 함께 host time 0이 반환된 실제 사례를 발견해 0·비유한 값·클록 역행을 처리하도록 수정했습니다. 첫 계측의 잘못된 절대 오차는 결과에서 제외하고 MR4 검사를 재실행했습니다. 최종 원본에는 시작 중 sample clock epoch 재시작도 별도로 기록합니다.

### 플레이어가 후단 지연을 아는가

MR4 및 macOS 기본 HomePod의 네이티브 재생에서는 `CMAudioDeviceClockGetAudioDevice`로 실제 기본 장치와 일치하는 클록을 확인했습니다. 각각 900회와 896회 샘플에서 일치했습니다. 이것은 네이티브 플레이어가 출력 장치와 연결된 클록을 얻는다는 검증이며, 임의 브라우저의 최종 립싱크 검증은 아닙니다.

앱 전용 AirPlay Full Group에서는 같은 조회가 −12746을 반환했고, HAL 기본 장치와의 일치는 0회였습니다. macOS 기본 장치의 조회값은 계속 MR4의 1.042 ms였습니다. 원래 Safari 등이 보는 MR4 경로에는 후단의 약 3.7초 HLS 버퍼가 표시되지 않습니다. 현재 캡처→별도 AVPlayer 구조에서 외부 플레이어가 이 추가 시간을 자동으로 보상한다고 가정할 근거가 없습니다.

추가로 실행하지 않는 private aggregate 두 개를 만들어 `kAudioSubDeviceExtraOutputLatencyKey`에 0 / 48,000 frames를 각각 설정했습니다. 기본 출력을 바꾸거나 IO를 시작하지 않았습니다. 이번 단일 MR4 구성에서는 둘 다 aggregate device latency 50 frames, stream latency 0, AU 지연 1.042 ms로 동일했습니다. 두 임시 장치 모두 정상 제거됐고 기본 출력도 유지됐습니다. [검사 결과](Reports/AVSync/latency-property-probe.json). 이 결과를 모든 aggregate 구성에서의 불가능성 증명으로 해석하지 않습니다. 물리 장치에 지연값을 강제로 쓰지 않았습니다.

## 영상 보정 구현과 범위

`ControlledVideo`는 직접 생성한 **영상만 있는 파일**을 재생합니다. `AVPlayer.sourceClock`을 오디오 플레이어의 source clock에 연결하고, `setRate(_:time:atHostTime:)`로 해당 오디오 타임라인에 영상 재생을 예약합니다. 브리지에서는 program-date와 캡처 원점을 사용합니다. 별도 제어 큐가 동작하며 UI 갱신 주기에 의존하지 않습니다.

보정 때문에 오디오 지연을 추가하지 않았습니다. 기존 MR4의 오디오 상호 정렬은 보존했고, 새로운 A/V 보정은 영상의 위치만 변경합니다. 비교용 `Before Video Compensation` / `Follow Audio for Video` 명령도 테스트 영상에만 적용됩니다.

Full Group의 30–90초 보정 후 영상 timebase 잔차는 중앙값 −0.037 ms, p05 −0.075 ms, p95 +0.034 ms, 최대 +0.616 ms였습니다. 자체 테스트 파일의 디코딩 프레임 PTS 잔차 중앙값은 −28.44 ms였습니다. 30 fps 영상의 프레임 단위 관측이며, 화면 패널의 실제 발광 시점이나 음향 측정은 아닙니다.

HomePod 한 목적지 전환 검사에는 보정 후에도 일시적인 약 251 ms timebase 잔차가 한 번 남았습니다. 중앙값·정상 구간 수치만으로 전환 시 동작까지 완벽하다고 판단하지 않습니다. 17초 테스트 루프 전환은 의도적인 재예약이며, 전환 직후 250 ms는 잔차 통계에서 제외합니다. 이는 임의 영화를 재생하는 완성된 플레이어가 아닙니다.

Full Group에서 사용자에게 화면 번쩍임과 소리만 비교하도록 요청했고 **“대체로 맞음”**이라는 정성적 확인을 받았습니다. 밀리초 추정을 요구하지 않았습니다. 이 테스트 영상의 보정은 청취 확인됐지만 일반적인 외부 앱 Video Mode는 **미완료**입니다.

### Music Mode / Video Mode

- **Music Mode:** 기존 다중 AirPlay 브리지와 gain/EQ 처리 구조를 유지합니다. 수초 버퍼가 있으므로 외부 영상 동기화 모드로 사용하지 않습니다.
- **Video Mode:** 실험 앱의 기존 처리를 중지하고 외부 앱의 원본 오디오를 유지합니다. `Live System Audio` 버튼을 비활성화하고 코드에도 차단 조건을 유지합니다. 네 가지 비교는 별도의 명시적 테스트입니다.
- Safari·Chrome·VLC의 영상 재생 시각을 이 앱이 임의로 변경하는 기능은 구현하지 않았습니다. 외부 플레이어가 제공하는 문서화된 시간 제어 또는 지연이 올바르게 보고되는 별도 출력 경로가 필요합니다.

### DRM

화면·브라우저·보호 영상 프레임을 읽지 않습니다. `AVPlayerItemVideoOutput`은 오직 직접 생성한 무음 테스트 파일의 PTS 확인에 사용합니다. 테스트 영상만 임시 파일에 생성하며 사용자 오디오는 저장하지 않습니다. DRM 감지기를 구현한 것처럼 표시하지 않습니다. Video Mode의 외부 앱은 캡처를 시작하지 않고 원래 재생 경로를 유지합니다. Netflix·TV+·보호된 Apple Music 콘텐츠의 실제 재생은 이번 검사에서 **미검증**입니다. 원래 HomePod 출력 자체에 있는 플레이어별 지연 문제도 자동 해결한다고 주장하지 않습니다.

## IMPLEMENTED

- 네 경로 90초 계측, Core Audio IO/sample/host time 및 AVPlayer 클록 비교.
- 고정 오프셋·계단형 버퍼 변화·회귀 기울기·클록 epoch 재시작을 구분하는 수치 보고.
- 자체 영상의 source-clock 기반 보정과 독립 제어 큐.
- Music / Video 구분, 외부 영상의 원본 경로 유지, Video에서 live capture 비활성화.
- Swift 기반 결과 요약 도구. 원본 샘플은 로컬에 보존하고 공개 보고에는 장치 UID·원격 이름·오디오를 포함하지 않습니다.

## VERIFIED

- Apple Silicon 네이티브 앱 빌드 및 실제 실행. 실시간 스레드의 기존 gain/EQ/PCM 경로 유지.
- 네 경로 각각 90초 완료. 네 번 모두 계측 IO stop / destroy가 `noErr`였습니다.
- Full Group에서 두 AirPlay 목적지와 MR4를 선택하고 기본 출력 MR4를 유지. 자체 영상·소리의 정성적 일치 사용자 확인.
- 분석 회귀 검사 10/10, 실제 AAC 서비스가 있는 앱 안에서 segment 검사 8/8, PCM/history 회귀 검사 7/7.
- 최종 코드 `ffa387e`의 [macOS 15 / 26 CI](https://github.com/avanturation/vanille/actions/runs/39102633480)가 성공했습니다. 각 러너에서 기존 제품 DSP/안전 63개 + PCM 7개 + 실제 AAC 8개 + A/V 분석 10개, 총 88개 검사와 Xcode 프로젝트·별도 실험 앱 빌드를 통과했습니다. 로컬은 전체 Xcode 없이 CLT로 앱을 빌드했고 실제 하드웨어 검사는 이 Mac에서 수행했습니다. [세부 검증 기록](Reports/AVSync/verification.json), [CI 요약](Reports/AVSync/ci-check-summary.txt).

## PARTIAL

- 보정은 통제 가능한 자체 테스트 영상에 한정됩니다. 영화 파일 열기·외부 플레이어 통합을 제공하지 않습니다.
- 개별 HomePod의 음향 지연·클록은 앱 전용 AirPlay 경로에서 공개 HAL 장치로 조회하지 못합니다. 원격 선택·음량은 Apple의 네이티브 picker를 사용합니다.
- 연결 전환 중 버퍼 변화와 일시적인 영상 잔차가 남습니다. 장시간 동작과 물리 측정은 남아 있습니다.
- 앱별 볼륨·EQ는 기존 제품 구현을 보존합니다. 실험 브리지는 시작할 때 저장된 설정을 읽으며 실시간 제품 UI와 통합된 버전은 아닙니다.

## NOT IMPLEMENTED

- Safari·Chrome·DRM 영상의 일반적인 다중 스피커 A/V 동기화.
- 외부 앱에 HLS 지연을 자동으로 알리는 가상 출력 장치 또는 드라이버.
- 마이크·카메라를 사용하는 자동 음향 지연 측정, 개별 HomePod에 대한 HAL latency 조절.
- 완전한 DRM 감지, 선택된 원격 장치 신원 조회·그룹 자동 재연결.

## KNOWN ISSUES

- 음악 브리지는 약 3.7~4.6초의 후단 타임라인 차이가 남습니다. 모든 네트워크 상태에서 같은 값이 아닙니다.
- 한 목적지로의 연결 전환에서 버퍼 증가와 영상 잔차가 있었습니다. 재동기화는 순간적인 영상 위치 변경을 동반할 수 있습니다.
- timebase/디코딩 프레임 잔차는 실제 화면과 스피커의 지연을 증명하지 않습니다. 이번 청취 확인도 정밀 계측이 아닙니다.
- Video Mode의 live-capture 차단 조건을 의도적으로 호출하는 부정 검사는 자동 승인 검토가 막았습니다. 이후 버튼 자체를 비활성화하는 안전한 UI로 변경하고, 실제 비활성 상태와 원본 MR4 출력을 확인했습니다. 코드 차단 조건의 직접 호출은 미검증으로 남습니다.
- 90초 범위를 벗어난 누적 오차, 네트워크 혼잡, DRM, 잠자기/깨우기는 추가 검사 대상입니다.
- 이 빌드는 별도 실험 앱입니다. 정식 `Vanille.app`과 동시에 오디오 처리를 시작하지 마세요.

## 재현 및 다음 판단

`Scripts/build-airplay-bridge-lab.sh`로 빌드합니다. 자체 클립 준비 후 경로를 선택하고 `Run 90-second Comparison`을 누릅니다. HomePod 기본 출력 비교는 macOS에서 해당 출력을 먼저 선택합니다. 브리지 비교는 MR4를 기본 출력으로 두고 native picker에서 목적지를 선택합니다. Full Group은 그다음 `Include MR4`를 켭니다. 90초 후 테스트가 멈추고 원본 경로를 유지합니다.

결과는 `build/avsync-*.json`에 수치만 기록됩니다. `Scripts/export-avsync.sh summary.json report1.json ...`로 동일한 분석을 재생성할 수 있습니다. 추가 오디오 보정 슬라이더는 제공하지 않습니다.

후속 P0는 외부 플레이어가 지연을 인식하는 출력 토폴로지의 실증 또는 문서화된 플레이어 영상 시간 제어입니다. 이 조건을 확보하기 전에는 Music Mode의 다중 출력을 일반 영상 지원으로 배포하지 않습니다. 새 EQ 기능이나 앱별 라우팅은 이 문제를 해결한 후 검토합니다.

## 공식 API 근거

- [AVPlayer.sourceClock](https://developer.apple.com/documentation/avfoundation/avplayer/sourceclock)
- [AVPlayer.setRate(_:time:atHostTime:)](https://developer.apple.com/documentation/avfoundation/avplayer/setrate(_:time:athosttime:))
- [kAudioDevicePropertyLatency](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertylatency), [kAudioStreamPropertyLatency](https://developer.apple.com/documentation/coreaudio/kaudiostreampropertylatency)
- [kAudioSubDevicePropertyExtraLatency](https://developer.apple.com/documentation/coreaudio/kaudiosubdevicepropertyextralatency), [kAudioSubDeviceExtraOutputLatencyKey](https://developer.apple.com/documentation/coreaudio/kaudiosubdeviceextraoutputlatencykey)
- [AVRoutePickerView.player](https://developer.apple.com/documentation/avkit/avroutepickerview/player), [AVSampleBufferAudioRenderer.audioOutputDeviceUniqueID](https://developer.apple.com/documentation/avfoundation/avsamplebufferaudiorenderer/audiooutputdeviceuniqueid)
- [HLS Authoring Specification](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/). Local HLS 브리지는 제품 경로로 검증이 끝난 구현이 아니라 이번 feasibility 실험입니다.

설치된 공개 SDK의 `AudioHardware.h`, `AudioHardwareBase.h`, `AVPlayer.h`의 계약도 함께 확인했습니다.
