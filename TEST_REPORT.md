# Test Report

2026-10-18 KST. 우선순위는 Multi-Device Routing입니다. **요구된 세 출력의 수락 검사는 미통과입니다.** EQ나 컴파일 성공을 그 대체 성과로 간주하지 않습니다.

## 환경과 방법

- Mac mini M4, arm64, macOS 27.0 (26A428).
- Apple Swift 6.4, Command Line Tools SDK 27, deployment target macOS 15. 로컬에는 전체 Xcode가 없습니다.
- 유선 MR4 경로는 `CalDigit TS4 Audio - Rear`, 시스템 연결 AirPlay는 일반 이름 `AirPlay`로 제공되며 모두 2ch/48kHz입니다.
- 터미널 샌드박스의 프로브는 장치/실행 앱 목록이 비어 있었습니다. 실제 장치 검사는 Finder로 실행한 네이티브 `.app` 안에서 수행했습니다. 터미널의 빈 목록을 하드웨어 부재로 판정하지 않았습니다.
- 오디오 파일은 녹음하지 않았습니다. 실제 출력을 **장치별 unmuted Process Tap으로 독립적으로 다시 읽고** RMS/Goertzel 진폭 및 host-time 기반 펄스 간격만 비교했습니다. 마이크로 실내 음향을 측정한 것은 아닙니다.

## IMPLEMENTED

- 네이티브 NSStatusItem/NSPopover, AppKit 컨트롤, 앱 아이콘/이름, EQ/설정/출력 그룹 창.
- 공개 Core Audio 프로세스 식별, Helper 묶기, 앱별 0–100% 볼륨/음소거/우회, 짧은 Gain ramp.
- 여러 실제 스테레오 하위 장치를 가진 사설 비 stacked Aggregate, 주 클록/Drift Compensation, 출력별 실제 PCM Volume/Mute/0–3000ms Delay.
- Desktop/HomePods/Immersive/Full Room 구성 슬롯과 사용자 그룹 편집·추가·삭제. 연결 불가 항목의 비활성화와 중복 장치 배정 방지.
- 10-band Global EQ, 프리셋/사용자 프리셋, Preamp, Auto Headroom, limiter, DSP smoothing.
- 처리 중지, 원본 복구, 초기 신호 확인 후 탭 mute, 콜백 감시, 장치/포맷 변화 처리, 상태 저장과 손상 복구.
- macOS의 기기·stream·safety 지연을 읽는 Match Device Timing, 타이밍 테스트음과 수동 Delay. 테스트음의 자동 종료/재실행 방지를 구현했습니다.
- SMAppService 로그인 시 실행 및 기존 오디오 프로필 관리 코드.

## VERIFIED

### 빌드와 자동 검사

| 항목 | 결과 |
| --- | --- |
| 로컬 최적화 arm64 `.app` 빌드·실행 | 성공 |
| ad-hoc 서명, 임시 staging bundle 검증 | 성공 |
| 외부 패키지 / 웹 UI 런타임 | 없음 |
| DSP·버퍼·설정 자동 검사 | **61개 통과** |
| Xcode ARM64 CI, macOS 15 / 26 | `48f5385` 두 환경 통과; 최종 커밋도 CI 확인 후 이력에 기록 |

61개 검사는 44.1/48/96kHz의 10개 밴드, 실제 PCM Gain/Mute, EQ와 Gain 동시 처리, headroom, limiter, 10ms ramp, planar/interleaved HAL 버퍼, 잘린 입력의 안전 중지, 짧은 소리의 신호 래치, 실제 출력별 impulse 지연, stereo polarity, 출력 mute 격리, 30ms 지연 변경 crossfade, 설정 migration/손상 복구, SPSC 동시 갱신을 포함합니다. 타이밍 음원의 pulse 간격·크기·종료와 재시작 안전성, 범위를 벗어난 앱 게인의 안전한 제한, OS 보고 지연의 계산과 알 수 없는 지연 거부도 검사했습니다.

### 실제 유선 + AirPlay 신호 (03:44 KST)

48kHz 실제 두 장치에서 8개 검사를 통과했습니다. 각 장치의 UID/stream 0을 지정한 **별도의 읽기 전용 탭**을 사용했습니다. 원래 시도한 사설 Aggregate UID의 출력 읽기는 0만 반환하여 검증 방법을 실제 장치 읽기로 고쳤습니다.

