## Installation and Initial Setup

1. Download the installer (.pkg) file from Releases and install it.
2. Using Finder, run the OSXRDP app from `Applications\osxrdp`.\
   <img width="318" height="180" alt="" src="https://github.com/user-attachments/assets/1656a214-49b0-43fe-aede-951107fe5060" /> \
   After start it, Click followed icon at top status bar and select 'Open' \
   <img width="57" height="32" alt="" src="https://github.com/user-attachments/assets/921be3bd-ffd9-40d3-b9fc-e7fd22e5aa1e" />
4. Click the **Check** button next to **Permission Status**.
5. Click the **Refresh** button next to **Accessibility Permission** to grant Accessibility permission.
6. Click the **Refresh** button next to **Screen Record Permission** to grant screen recording permission.\
   If a “Quit and Relaunch” popup appears at this time, select **Later**.
7. Click the **Restart** button to restart the app.
8. If **Remote connection status** shows **running** as follows, remote access is enabled. \
   <img width="633" height="450" alt="" src="https://github.com/user-attachments/assets/b7bd3a0a-b699-4980-bb52-9f7422b8586b" />
10. Use your macOS account name and password as the remote access account name and password.

## Uninstall

1. Using Finder, run the OSXRDPUninstaller app from `Applications\osxrdp`.
2. Click **Yes** to proceed with uninstallation. \
   <img width="593" height="274" alt="" src="https://github.com/user-attachments/assets/a385fdee-a133-4a96-bff6-77266ed4e670" />

## Other
* You must disable sleep mode and turn off monitor feature for continuous remote access.

* If you cannot connect from an external computer using an RDP client,\
  check whether the `3389/tcp` port is blocked by the firewall.\
  Using Terminal, check whether the xrdp and osxrdp processes are running. \
  <img width="799" height="84" alt="" src="https://github.com/user-attachments/assets/fc97648e-0ff0-43f8-a0ae-4f9337ab386c" />

* When attempting to connect, the following message appears:\
  (“OSXRDP agent does not running. Please check main agent is running.”)\
  Check that the account you are trying to connect to is logged in, and that the OSXRDP app is running in that account’s session.\
  The current version does not yet support connecting using an account that is not logged in. This will be improved in a future update.
