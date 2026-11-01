How to Use the OneManCursor Windows Peer
========================================

A small program that stays resident in the system tray, for extending
the Mac's cursor sharing (OneManCursor) to Windows as well. It assumes
OneManCursor is running on the Mac side.

■ What You Need
If you have the prebuilt OneManCursor.exe (OneManCursor-Windows.zip from Releases),
put the unzipped OneManCursor.exe in any folder and go on to "Launching."

To build from source, put OneManCursor.cs / build.bat / this document
in any folder on Windows.

■ Building (only when building from source)
Double-click build.bat and OneManCursor.exe is produced with the C#
compiler that ships with Windows.

■ Launching
Launch OneManCursor.exe.
   - If "Windows protected your PC" (Microsoft Defender SmartScreen) appears:
     Click "More info", then select "Run anyway"
   - The first time, you will be asked to allow it through the firewall.
     Allow it on "Private networks"
   - No window opens; it stays resident in the system tray with a "ワ" icon (the Japanese katakana "wa", from "ワンマン" = "one-man")
   - You can check your own ID from the right-click menu of the tray icon
   - Solo mode: right-click the tray icon → "Solo mode" (while on, cursor will not
     leave to other machines and arriving cursors are returned)
   - To view the log: right-click the tray icon → "Show Log"
   - To quit:         right-click the tray icon → "Exit"
   - Settings are saved in OneManCursor.ini in the same folder

■ Settings
Basically none are needed. The neighbor relationships (layout) decided on the Mac side
are distributed automatically and saved in OneManCursor.ini (you do not need
to edit the ini by hand).
* If an older FinderSwipePeer.ini exists, it is carried over automatically
  to OneManCursor.ini on first launch (the ID and settings keep working as they are)
* When updating, quit from the tray first, then overwrite the exe.
  If you replace the whole folder, the ini is reset and the machine's ID changes

■ Mac-Side Settings
- Open "Edit Layout…" in the Mac menu and this Windows machine (the name
  shown in the tray and the log) appears as a tile. Drag it into place to match
  your actual arrangement. Machines whose edges touch become "neighbors"
- The arrangement is distributed automatically to all machines (including this Windows machine).
  Merely opening the editor does not distribute it, so move one tile

■ Usage
- Push the cursor out past the edge of the neighboring Mac's screen and control moves to Windows
- Push out past the edge of the Windows screen toward a neighboring machine and control moves to that machine
- When Explorer is frontmost, swipe gestures (back/forward, etc.) work too

■ Security prompts (UAC) and administrator apps
- A normal-privilege app cannot send input to confirmation screens such as UAC (the secure
  desktop) or to apps running as administrator. Left alone, the sender's cursor would vanish and
  its keys would stop working, so when a prompt appears the cursor is handed back to the sender
  automatically (while the prompt is shown, incoming cursors are also sent back. Operate the prompt
  with this Windows machine's own mouse/keyboard; it returns to normal once the prompt closes)
- To type into administrator apps (such as BCUninstaller), right-click the tray icon and check
  "Run as administrator" (it then starts as administrator automatically from the next launch)
  * Input into the prompt screen itself is impossible even as administrator, due to a Windows restriction

■ Notes
- Communication has no authentication. This is a prototype for home LAN use only
- Text being composed in an IME is not passed correctly (typing in Latin characters is recommended)