| 검사 | 실제 결과 |
| --- | --- |
| 두 실제 출력에 동일 펄스 전달 | 각 기준 진폭 1.000 |
| 유선만 30% | 유선 0.300000, AirPlay 1.000000 |
| AirPlay만 Mute | 유선 0.300000, AirPlay 0.000000 |
| AirPlay에 추가 120ms | 상대 변화 **119.9007ms** |
| 두 출력 Global EQ 1kHz +6dB | 양쪽 진폭 약 1.995262 |
| Pause | Vanille가 보낸 두 출력 신호 0 |
| 기본 시스템 출력 보존 | 성공 |
| 탭/Aggregate 누수 | 없음 |

이 검사는 실제 장치 경로에 제출된 신호를 확인합니다. 스피커에서 소리가 도착하는 절대 시간, 네트워크 내부 버퍼, 청취 위치의 동기화를 보증하지 않습니다.

04:03 KST에 타이밍 도구까지 포함해 **11개 검사를 재실행하여 모두 통과**했습니다. 캡처 중인 앱이 하나도 없는 상태에서도 내장 타이밍 소리가 두 실제 장치에 전달되고, 추가 400ms가 약 **399.9ms**로 읽혔으며, Stop 후 출력이 0이 되는 것을 확인했습니다. 검사 후 원래 시스템 출력과 설정을 복원했고 리소스 누수는 없었습니다.

### 실제 앱별 볼륨·EQ 회귀 검사 (04:04 KST)

**17개 모두 통과**했습니다. 네이티브 1kHz/440Hz 재생 앱 두 개를 동시에 실행하고 Vanille가 실제 출력한 신호를 별도의 탭으로 측정했습니다.

- 앱 볼륨 100/70/0%, mute, 1kHz +6dB EQ, 50% 볼륨과 EQ 동시 처리, EQ Off, Pause.
- 두 앱 동시 혼합, 한 앱만 30%, 다른 앱만 mute, 두 주파수에 실제 Global EQ 적용, 한 앱의 Protected Content Bypass, 다른 앱 종료 후 복구.
- 검사 후 기본 출력 유지, 탭 개수·장치 개수의 정확한 원상 복귀.

초기 회귀 시도에서는 사용자의 실행 중 엔진까지 baseline에 포함하여 정리 비교가 잘못 실패했습니다. 엔진을 먼저 중지하고 HAL의 비동기 제거를 기다린 뒤 baseline을 측정하도록 하네스를 고쳤습니다. 위 17개 결과는 수정 후의 재실행 결과입니다. 신호 검사의 실패를 숨기기 위해 허용 오차를 늘린 것이 아닙니다.

원본 수치: [LiveRouting.json](Tests/Results/LiveRouting.json), [LiveAudio.json](Tests/Results/LiveAudio.json), [Offline.txt](Tests/Results/Offline.txt). 오디오 샘플, 하드웨어 UID, 네트워크 이름은 포함하지 않습니다.

### 사용자 실제 청취

사용자가 Immersive의 MR4와 현재 HomePod에서 **양쪽 소리가 들림**을 확인했습니다. 초기 미디어 청취에서는 큰 차이와 HomePod 선행을 보고했습니다. 이후 **두 추가 지연을 0ms로 둔 네이티브 기준 음원에서는 MR4 선행**을 확인했습니다. 초기 수동값/플레이어 경로의 차이를 실내 지연 측정으로 혼동하지 않습니다.

추가 하드웨어 조사에서 HomePod stream latency 205ms를 확인했고, `Match Device Timing`으로 유선의 약 2.083ms를 뺀 **MR4 203ms / AirPlay 0ms**가 실제 UI·설정·DSP 파라미터에 적용되는 것을 확인했습니다. 해당 설정으로 타이밍 음원을 재생했습니다. **보정 후 청취 동기화 완료와 장시간 유지에 대한 사용자 확인은 아직 없습니다.** 정확한 브라우저·콘텐츠와 두 HomePod 페어 모두의 동시 출력 여부도 확인하지 않았습니다.

## PARTIAL

