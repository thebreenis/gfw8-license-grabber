# Install game receipts

GUI 1.9.0 includes **Install Receipts** in the main window beside Receipt Sharing. It is part of the same EXE. CLI 1.5.0 offers the workflow with **I** in its main menu.

1. Open **Install Receipts**, then choose **Choose Folder** or **Choose Archive**. No picker opens automatically. The folder picker uses the modern Windows browser with an address bar and navigation pane. It initially points to `%LOCALAPPDATA%\GFW8LicenseGrabber\Games`, the common receipt library used by single pulls, bulk downloads, imports and Sharing.
2. Choose a folder, ZIP, or 7z archive, then **Scan Receipts**. Folder scans search all subfolders. Archive scans read nested `pop.bin` entries without extracting their paths. The app matches receipt XML to supported games, verifies Microsoft signatures and signed 24-hour validity, removes a leading UTF-8 BOM in its private staged copy, and selects the newest valid receipt per game. Source files stay unchanged. Invalid, expired, unsupported and inaccessible items appear as skipped results.
3. Review the games and destinations. The checkbox is off by default, so the preview shows installed games only. Check it to add uninstalled games to the preview, or uncheck it to hide them again without rescanning. There is no popup. Its text is: “Include games that aren't currently installed. This will create receipt folders under your Windows profile.” CLI users retain their explicit Y/N choice.
4. Choose **Install Receipts**. CLI users explicitly confirm with Y. The app rechecks signatures, dates, staged hashes, current installation status and running games before writing.

Destinations belong to the current Windows user:

```text
%LOCALAPPDATA%\Packages\<catalogue package family>\LocalState\Microsoft.Xbox\pop.bin
```

Including an uninstalled game creates its receipt directory; it does not install or register the game. Windows may later replace package data during game installation.

Existing receipts are replaced directly, without backups. An identical receipt is reinstalled; a newer valid installed receipt is retained. Running games are skipped. No other game data is changed. Cancellation retains completed installations and stops before the next file. The private installation summary is under `%LOCALAPPDATA%\GFW8LicenseGrabber\ReceiptInstaller`.

Drive roots and Windows folders are blocked. Directory junctions, symbolic links and other reparse points are skipped or rejected, including destination ancestors. Archive paths never become destination paths: only receipt bytes are staged under generated names, and destinations are recomputed from the bundled catalogue. Input is limited to 1 MB per receipt, and XML DTD/entity resolution is disabled. Password-protected archives are not supported.

The app includes the unmodified 7-Zip Extra 26.06 x64 reader and its license; no separate installation is needed. The reader binary is hash-verified before use. See `backend/runtime/archive-tools/License.txt` and `README.txt` in the source package for licensing and source links.

Both subscreens use matching Metro window controls and omit credits and heading icons. Credits remain on the main screen. Sharing displays: “Your Xbox, Windows, and Microsoft Account credentials are never shared.”

Receipt installation is local; it does not renew receipts, use the full-scan cooldown, or advertise imported receipts as owned licenses.

