## 설치 및 초기 설정
1. Release 에서 설치 파일 (.pkg) 파일을 다운로드 받아 설치하십시오.
2. Finder를 사용하여 '응용 프로그램\osxrdp' 경로의 OSXRDP 앱을 실행하십시오.
3. 'Permission Status' 옆의 'Check' 버튼을 누르십시오.
4. 'Accessibility Permission' 옆의 Refresh 버튼을 눌러 접근성 권한을 부여하십시오.
5. 'Screen Record Permission' 옆의 Refresh 버튼을 눌러 화면 녹화 권한을 부여하십시오.\이 때 '종료 후 다시시작' 팝업이 뜬 경우 '나중에' 를 선택하십시오.
6. 'Restart' 버튼을 눌러 앱을 다시 시작하십시오.
7. 다음과 같이 'Remote connection status' 가 running 으로 뜨면 원격 접속이 활성화된 상태입나디.
8. 원격 접속 계정명과 암호는 macOS 계정명과 암호를 사용하십시오.

## 삭제
1. Finder를 사용하여 '응용 프로그램\osxrdp' 경로의 OSXRDPUninstaller 앱을 실행하십시오.
2. Yes 를 클릭하여 삭제를 진행합니다.

## 기타
* rdp 클라이언트를 사용하여 외부 컴퓨터에서 접속이 불가능한 경우\
  3389/tcp 포트가 방화벽에 의해 차단되어있는지 확인합니다.\
  터미널을 사용하여 xrdp 및 osxrdp 프로세스가 실행되어 있는지 확인합니다.

* 접속 시도 시 다음과 같은 메시지가 뜹니다 ('OSXRDP agent does not running. Please check main agent is running.')\
  접속하려는 계정이 '로그온' 되어있고, 해당 계정의 세션에 OSXRDP 앱이 실행중인지 확인합니다.\
  지금 버전은 아직 '로그온' 되지 않은 계정을 사용하여 접속하는 기능을 지원하지 않습니다. 이는 추후 개선될 예정입니다