- **Multi-Device Routing:** 유선 + 시스템 AirPlay 하나의 실제 IO·신호·독립 볼륨/지연은 확인했습니다. 두 HomePod 페어를 독립적인 시스템 출력으로 연결하지 못했습니다.
- **동기화:** 실제 Delay와 OS 보고 stream 지연 기반 초기 보정은 구현·검사했습니다. 미보정 상태의 청취 차이가 확인됐으며, 203ms 보정 후 음향 동기화·장시간 drift 안정성은 미검증입니다. 자동 음향 측정은 없습니다.
- **시스템 오디오 범위:** 현재 기본 장치로 재생하며 공개 탭에서 캡처 가능한 활성 앱을 처리합니다. 다른 장치를 직접 선택한 앱, 우회 앱과 보호 오디오는 제외합니다. 매우 짧은 첫 알림음은 활성 프로세스 발견 전에 끝날 수 있어 원본으로 재생됩니다.
- **원본 복구:** Pause/일반적인 엔진 중지·검사 리소스 해제를 확인했습니다. 권한 거부, 강제 종료, 잠자기/깨우기, 실제 네트워크 단절과 Core Audio 재시작을 모두 물리적으로 검사한 것은 아닙니다.
- **DRM:** 수동 bypass 경로를 신호 검사했습니다. 실제 Netflix/TV+/보호된 Music 재생 검사는 하지 않았습니다. 보호 콘텐츠 자동 감지는 없습니다.
- **설정과 프로필:** 파일 저장/복원은 검사했습니다. 로그인 시 실행은 코드 구현만 했으며 사용자의 로그인 항목을 변경해 검사하지 않았습니다. 프로필은 그룹 스냅샷을 포함하지 않습니다.

## NOT IMPLEMENTED

- 두 독립 HomePod 페어의 시스템 전체 동시 연결과 Full Room 수락 시나리오.
- 마이크/루프백 기반 자동 음향 지연 측정, 자동 동기화, 재연결 후 지연 재추정.
- 자체 AirPlay 2/RAOP 프로토콜, 비공개 MediaRemote/AVOutputContext, 외부/커널 드라이버.
- 자동 DRM 판정, 보호 콘텐츠 복호화, 영상 프레임 캡처.
- 장치별 EQ와 앱별 서로 다른 목적지 라우팅.
- Developer ID 서명·공증·업데이트 배포.

## KNOWN ISSUES

1. **보정 후 실내 동기화는 미검증입니다.** 기준 음원의 MR4 선행과 OS의 205ms stream 지연을 근거로 MR4에 203ms를 적용했습니다. 소프트웨어의 120/400ms 검사는 스피커의 절대 음향 오프셋을 측정하지 않습니다.
2. Core Audio에 AirPlay 출력 하나만 나타나며 일반 이름/연결별 UID이므로 두 페어의 신원·재연결 복원에 제약이 있습니다.
3. 처음부터 캡처 불가한 오디오는 원본을 유지하지만, 이미 처리 중인 브라우저가 DRM으로 전환되는 상황은 자동 감지하지 않습니다. 해당 브라우저를 수동 우회해야 합니다.
4. 활성 프로세스/기본 장치 변화 시 엔진을 다시 만들면서 짧은 원본↔처리 전환이 발생할 수 있습니다. 끊김 없는 전환을 장시간 검증하지 않았습니다.
5. iCloud Documents의 File Provider가 앱에 FinderInfo 메타데이터를 붙일 수 있습니다. 서명은 별도 임시 폴더에서 검사하고 그 원본으로 zip을 만듭니다. 재배포·서명 검사는 zip에서 새로 푼 사본을 기준으로 합니다.
6. 기본 UI는 영어이며 전체 VoiceOver/키보드 동선과 모든 OS appearance 조합은 추가 확인이 필요합니다.

## 최종 수락 기준

| 요구 | 판정 |
| --- | --- |
| 실제 native app·arm64·메뉴 막대 | VERIFIED |
| 앱별 실제 볼륨·mute와 EQ 동시 처리 | VERIFIED (실제 검사 범위 한정) |
| 유선 + 현재 AirPlay의 독립 PCM Volume/Delay | VERIFIED |
| MR4 + HomePod 페어 + HomePod mini 페어 | NOT IMPLEMENTED / 미통과 |
| 세 출력 음향 동기화 | 미통과 |
| Safari YouTube의 요구된 전체 8단계 시나리오 | 미통과 |
| 보호 콘텐츠별 정상 영상·오디오 | 미검증 |
| 모든 비정상 상황 복구 | PARTIAL |

## 검사 이력

- `29594ad`: native shell / process tap 기본 파이프라인.
- `1563345`: offline 및 실제 출력 검사, Helper 그룹.
- `0ea444b`: macOS 15/26 Xcode CI 성공, 서명 보존 패키징.
- `91b528c`: 실제 신호 확인 후 원본 mute, 두 앱 동시 검사. [두 OS CI 성공](https://github.com/avanturation/vanille/actions/runs/39056639223).
- `48f5385`: 다중 출력, 독립 Gain/Delay, 그룹 편집과 타이밍 도구, 제한 문서화. [macOS 15/26 Xcode·offline·app 빌드 모두 성공](https://github.com/avanturation/vanille/actions/runs/39060207177).
