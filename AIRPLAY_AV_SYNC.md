# AirPlay 실험 결과 — 영상 싱크 미해결

2026-10-18 KST · `experiment/multi-airplay-routing` · Mac mini M4 / macOS 27.0.

**MR4를 macOS 기본 출력으로 유지하면서 두 HomePod 목적지까지 같은 소리를 보내는 데 성공했습니다. 사용자는 세 스피커 사이의 싱크도 맞는다고 확인했습니다. 그러나 Safari 영상과 오디오의 싱크는 맞지 않으며, 이 요구는 완료하지 못했습니다.**

## IMPLEMENTED

- 기존 정식 앱과 분리한 Swift/AppKit 실험 앱. 정식 앱의 EQ·앱 볼륨·설정 코드는 변경하지 않았습니다.
- 공개 Process Tap → 기존 Gain/EQ DSP → 메모리 AAC → AVPlayer → Apple의 네이티브 AirPlay 다중 선택.
- MR4는 같은 PCM 이력을 플레이어의 프로그램 시점에 맞춰 재생합니다. 사용자 지연 입력이나 슬라이더는 없습니다.
- 일시 중지 중 원본 출력 복구, 재개 시 최신 스트림 위치로 이동, MR4 포함 상태와 자동 재정렬 유지.
- 재생이 Mac으로 돌아온 것을 공개 Core Media 장치 클록으로 확인하면 브리지를 안전하게 중지합니다.
- **Use MR4 for Video** 버튼으로 다중 출력 처리를 중지하고 원본 출력을 복구합니다. 영상 자동 감지는 구현하지 않았습니다.
- 부분 세그먼트·차단형 재요청·preload·메모리 상한·진단 수치를 구현했습니다. 수치에는 오디오 샘플, 장치 UID, 네트워크 이름이 없습니다.

## VERIFIED

| 실제 검사 | 결과와 범위 |
| --- | --- |
| Audio MIDI Setup의 Multi-Output Device | MR4 기본 출력에서는 두 HomePod를 독립적인 HAL 장치로 구성할 수 없었음. 기존 사용자 장치는 삭제하지 않음 |
| 네이티브 AirPlay 선택 | HAL AirPlay 장치가 0개인 상태에서도 두 원격 목적지 동시 체크 가능 |
| Safari YouTube → 세 출력 | 사용자 실제 청취: 세 출력 모두 들림 |
| 스피커 상호 동기화 | 사용자 실제 청취: MR4·HomePod들 싱크 맞음. 마이크 측정·장시간 검사는 아님 |
| 영상과 오디오 | 사용자 실제 확인: 싱크 불일치. **실패** |
| 일시 중지/재개 | MR4 포함 선택 유지, 원본 차단 해제, 재개 후 자동 재정렬. 일시 중지한 전체 시간을 계속 재생하지 않음 |
| Mac으로 경로 복귀 | 플레이어·캡처 자동 중지, 원본 차단 해제, IO/Aggregate 정리 상태 0 |
| 정식 앱 회귀 검사 | 63개 통과 |
| PCM 이력·인덱스·동시성 | 7개 통과 |
| 실제 AAC/매니페스트/보관 상한 | 네이티브 앱에서 8개 통과. 터미널 환경에서는 AAC 서비스 접근 불가로 SKIP |

최종 320ms 부분 세그먼트의 재개 검사에서 캡처 프레임과 플레이어 시점 차이는 약 **3.6초**, 경로 변경 전 관찰값은 약 **4.6~4.8초**였습니다. 106.7ms 부분 세그먼트와 더 작은 버퍼도 시험했지만 약 **4.1초**가 남았습니다. 작은 세그먼트 실험은 되돌렸습니다. 이는 소프트웨어 시점 차이이며 스피커의 음향 도착 시간을 측정한 값은 아닙니다.

AVPlayer가 이 Mac에서 권장한 live offset은 3초였습니다. HTTP 수치상 대부분 완성된 세그먼트를 읽었으므로, 부분 세그먼트 태그가 있다는 이유만으로 저지연 재생 성공이라고 표시하지 않습니다. 네이티브 검사 중 한 번의 실패는 인코더가 마지막 부분 세그먼트를 만드는 도중 검사한 경합이었고, 생산 완료가 안정된 뒤 검사하도록 고쳐 8개 모두 재통과했습니다.

## PARTIAL

