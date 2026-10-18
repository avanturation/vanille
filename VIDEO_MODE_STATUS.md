# Video Mode — latest status

2026-10-18 · `experiment/latency-aware-output` · Mac mini M4 / macOS 27.0.

**Safari/YouTube에서 MR4와 두 HomePod 목적지의 영상·소리가 조작 전후에 맞는다는 사용자 확인을 받았습니다. 다만 조작 후 반응 대기가 여전히 너무 길다는 보고가 있어 전체 Video Mode 수락 검사는 아직 통과하지 않았습니다.** 초기 조작 검사에서는 싱크 변화·일부 출력 중단도 있었으며, 소스 복구 수정 뒤 사용자는 “싱크는 맞음”이라고 확인했습니다. 정밀 음향 계측이나 모든 플레이어의 보증으로 확대하지 않습니다.

## IMPLEMENTED

- 기존 정식 앱과 분리된 Swift/AppKit 실험 앱의 Music / Video Mode, Start / Stop. 사용자용 지연 입력은 없습니다.
- 공개 AudioServerPlugIn 0.1.2와 물리 MR4를 함께 포함하는 시스템 출력. 후단 AirPlay 재생 시점과 입력 `mHostTime`을 비교하여 실제 HAL 출력 지연을 자동 보고합니다. 영상이 늦은 오디오를 따라가도록 소스 플레이어에 지연을 알리며, 영상을 맞추려고 오디오를 더 늦추지 않습니다.
- 앱별 Process Tap → 기존 Gain/EQ DSP → 고정 메모리 PCM 이력 → 메모리 AAC/HLS → AVPlayer → 네이티브 AirPlay 다중 선택. MR4는 같은 재생 클록을 따라 물리 HAL 장치로 직접 출력합니다.
- 소스 앱과 PID의 변경을 고정 탭 슬롯에 반영합니다. 새 앱을 위해 AAC 스트림·출력 장치를 다시 만들지 않습니다. 원본 신호가 확인된 탭만 `mutedWhenTapped`로 전환합니다.
- Core Audio의 프로세스 출력 중단·재개 알림, 일시 중지 중 정상 콜백 정지의 허용, 재개 시 오래된 미디어를 건너뛰는 경로. 원본 복구, 포맷·장치·콜백 감시와 명시적인 Stop.

## VERIFIED

| 검사 | 실제 결과 / 한계 |
| --- | --- |
| 네이티브 세 출력 | 사용자가 MR4 + 두 HomePod 목적지에서 동일 오디오 청취 확인 |
| Safari/YouTube 연속 재생 | 사용자: “MR4도 HomePod·영상과 대체로 일치함”. 정밀 음향 계측이나 모든 플레이어의 보증은 아님 |
| MR4 경로 수정 | 공개 Aggregate를 통한 재출력의 중복 지연을 피하고 물리 HAL로 직접 렌더링. 수정 전 MR4가 늦었고 수정 후 위 사용자 확인 |
| 설치된 드라이버 | 0.1.2 서명·바이너리 SHA 일치, 실제 기본 출력 선택 및 지연 설정 성공. 기존 75개 드라이버 격리 검사 통과 |
| 자동 지연 보고 | 실제 Chrome 세션에서 선언값 4,000 → 3,400ms, 측정 중앙값 약 3,395ms. 드라이버와 Aggregate 실제 HAL 속성 반영 확인. 마이크 측정이 아님 |
| 회귀 및 오디오 코드 검사 | 기존 DSP/설정 63개, PCM 이력 7개, A/V 분석 16개, 분리된 캡처·출력 콜백 8개 통과. 셸 AAC 검사는 서비스 접근 제약으로 SKIP |
| 조작 후 사용자 검사 | **실패:** 긴 대기, 싱크 변화, 일부 스피커 출력 중단 보고. 후속 수정의 합격으로 간주하지 않음 |
| 소스 복구 수정 후 재검사 | 실제 소스 종료·다른 앱 시작과 Safari 일시 정지·재개에서 연결 유지, 원본 중복 방지, MR4 PCM 복구 확인. 사용자: 조작 전후 싱크는 맞지만 반응 대기가 너무 김. **응답성 미통과** |
| Native AAC 검사 | 실제 앱에서 메모리 AAC, 부분·전체 세그먼트, manifest, 요청 경계·메모리 상한 **8개 통과** |

수치와 청취 결과는 `Reports/AVSync/installed-driver-012-*.json`에 구분해 기록합니다. 오디오 샘플, 개인 네트워크 이름과 기기 UID는 보고서에 포함하지 않습니다.

## PARTIAL

