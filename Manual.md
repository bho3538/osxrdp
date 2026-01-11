## Installation and Initial Setup

1. Download the installer (.pkg) file from Releases and install it.
2. Using Finder, run the OSXRDP app from `Applications\osxrdp`.
3. Click the **Check** button next to **Permission Status**.
4. Click the **Refresh** button next to **Accessibility Permission** to grant Accessibility permission.
5. Click the **Refresh** button next to **Screen Record Permission** to grant screen recording permission.\
   If a “Quit and Relaunch” popup appears at this time, select **Later**.
6. Click the **Restart** button to restart the app.
7. If **Remote connection status** shows **running** as follows, remote access is enabled.
8. Use your macOS account name and password as the remote access account name and password.

## Uninstall

1. Using Finder, run the OSXRDPUninstaller app from `Applications\osxrdp`.
2. Click **Yes** to proceed with uninstallation.

## Other

* If you cannot connect from an external computer using an RDP client,\
  check whether the `3389/tcp` port is blocked by the firewall.\
  Using Terminal, check whether the xrdp and osxrdp processes are running.

* When attempting to connect, the following message appears:\
  (“OSXRDP agent does not running. Please check main agent is running.”)\
  Check that the account you are trying to connect to is logged in, and that the OSXRDP app is running in that account’s session.\
  The current version does not yet support connecting using an account that is not logged in. This will be improved in a future update.