다중 출력의 타당성과 한 차례의 청취 동기화는 확인했습니다. 현재 결과는 음악 등 오디오 청취용 실험이며 제품 수준의 일반 영상 출력 그룹은 아닙니다. 원격 장치별 볼륨은 Apple 선택 UI에 있으며, 별도 신원 기반 연결 상태 관리나 프로필에는 통합하지 않았습니다.

기존 EQ와 앱별 Gain은 실험 시작 시 저장된 설정의 스냅샷을 처리합니다. 정식 UI에서 바꾸는 값을 실험 앱에 실시간 연결하는 통합은 하지 않았습니다. 실험 시작 당시 활성 앱만 캡처합니다.

## NOT IMPLEMENTED

- Safari·Chrome·VLC 등 다른 앱의 영상을 자동 지연시키는 기능.
- 세 출력 동시 재생을 유지하면서 일반 시스템 영상의 입 모양까지 맞추는 기능.
- 특정 HomePod 신원으로 저장한 그룹의 자동 연결·재연결.
- 모든 물리적 네트워크 단절, 잠자기, 강제 종료와 DRM 서비스의 실제 검증.
- 비공개 API, 자체 AirPlay 프로토콜, 드라이버, 영상 프레임 캡처.

## KNOWN ISSUES

오디오를 캡처한 뒤 전달하는 경로에는 추가 버퍼가 있습니다. MR4를 늦추면 스피커끼리는 맞출 수 있지만, 이미 다른 앱에서 표시한 영상을 오디오 쪽에서 되돌릴 수는 없습니다. 이 조사에서 다른 앱의 영상 타이밍을 제어하거나, MR4의 장치 지연 값을 브리지의 지연으로 바꾸어 모든 플레이어에 전달하는 지원 경로는 확인하지 못했습니다. 실제 MR4 출력의 latency 속성은 변경 불가로 보고됐습니다.

따라서 **현재 브리지를 영상용 완성 기능으로 정식 앱에 병합하지 않습니다.** 영상 시청은 MR4 원본 경로로 돌아갈 수 있습니다. 이는 세 장치 영상 싱크 해결의 대체 성과가 아닙니다.

선택된 AirPlay 장치의 신원·상태를 `AVRouteDetector`로 얻는 API는 확인하지 못했습니다. `isExternalPlaybackActive`는 영상 외부 재생 플래그이므로 오디오 AirPlay 연결 판정으로 사용하지 않습니다. 장치 클록이 실제 로컬 장치와 일치할 때의 복귀만 명시적으로 검사했습니다.

Apple의 HLS 작성 지침은 로컬 HLS 서버 사용을 권장하지 않습니다. 루프백 브리지는 공개 API 타당성 실험이며, 안정적인 제품 구조로 인증된 방식이 아닙니다. 오디오는 메모리에서만 처리하며 서버는 127.0.0.1에만 열립니다.

## 실행 및 다음 결정

정식 `Vanille.app`과 실험 앱을 동시에 처리 상태로 두지 마세요. 정식 앱을 Pause한 뒤 실험 앱을 실행합니다. macOS 기본 출력은 MR4로 둡니다. 원본 앱에서 재생을 시작하고 **Live System Audio**, AirPlay 버튼에서 두 목적지, **Include MR4** 순서로 선택합니다. 종료하거나 **Use MR4 for Video**를 누르면 브리지를 중지합니다. 실험 앱의 원격 선택은 재시작 시 다시 필요할 수 있습니다.

다음 우선순위는 추가 EQ나 수동 지연 UI가 아니라 **원본 플레이어와 시간 기준을 공유할 수 있는 공개 경로**입니다. Apple DTS에 macOS의 다중 AirPlay와 외부 플레이어 A/V 동기화 지원 범위를 확인해야 합니다. 협력 가능한 플레이어 통합은 별도 범위이며, 원래 브라우저/DRM 플레이어를 유지하는 요구를 임의로 대체하지 않습니다.

근거: [공식 AirPlay 구현 안내](https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app), [플레이어 live offset](https://developer.apple.com/documentation/avfoundation/avplayeritem/configuredtimeoffsetfromlive), [네이티브 선택기의 player](https://developer.apple.com/documentation/avkit/avroutepickerview/player), [HLS 작성 지침](https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices/). 실제 관찰 수치는 `Tests/Results/AirPlay-*`에 있습니다.