- **Video Mode:** 연속 재생 및 조작 전후 싱크의 질적 확인은 있으나 응답성 기준 미통과입니다. 새 소스 추적·재개 native 결과는 [source-recovery 보고서](Reports/AVSync/installed-driver-012-source-recovery.json)에 기록했습니다.
- **자동 보정:** 입력과 AVPlayer 프로그램 시점 간의 소프트웨어 지연을 반영합니다. 이 환경에서 약 3.4초의 AirPlay 버퍼 자체가 없어지는 것은 아닙니다. 네트워크·스피커 내부 지연과 청취 위치를 자동 음향 측정하지 않습니다.
- **외부 플레이어:** 출력 장치 지연을 존중하는 플레이어에 적용됩니다. 프로세스 `IsRunningOutput`은 미디어 탐색 API가 아니므로 브라우저가 IO를 유지한 채 탐색하는 경우를 자동 감지한다고 보장하지 않습니다.
- **출력 제어:** Apple의 AirPlay 선택창에서 목적지별 볼륨과 선택을 제어합니다. 공개 AVPlayer API는 선택된 모든 원격 목적지의 안정적인 신원 목록을 제공하지 않으므로, 세 장치의 영구 식별·그룹 자동 재연결을 완성한 것은 아닙니다.
- **기존 기능:** 실제 EQ와 앱 Gain DSP 및 설정을 재사용합니다. 정식 메뉴 막대 앱의 편집기와 이 실험의 Video Mode를 통합한 제품 배포본은 아닙니다. 두 앱을 동시에 처리하지 마세요.

## NOT IMPLEMENTED

- Netflix / TV+ / 보호된 Apple Music의 실제 DRM 재생 검증, 보호 전환 자동 감지.
- 브라우저의 임의 탐색 시점 제어, 영상 프레임 캡처, 비공개 AirPlay 프로토콜. 프레임·화면·DRM 데이터에 접근하지 않습니다.
- 두 HomePod 페어를 각각의 HAL 장치로 생성하는 경로, 완전한 그룹 자동 복원, 장치별 EQ.
- 모든 앱·macOS 버전의 동기화 인증, Developer ID 서명·공증.

## KNOWN ISSUES

- 시작·재개에는 AirPlay 버퍼 준비 시간이 필요합니다. 최신 사용자 검사는 조작 전후 싱크를 확인했지만 기다림이 너무 길다는 응답입니다. 반응성 최적화를 계속 검증해야 합니다.
- 보호 콘텐츠로 전환할 때는 해당 앱의 저장된 bypass를 사용하거나 Stop으로 원본을 복구해야 합니다. 자동 DRM 감지는 없습니다. 처음부터 신호를 읽지 못하는 앱은 원본 경로에 둡니다.
- 기존 정식 Vanille를 동시에 실행하면 그 앱의 출력 복구 정책과 충돌할 수 있어 실험 시작을 거부합니다. 먼저 다른 Vanille 처리를 종료하세요.
- 실험의 macOS 기본 출력은 `Vanille Video Output`입니다. 실제 오디오는 MR4와 선택된 HomePod로 갑니다. 사용자가 허용한 예외이며 MR4가 문자 그대로 기본 출력이라는 기존 Music Mode 조건과 구분합니다.
- 잠자기·강제 종료·네트워크 단절·Core Audio 재시작의 전체 조합, 장시간 음향 drift는 아직 모두 검증하지 않았습니다. 오류 시 원본 복구가 제품 수준의 모든 장애 검증을 대신하지 않습니다.

## 실행 / 복구

기존에 설치한 드라이버 **0.1.2를 그대로 사용**합니다. 이번 클라이언트 수정에 드라이버 재설치는 필요 없습니다. `Scripts/build-airplay-bridge-lab.sh`로 빌드한 앱에서 두 AirPlay 목적지를 선택하고 Video Mode → Start를 누릅니다. Stop은 원본 출력 복원 후 캡처·출력을 중지하고 실험 Aggregate를 제거합니다. 사용자별 EQ·앱 볼륨·bypass 설정은 기존 설정에서 읽습니다.

이 실험에는 명시적으로 승인받아 설치한 `/Library/Audio/Plug-Ins/HAL/VanilleLatencyClock.driver`가 필요합니다. 설치·회수 범위는 [VIRTUAL_OUTPUT_REVIEW.md](VIRTUAL_OUTPUT_REVIEW.md)에 있습니다. 기본 정식 앱은 이 드라이버를 사용하지 않습니다.

공식 API: [Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [AudioServerPlugIn](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in), [AVPlayer 대기 정책](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling), [장치 지연](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertylatency).
