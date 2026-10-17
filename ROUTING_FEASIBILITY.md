# Multi-Device Routing Feasibility

검사일: 2026-10-18 KST. 실제 Mac mini M4, macOS 27.0 (26A428), Core Audio 공개 API와 네이티브 검증 앱을 사용했습니다.

## 결론

**MR4 + 두 HomePod 페어의 시스템 전체 동시 출력은 현재 미해결입니다.** 현재 macOS 시스템 연결은 AirPlay HAL 출력 하나를 제공합니다. 유선 + 이 AirPlay 출력 하나의 Aggregate는 실제로 열리고 4개 출력 채널의 IO 콜백이 실행됩니다. 이것은 세 장치 그룹이나 실내 동기화 성공을 뜻하지 않습니다.

## 실제 관찰

| 검사 | 결과 | 의미 |
| --- | --- | --- |
| 미연결 상태의 HAL 장치 열거 | 유선/내장/디스플레이 등; HomePod 없음 | Bonjour 이름이 시스템 출력 장치가 되는 것은 아님 |
| AVPlayer 연결 AVRoutePickerView | HomePod 계열 목적지 둘을 동시에 선택 가능 | 이 플레이어만의 라우팅. 시스템 HAL 장치는 생성되지 않음 |
| 플레이어 없는 AVRoutePickerView | 시스템 다중 선택 경로를 확보하지 못함 | 제품의 시스템 AirPlay 선택기로 채택하지 않음 |
| 사용자가 제어 센터에서 HomePod 시스템 출력 연결 | 일반 이름 `AirPlay`, 2채널, 48kHz 장치 하나가 나타남 | 현재 연결 하나를 Core Audio에서 사용 가능 |
| AudioTransportManager / AirPlay AudioBox 조사 | 개별 HomePod를 여는 공개 endpoint가 나타나지 않음 | 공개 endpoint composition으로 두 번째 출력을 만들 근거 없음 |
| 유선 + AirPlay 비공개 Aggregate | 활성 하위 장치 2개, 출력 4채널 Float32/48kHz | 독립적인 스테레오 버퍼 2개 확보 |
| 실제 AudioDeviceStart | 성공, 3초에 297개 IO 콜백 | 실제 하드웨어 IO 실행. 이 검사는 무음을 썼음 |
| 종료/IOProc 해제/Aggregate 제거 | 모두 noErr | 검사 리소스 정상 정리 |
| AirPlay latency / safety offset | 둘 다 0 프레임 | 실제 스피커 지연 자동 산출에 사용할 수 없음 |

두 AirPlay 항목 중 하나는 시스템 UI에서 HomePod mini 스테레오 페어로 보였습니다. 다른 항목의 스테레오 페어 구성을 별도로 검증하지 않았습니다. 하드웨어 UID, 네트워크 이름, 사설 장치 식별자는 공개 저장소에 포함하지 않습니다.

## 공개 문서와 판단

Apple은 [Mac의 제어 센터에서는 여러 AirPlay 스피커로 동시 스트리밍할 수 없으며, Music 앱에서는 여러 스피커를 선택할 수 있다고 설명](https://support.apple.com/en-gb/105068)합니다. 이 제품의 시스템 오디오 요구와 앱 플레이어의 다중 출력은 범위가 다릅니다.

[Audio MIDI Setup의 Multi-Output Device](https://support.apple.com/guide/audio-midi-setup/play-audio-through-multiple-devices-at-once-ams7c093f372/mac)는 이미 장치 목록에 존재하는 출력을 결합합니다. 현재 목록에 없는 두 번째 HomePod 페어를 새 HAL 출력으로 제공하는 기능은 아닙니다. 사용자에게 이미 존재하던 Multi-Output Device는 수정하거나 제거하지 않았습니다.

[AVRoutePickerView.player](https://developer.apple.com/documentation/avkit/avroutepickerview/player)는 AVPlayer의 라우팅입니다. 테스트용 플레이어에서 두 목적지를 체크할 수 있었다는 사실만으로 Safari/Chrome/VLC 오디오가 모두 그 그룹으로 전달된다고 결론 내리지 않습니다.

이것은 모든 공개 API를 통한 구현의 수학적 불가능성을 증명한 결과는 아닙니다. **이번 환경과 작업 범위에서 지원되는 시스템 전체 다중 AirPlay 경로를 확보하지 못한 결과**입니다. 비공개 AVOutputContext/MediaRemote 또는 역공학 RAOP/AirPlay 구현으로 제한을 감추지 않습니다. AirPlay 프로토콜을 직접 구현하지 않았으므로 프로토콜 인증·라이선스 확보를 완료했다고 주장하지 않습니다.

## 남은 핵심 검증

Safari YouTube → MR4 → HomePod 페어 추가 → HomePod mini 페어 추가 → 세 출력의 독립 볼륨·지연·연결 해제 복구라는 요구 시나리오는 **미통과**입니다. 두 번째 독립 AirPlay endpoint와 실내 음향 측정이 먼저 필요합니다. 소프트웨어 Delay와 Aggregate의 Drift Compensation만으로 청취 위치에서 동기화되었다고 표시하지 않습니다.
