# Vanille

Swift와 AppKit으로 만든 macOS 메뉴 막대 오디오 컨트롤러입니다. macOS 15 이상, Apple Silicon을 대상으로 합니다. 드라이버, 관리자 권한, 웹 런타임, 외부 패키지가 필요하지 않습니다.

**현재 결과는 멀티 출력의 부분 구현입니다. MR4 + HomePod 페어 + HomePod mini 페어의 세 출력 동시 재생은 완료하지 못했습니다.** 이 Mac에서는 시스템에 연결한 AirPlay 출력 하나만 Core Audio 장치로 나타납니다. Apple Music/AVPlayer의 여러 AirPlay 선택을 시스템 전체 라우팅으로 표시하지 않습니다. 자세한 근거는 [ROUTING_FEASIBILITY.md](ROUTING_FEASIBILITY.md)에 있습니다.

## 실행

1. 제공된 `Vanille-macos-arm64.zip`을 압축 해제합니다. `Vanille.app`을 원하는 위치로 옮겨 실행합니다. 로그인 시 실행을 사용하려면 `/Applications`에 두는 편이 좋습니다.
2. 메뉴 막대의 스피커 아이콘을 클릭합니다. 첫 실행은 **Processing paused** 상태입니다.
3. HomePod를 사용할 때는 먼저 macOS **제어 센터 → 사운드**에서 해당 출력을 연결합니다. 앱의 **System Output** 목록에서 연결 여부를 확인합니다.
4. **Edit…**에서 그룹의 각 항목에 실제 장치를 배정합니다. MR4가 연결된 장치는 이 환경에서 `CalDigit TS4 Audio - Rear`입니다. `AirPlay`는 현재 macOS 시스템 연결 하나를 뜻합니다.
5. **Use Group**, **Start Processing**을 선택합니다. macOS가 시스템 오디오 녹음 접근을 요청하면 허용합니다. 이 앱은 오디오 파일을 녹음하거나 전송하지 않습니다.

배포 파일은 개발용 ad-hoc 서명입니다. Developer ID 서명과 공증은 되어 있지 않습니다. 다른 Mac에서는 Gatekeeper의 사용자 승인이 필요할 수 있습니다. 시스템 보안 기능을 끄지 마세요.

권한을 거부한 경우 원본 오디오가 유지됩니다. 다시 사용하려면 **시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음**에서 Vanille의 시스템 오디오 접근을 허용하고 **Pause / Start Processing**으로 재시도합니다. macOS 버전에 따라 항목 이름은 다를 수 있습니다.

## 출력 그룹

기본 그룹은 수정·이름 변경·삭제할 수 있습니다. 새 그룹과 출력 항목도 추가할 수 있습니다.

| 그룹 | 초기 구성 슬롯 | 현재 제한 |
| --- | --- | --- |
| Desktop | MR4 / 유선 | 연결된 유선 출력에 배정 가능 |
| HomePods | HomePod + HomePod mini | 두 개의 독립적인 AirPlay 시스템 출력이 없어 완성 불가 |
| Immersive | 유선 + HomePod | 유선 + 현재 연결된 AirPlay 하나로 구성 가능; 실내 동기화 미검증 |
| Full Room | 유선 + HomePod + HomePod mini | 두 번째 AirPlay 시스템 출력이 없어 완성 불가 |

연결되지 않거나 배정되지 않은 항목은 상태를 표시하고 볼륨 조작을 비활성화합니다. 동일한 장치를 두 번 배정할 수 없습니다. 그룹 이름이나 저장된 슬롯이 하드웨어의 연결 성공을 뜻하지 않습니다. 사용할 수 없는 항목은 건너뛰고 나머지 출력으로 처리하거나 원본 오디오를 유지합니다.

각 출력의 **Enable**, **Volume**, **Mute**는 실제 PCM 출력에 적용됩니다. **Additional Delay**는 해당 출력의 신호를 0–3000ms 늦춥니다. 빠른 유선 출력을 늦춰 느린 무선 출력에 맞추는 용도입니다. 자동으로 지연을 측정하는 기능은 없습니다. AirPlay 재연결·네트워크 변경 후에는 다시 맞춰야 할 수 있습니다. 이 기능은 스테레오 복제이며 서라운드가 아닙니다.

