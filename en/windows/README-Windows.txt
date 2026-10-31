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
   - The first time, you will be asked to allow it through the firewall.
     Allow it on "Private networks"
   - No window opens; it stays resident in the system tray with a "ワ" icon (the Japanese katakana "wa", from "ワンマン" = "one-man")
   - You can check your own ID from the right-click menu of the tray icon
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

■ Notes
- Communication has no authentication. This is a prototype for home LAN use only
- Text being composed in an IME is not passed correctly (typing in Latin characters is recommended)
