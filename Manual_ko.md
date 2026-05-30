## 설치 및 초기 설정
1. Release 에서 설치 파일 (.pkg) 파일을 다운로드 받아 설치하십시오.
2. Finder를 사용하여 '응용 프로그램\osxrdp' 경로의 OSXRDP 앱을 실행하십시오. \
   <img width="318" height="180" alt="" src="https://github.com/user-attachments/assets/9a616e9c-0867-4dce-bea3-c2762cf4ca1b" /> \
   상단 표시줄에 다음과 같은 아이콘을 클릭하여 'Open' 을 선택하십시오. \
   <img width="57" height="32" alt="" src="https://github.com/user-attachments/assets/32986ee7-c80a-4c9c-ae45-552cca2918f8" />
4. 'Permission Status' 옆의 'Check' 버튼을 누르십시오. \
   <img width="633" height="450" alt="" src="https://github.com/user-attachments/assets/79fb7110-7d3f-4859-bec1-1151e4e431b5" />
6. 'Accessibility Permission' 옆의 Refresh 버튼을 눌러 접근성 권한을 부여하십시오. \
   <img width="573" height="293" alt="" src="https://github.com/user-attachments/assets/bbf6e040-e59d-4058-9df0-73af3788778c" />
8. 'Screen Record Permission' 옆의 Refresh 버튼을 눌러 화면 녹화 권한을 부여하십시오. \
   이 때 '종료 후 다시시작' 팝업이 뜬 경우 '나중에' 를 선택하십시오. \
   <img width="573" height="293" alt="" src="https://github.com/user-attachments/assets/a3d9e3f6-edfc-4d09-8fc1-ca92bc8e8c11" />
10. 'Restart' 버튼을 눌러 앱을 다시 시작하십시오.
11. 다음과 같이 'Remote connection status' 가 running 으로 뜨면 원격 접속이 활성화된 상태입나디. \
    <img width="633" height="450" alt="" src="https://github.com/user-attachments/assets/19f94d60-3886-46d4-aeba-4f714a4e0084" />
13. 원격 접속 계정명과 암호는 macOS 계정명과 암호를 사용하십시오.

## 삭제
1. Finder를 사용하여 '응용 프로그램\osxrdp' 경로의 OSXRDPUninstaller 앱을 실행하십시오.
2. Yes 를 클릭하여 삭제를 진행합니다. \
   <img width="593" height="274" alt="" src="https://github.com/user-attachments/assets/23f023e8-26c6-4c63-9221-edfc97ff4b9d" />

## 가상 모니터 사용
osxrdp 1.3 버전부터 가상 모니터 기능을 지원합니다. 이 기능은 원격 제어 해상도를 호스트 컴퓨터의 모니터 해상도와 관계없이 클라이언트 크기와 동일하게 설정해 줍니다.\
가상 모니터 기능을 사용할 경우 클라이언트 해상도에 맞추어 호스트 컴퓨터의 화면이 제공됩니다. 따라서 우수한 화질로 호스트 컴퓨터를 제어할 수 있습니다.\
가상 모니터 기능을 사용할 경우 원격 세션이 접속중일 때 호스트 컴퓨터의 모니터가 비활성화됩니다. (ARD의 고성능 모드와 동일합니다.)\
<img width="1280" height="720" alt="osxrdp_virtdisp" src="https://github.com/user-attachments/assets/2f1559e9-07cb-4ddd-a998-4294a3b8f86d" />

가상 모니터 기능은 초기 접속 화면에서 'Session' 타입을 선택하여 활성화 할 수 있습니다.
<img width="800" height="500" alt="osxrdp_virtdis_sel" src="https://github.com/user-attachments/assets/ab953d4b-31de-4cab-bf7c-eeabd4bd1601" />
* osxup :
  가상 모니터를 활성화하여 원격 제어를 시작합니다.
* osxup (no virtual display) :
  가상 모니터를 사용하지 않고 원격 제어를 시작합니다. 가상모니터 사용 시 문제가 발생한 경우 사용하십시오.

## 파일 복사 사용
osxrdp 2.0.0 이후 버전부터 클라이언트 <---> 서버간 파일/폴더 복사를 지원합니다.

* 서버 (macOS) --> 클라이언트 파일 복사
  Windows host 에 접속한것과 동일합니다.\
  Finder 에서 파일/폴더 를 선택하여 복사 (control c) 한 후 클라이언트 컴퓨터의 탐색기 (explorer 등) 에서 붙혀넣기 (ctrl v) 하면 파일이 복사됩니다.
* 클라이언트 (mstsc 등) --> 서버 (macOS) 파일 복사
  다음과 같은 절차를 따라야 합니다.
  1. 클라이언트 컴퓨터에서 파일/폴더를 선택한 후 복사 (ctrl c) 하십시오.
  2. 서버 (macOS) 의 상단 메뉴에서 OSXRDP 앱을 선택합니다.
  3. '복사할 파일 저장'를 선택합니다.<img width="1366" height="800" alt="1" src="https://github.com/user-attachments/assets/85363408-7b64-4a3e-8f37-5227f702993b" />
  4. 파일을 저장할 폴더 경로를 선택합니다.<img width="1366" height="800" alt="2" src="https://github.com/user-attachments/assets/c4c9c62a-7d47-4e45-86db-ef37a9d4d6d1" />
  5. 다음과 같이 파일/폴더가 복사되는것을 확인할 수 있습니다.<img width="1366" height="800" alt="3" src="https://github.com/user-attachments/assets/988a260f-7656-4c58-aa1d-b0c0e869e1ac" />

## 기타
* 안정적이고 좋은 연결 품질을 유지하기위해 원격 대상 Mac을 유선 네트워크로 연결하십시오.\
  WI-FI 사용시 AWDL 간섭으로 인해 지연이 발생할 수 있습니다.\
  WI-FI AP 의 채널을 변경하거나 AWDL 을 비활성화 하십시오. 

* 지속적인 원격 접속을 위해 시스템 설정에서 '잠자기 (절전 모드)' 를 비활성화 하십시오.

* rdp 클라이언트를 사용하여 외부 컴퓨터에서 접속이 불가능한 경우\
  3389/tcp 포트가 방화벽에 의해 차단되어있는지 확인합니다.\
  터미널을 사용하여 xrdp 및 osxrdp 프로세스가 실행되어 있는지 확인합니다. \
  <img width="799" height="84" alt="" src="https://github.com/user-attachments/assets/ba128371-bed0-4cdc-af76-6c998f5a6406" />

* 접속 시도 시 다음과 같은 메시지가 뜹니다 ('OSXRDP agent does not running. Please check main agent is running.')\
  접속하려는 계정에서 OSXRDP 앱을 실행한 후 'Start on logon' 옵션을 활성화 해야 합니다.