AirPlay의 일반적인 장치 이름과 연결별 UID만 제공되어 두 HomePod 페어의 신원을 자동으로 구분하지 못합니다. 재연결 후 그룹에서 장치를 다시 배정해야 할 수 있습니다.

## 앱별 볼륨과 EQ

재생 중인 앱을 식별하고 Chrome 등의 여러 Helper를 한 앱으로 묶습니다. 볼륨 0–100%, 음소거, 앱별 우회를 제공합니다. 처리 중인 앱에만 조작 가능한 앱 볼륨을 표시합니다. 앱 설정은 PID 대신 Bundle ID로 저장합니다. Bundle ID가 없는 활성 오디오 프로세스는 **Other System Audio**로 묶습니다.

10개 EQ 밴드, ±12dB, Preamp, Auto Headroom, 기본 프리셋 6개, 사용자 프리셋 저장·이름 변경·삭제를 제공합니다. 수직 밴드 슬라이더를 두 번 클릭하면 0dB로 돌아갑니다. EQ는 처리 중인 앱들의 혼합 신호에만 적용됩니다. 우회 앱과 다른 장치를 직접 사용하는 앱에는 적용되지 않습니다.

출력 그룹과 EQ가 서로 다른 개념입니다. 그룹의 선택이 EQ 프리셋을 강제로 바꾸지 않습니다. 기존 Desktop / Music / Cinema 프로필은 설정 창에서 출력·앱 볼륨·EQ를 저장하고 수정할 수 있습니다. 프로필은 현재 그룹 구성을 포함하지 않습니다.

## 원본 오디오 복구와 DRM

**Pause Audio Processing** 또는 **Restore Default Audio**를 선택하면 탭 리더와 사설 Aggregate를 중지하고 원래 시스템 출력으로 돌아갑니다. 시스템 기본 출력을 Vanille의 사설 장치로 바꾸는 구조가 아니므로 이 장치가 기본 출력으로 남지 않습니다.

앱별 `…` 메뉴의 **Protected Content Bypass**를 켜면 그 앱은 원래 출력 경로를 사용합니다. Music과 TV는 기본적으로 우회합니다. Netflix 등 보호 콘텐츠를 브라우저에서 볼 때는 해당 브라우저를 먼저 우회하세요. 우회한 오디오는 그룹 복제, 앱 볼륨, EQ의 대상에서 빠집니다.

DRM 감지나 우회 해제 기능은 없습니다. 영상 프레임을 캡처하지 않습니다. 처음부터 읽을 수 없는 소리는 원본 경로에 남깁니다. 이미 처리 중인 앱이 보호 재생으로 전환되는 상황을 자동 감지하지 못하므로 수동 우회가 필요합니다. Netflix, TV+, 보호된 Apple Music의 실제 재생은 검증하지 못했습니다.

## 개발 및 테스트

```sh
./Scripts/build.sh
./Scripts/test.sh
```

Command Line Tools만으로도 빌드할 수 있습니다. `Vanille.xcodeproj`의 공유 Vanille 스킴으로도 빌드합니다. 로컬 Mac에는 전체 Xcode가 없으며 Xcode 빌드는 GitHub의 macOS 15 / 26 ARM64 CI에서 검사합니다. 소스 목록 변경 시 `ruby Scripts/generate-project.rb`로 프로젝트를 갱신합니다.

실제 하드웨어 검증 도구:

```sh
./Scripts/build-test-tone.sh
VANILLE_DIAGNOSTICS=1 ./Scripts/build.sh
./Scripts/build-routing-lab.sh
```

Finder에서 진단 빌드를 실행한 뒤 `⌘T`는 앱 볼륨/EQ 검사, `⌘R`은 연결된 유선 + AirPlay 검사입니다. 개발용 테스트 톤은 매우 작은 신호를 사용하고 자동 종료합니다. `build/`의 결과에는 오디오 샘플이 없으며 수치만 저장합니다. 일반 배포 빌드에는 진단 메뉴가 없습니다.

완료·미완료 구분과 실제 측정 결과는 [TEST_REPORT.md](TEST_REPORT.md), 구조는 [ARCHITECTURE.md](ARCHITECTURE.md), 후속 우선순위는 [NEXT_STEPS.md](NEXT_STEPS.md)를 참고하세요.
