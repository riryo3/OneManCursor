# OneManCursor Manual

**Current release: v1.1.5 (Build 20261031-70)**

OneManCursor is an app that lives in the Mac menu bar. The name comes from the "one-man" train, which has a single driver, and the concept is "one driver for the cursor." From the trackpad and keyboard of a single Mac, you can drive the other Macs and Windows machines lined up next to it, just as if they were one.

The app combines three tools.

- **Cursor sharing**: Push the cursor out past the edge of the screen and control moves to the neighboring machine
- **Finder swipes**: While Finder is frontmost, use trackpad swipes for "Back / Forward / Up one level / Open"
- **Always-visible cursor**: Draws a conspicuous cursor on top of the cursor position (a countermeasure for when the real cursor becomes hard to see during remote operation)

It also has linked features that keep work across multiple machines in sync (Mission Control / Task View link, Linked Search) and thumbnail display in the layout editor.

---

## 1. System Requirements and Assumptions

- **Only a Mac can be the originator (the driver).** The Windows version is only for participants that "receive, return, and relay"
  - Moving between Windows machines, or starting control from Windows, is not possible
  - As long as you have one Mac, the rest can be Windows machines and you can move between them
- Supported OS: macOS 13 or later (developed and tested on macOS 27). On Windows, an environment with .NET Framework 4.x (normally included by default)
- All machines are assumed to be on the **same LAN (home network)**
- Communication has no authentication. It is built for use on a home LAN. Do not use it on networks outside your home
- Finger detection on the trackpad uses a private macOS framework (MultitouchSupport). It may stop working on future versions of macOS

## 2. Installation

### Mac

1. Download `OneManCursor.zip` from [Releases](https://github.com/riryo3/OneManCursor/releases), unzip it, and put `OneManCursor.app` in the Applications folder or elsewhere
2. On first launch, right-click → "Open" (because of how it is signed, a double-click may be blocked). If even right-click doesn't open it on a newer macOS, try to open it once, then click "Open Anyway" near the bottom of System Settings → Privacy & Security
3. Look for the "ワ" icon in the menu bar (the Japanese katakana "wa", from "ワンマン" = "one-man")
4. If you are migrating from the earlier standalone apps (FinderSwipe / AlwaysCursor), **quit them before** launching this one (running them at the same time causes conflicts). Your settings are carried over automatically on first launch

To build it yourself, run `sh build.sh` on a Mac with Xcode installed to produce `OneManCursor.app`. For the distribution version (signature replaced with an ad-hoc signature, and the icon restored to the standard one without a number), run `sh build.sh dist` to produce `dist/OneManCursor.zip`.

### Windows (the receiving side)

1. Download `OneManCursor-Windows.zip` from Releases and unzip it into a suitable folder (for example `C:\Users\<you>\OneManCursor`)
2. Launch `OneManCursor.exe` and a "ワ" icon (katakana "wa", from "ワンマン" = "one-man") stays resident in the system tray (it does not run twice; launching a second copy shows a notice and exits)
3. Settings are saved automatically to `OneManCursor.ini` in the same location as the exe. **When updating, quit from the tray first, then overwrite the files in the same folder.** If you replace the whole folder, the ini is reset and the machine's ID changes (which leaves stale tiles in the layout editor)

### Permission Setup (Mac)

After the first launch, in System Settings → Privacy & Security, grant this app the following permissions (the menu also has items that open them). You may need to restart the app right after granting a permission.

| Permission | Purpose | Required? |
|---|---|---|
| Device Control and Data Access (formerly Accessibility) | Relay key and mouse operations to other machines, and perform the operations received | Required |
| Input Monitoring | Read keyboard and trackpad input | Required |
| Screen & System Audio Recording | Show screen thumbnails on the layout editor tiles | Optional (for thumbnails) |

## 3. Using Cursor Sharing

### Basics

1. Launch the app on each machine (on a Mac, "Enabled" is on in the menu; on Windows, it stays in the tray)
2. Set up the arrangement in the layout editor (Chapter 6). You only need to do this on one Mac, and it is distributed to all machines automatically
3. Push the cursor out past the edge of the screen and control moves to the neighboring machine. Movement, clicks, scrolling, and key input happen on the other machine as they are
4. On the other machine's screen you can also push past an edge to relay further to the next machine, or return in the direction you came from. With a ring-shaped arrangement, you can go all the way around back to the starting point
5. While control is handed off, the cursor on the originating machine stays fixed at the point where it left, and the always-visible cursor also stops automatically (so you never get a double cursor)

**Operating tip: keep the originator to a single machine.** If several machines start handing off at the same time, they fight over the cursor.

### Emergency Exit

- **⌘Esc**: Ends the session wherever you are and takes the cursor back to your machine (works in any role: originator, holder, or relay). On the machine where you pressed it, the cursor moves to the center of the screen (to make it easy to find if you lost it; this works even when no session is active). A machine that receives the reset signal also returns its cursor to the center if it was in a session (so that a far-away machine can rescue an unresponsive machine with ⌘Esc)
- A plain Esc is not an emergency exit; it is sent to the other machine as an ordinary key

### Solo mode

On a machine with "Solo mode" turned on in the menu, cursor sharing handoffs are stopped.

- The cursor does not leave your screen edge for other machines
- If a cursor arrives from another machine, it is not accepted and is sent back
- If a session was active at the moment you turn it on, the cursor is returned to your machine first and then Solo mode begins

This keeps the cursor from getting lost at the screen edge when you use just one machine, or when the neighboring machine is powered off. The setting is per machine (on Windows, from the tray menu).

### Horizontal Swipes in Browsers (App Awareness)

Scrolling across a share arrives as raw wheel signals, so on its own the "swipe to go back/forward" in Chrome and similar browsers doesn't work. So when the other machine's frontmost app is a browser (Chrome / Safari / Edge / Firefox / Arc / Brave / Opera / Vivaldi), the originating side watches the finger movement itself and sends a two-finger horizontal push as "Back/Forward." Because detection is based on finger movement, the rebound after you lift your fingers (momentum scrolling) is never sent along. During the gesture, the scrolling itself is also not sent to the other machine, so the screen doesn't jerk sideways and history doesn't move twice. Vertical scrolling works as before. (The first implementation converted scroll signals on the receiving side, but it also converted the rebound, so it was changed to detection on the originating side.)

Swipes during sharing also adapt to the other machine's app. The holding Mac tells the originator what its frontmost app is, so when the other side is Finder, all swipes are sent; when it is a browser, only "Back/Forward" is sent. For any other app, nothing is sent (for example, sending "Open (⌘O)" to Chrome would bring up a file-open dialog). When the other side is Windows, the app is unknown, so everything is sent as before.

### Detailed Specifications

- Macs talk to each other over a direct TCP connection, and to Windows over UDP (directly to the other machine's IP). Discovery uses UDP broadcast
- If you leave the network and come back to the same LAN, it reconnects automatically (no app restart needed). However, if a session was active at the moment you left, the state may be out of sync, so reset with ⌘Esc
- Text being composed in an IME is not passed correctly to the other machine's screen (only confirmed text arrives). Latin-character input is the safer choice during sharing

## 4. Finder Swipes

They work only while the app is enabled and **Finder is frontmost**. The system's trackpad settings are not changed.

| Gesture | Action |
|---|---|
| Two-finger flick right (fast and large) | Back (⌘[) |
| Two-finger flick left | Forward (⌘]) |
| Three-finger swipe down | Go up one level (⌘↑) |
| Three-finger swipe up | Open (⌘O) |

During a cursor sharing session (when control is on another machine), the same swipe gestures work on that machine. On Windows, swipe gestures such as back/forward work while Explorer is frontmost.

## 5. Always-Visible Cursor

- Turn on "Always Show Cursor" in the menu and a conspicuous cursor is drawn on top of the real cursor
- When you set the shape to "lookalike of the real cursor," the real cursor's shape (I-beam, pointing hand, etc.) is drawn enlarged as is. In this case color, outline thickness, and blur have no effect, so those items can't be operated in the settings window (size and opacity do take effect)
- In "Cursor Display Settings…" you can adjust the shape (arrow / circle / lookalike of the real cursor), size, color, outline, blur, opacity, how it tracks, the ripple for a lone Command tap, and more. You can also save profiles and export/import JSON
- There is also a setting to hide it while Mission Control is open (detection is an estimate, so it may not work in some environments)
- While control is handed off to another machine via cursor sharing, the display stops automatically

## 6. Layout Editor

Open the menu item "Edit Layout…" and the machines it has discovered appear as tiles shaped like their screens.

- **Arrangement**: Drag the tiles to match your actual arrangement. **Machines whose edges touch become "neighbors"**
- You can also use arrangements where only part of an edge overlaps (offset arrangements). In that case, the cursor can pass only through the overlapping part
- At corners where several machines meet (T-junctions and crossings), a small gap (2% of the edge on each side) is opened automatically on both sides, and the cursor cannot cross within that range. This prevents the cursor from going missing in a fight over the corner
- Tiles that touch only at a corner are not connected. Overlap the edges at least slightly
- Arrangements like a triangle or a ring (where child machines are adjacent to each other) are also possible
- When "Snap" is on, tiles snap to the edges, top edges, bottom edges, and center lines of other tiles
- **Distribution**: Merely opening the editor does not distribute anything. As soon as you move even one tile (or change a color), the arrangement at that moment is distributed to all machines. Only one Mac needs to be configured; nothing is required on the other machines (including Windows)
- **Host**: Only the machine on which you pressed the "Make This Machine the Host" button can distribute the layout. Edits on other machines are no longer distributed, which prevents the accident where "an old layout overwrites a new one and breaks every machine's neighbors." The host is shown in the window title
- **Color**: The circle at the top right of a tile changes that machine's color. When you move the cursor close to any destination (an edge with a link), the passable section of every edge glows at once, each in the color of its destination machine (the whole screen outline does not glow in just the color of the nearest destination). When two neighbors share the same edge, the point where the glowing color changes is the boundary (on Windows too, it glows the same way while it holds the cursor). The ends of each glowing section have a small margin so that adjacent colors don't blend
- **Identify on screen**: Pressing the button makes every machine's screen glow faintly in its own color. Use it when you can't tell which tile is which physical machine
- **Thumbnails**: While the editor is open, a reduced image of each machine's screen is shown on its tile (updated with a delay of a few seconds; capture stops when you close it). On a Mac the "Screen Recording" permission is required. Machines without the permission, or from which nothing has arrived, are shown as a plain color
- The strip at the bottom is the holding area for unplaced machines. Moving a tile back to the strip removes it from the layout. If you reinstall on the other machine and its ID changes, move the old tile (shown as "No response") back to the strip and place the new tile again

## 7. Mission Control / Task View Link

When the menu item "Mission Control / Task View Link" is on (the default), the overview display of Mission Control (Mac) and Task View (Windows) is kept in sync across all machines. The cursor does not move.

- **What triggers opening**: The operations that open Mission Control (Ctrl+↑, four-finger swipe up) / Win+Tab on Windows
- **Other machines** open their own overview when they receive the signal
- **What counts as confirming (closing)**: Switching apps in the overview / Esc / swipe down while switching / pressing Ctrl+↑ again (toggle) / 60-second timeout (in this case no signal is sent and only that machine's own overview is released)
- **Not covered**: ⌘+Tab and Alt+Tab (app switching is a local operation on each machine), App Exposé (the version opened with Ctrl+↓ and swipe down), the F3 key (the overview opens on the machine where it was pressed, but it cannot be detected so it is not linked)
- **Limitations**:
  - If you select "the window of the app that is frontmost right now" in the overview (selecting the same app or the same window), no app switch occurs, so the confirmation is not conveyed to the other machines. Mission Control / Task View on other machines may stay open
  - If you operate Mission Control in rapid succession (opening and closing quickly over and over), processing may not keep up and the overview on other machines may stay open
  - When that happens, close it on that machine with Esc, swipe down, or the Ctrl+↑ toggle

## 8. Linked Search (Beta)

This feature is in beta. Searching with half-width alphanumeric characters is practical, but differences in each machine's search UI (for example, in Spotlight the first Esc clears the text and the second closes it) can make behavior inconsistent.

When the menu item "Linked Search" is on (the default), pressing ⌘+Space on any Mac opens Spotlight on the other Macs and Search (Win+S) on Windows.

- What is sent is the keys you type, as they are. Each machine reproduces the same keys in its own search field
- Japanese input is not supported. Linked Search targets searching with half-width alphanumeric characters
- Results depend on each machine's IME (input method) settings. This is one of the reasons it is a beta. Align the IME state (for example, set it to alphanumeric input) on all machines
- Pressing Enter presses Enter on each machine too, opening the top hit. Esc (except when it only cancels composition) or switching to another app closes the search on all machines
- Only a Mac can be the originator (Windows is the receiving side)
- The link ends automatically after 30 seconds
- It does not trigger while the cursor is on another machine through cursor sharing (only while the cursor is on the originating Mac)

## 9. Dialog Default Button

Turn on the menu item "Move Cursor to Dialog's Default Button" (off by default), and when a dialog or sheet appears, the cursor automatically moves to the center of the default button (such as "OK"). It works the same way as "Automatically move pointer to the default button in a dialog box" in the Windows mouse settings.

- It may not work in some apps
- It does not operate during a cursor sharing session
- On Windows the OS's own setting can do the same thing, so it is not included in this app

## 10. Screen Transition Settings

You can change the values in the menu item "Screen Transition Settings."

- **Edge push amount** (None / 10 / 20 / 40 / 80 px): Control is not handed off by merely touching the edge; it is handed off when the amount you push outward reaches this value. Use this if the cursor flutters at the edge. "None" is the default. It applies to every movement that leaves this machine
- **Movement multiplier** (0.50 to 2.00×): The multiplier applied to the movement the originating machine sends. Use it when you want the cursor to move faster or slower on the other machine's screen. Fractional remainders of slow movements are carried over, so they are not lost
- On Windows, only the push amount can be set, via `push=` (px) in the ini file. The multiplier is handled on the originating (Mac) side

## 11. Overview of Menu Items (Mac)

Open it from the "ワ" icon in the menu bar. At the top it shows the build number (for example, Build 20261031-70) and "Cursor: …" (which machine the cursor is on right now).

- Enabled (turns swipes, signal sending/receiving, and cursor sharing on/off all together)
- Remote Operation Mode (enables swipes even over remote sessions such as Moonlight)
- Move Cursor to Dialog's Default Button
- Mission Control / Task View Link
- Linked Search
- Solo mode
- Edit Layout…
- Screen Transition Settings (push amount, multiplier)
- Always Show Cursor / Cursor Shape / Cursor Display Settings… (the various settings for the always-visible cursor)
- Launch at Login
- Restart (relaunches the app when something is wrong; it is above Quit)
- Show Log (a record of communication and detection; useful for narrowing down problems)
- Show Detailed Status (last detection / number of trackpad frames received and the maximum number of fingers / received count; normally hidden)
- Items that open the permissions for Device Control and Data Access / Screen & System Audio Recording / Input Monitoring

On Windows, the tray menu has your own ID and build number, the cursor's current location, Solo mode, Show Log, and Quit.

## 12. Where Settings and Data Are Stored

- **Mac**: Settings are stored in the app's UserDefaults (`local.onemancursor`). This includes the machine ID, layout, colors, and the various toggles
- **Windows**: `OneManCursor.ini` in the same location as the exe
  - `name=` display name (the computer name if empty) / `id=` machine ID (generated automatically)
  - `links=` neighbor information (updated automatically by layout distribution; you don't need to write it by hand)
  - `push=` edge push amount (px) / `colors=` machine colors (used for the edge border display) / `solo=` Solo mode (1 = on)
- **Log**: On a Mac, in addition to "Show Log" within the app, it is also written to `~/Documents/cursor-log.txt` (rotated at 1 MB). On Windows, "Show Log" in the tray (the most recent 300 lines)

## 13. Troubleshooting

### Swipes don't work at all (but keys do)

The registration of the trackpad's finger data may be stuck. Turn on "Show Detailed Status" in the menu and look at "Received: N frames / max M fingers." If **the frames keep increasing but the max stays at 1**, that is the cause.

- The app re-registers automatically on wake from sleep and when it detects "only one finger has been read for a whole minute" (the log records "re-registered finger data")
- If that doesn't fix it, restart the app

### The cursor won't come back or stopped moving

- Reset the session with **⌘Esc**
- Check that all machines are on the same version (the build number at the top of the menu; development builds also show the number at the bottom right of the app icon. The distribution icon has no number as standard)
- Also check whether **an old copy of the app is left over**. If an old `OneManCursor.app` exists in a different folder, the old one may be the one still running, leaving you in a "I fixed it but nothing changed" state. Quit everything, confirm the "ワ" in the menu bar is gone, and then launch only the one you want to use. On Windows too, check whether an old version left in the tray is still running

### It no longer passes to the neighbor, or the arrangement is wrong

An old layout may have been redistributed and broken things. Open the layout editor on the Mac you want as the host, **move a tile slightly**, and redistribute the correct arrangement. Merely opening it does not distribute anything.

### With the Mission Control link, the overview on other machines doesn't close

If what you selected was "the window of the app that is frontmost right now," or you operated Mission Control in rapid succession, the confirmation isn't conveyed and the overview stays open (the limitation in Chapter 7). Close it with Esc, swipe down, or the Ctrl+↑ toggle. If it happens repeatedly, "Show Log" can help narrow it down by showing whether a record of an unconfirmed selection remains.

### Thumbnails don't appear

- Check that the "Screen Recording" permission is granted on that Mac (you may need to restart the app right after granting it)
- Capture happens only while the layout editor is open. Open it and wait a few seconds
- If capture fails, the log records "thumbnail capture failed"

### After being away from the network

It reconnects automatically once you are back on the same LAN. No restart is needed. If a session was active, reset it once with ⌘Esc.

## 14. Known Limitations

- Only a Mac can be the originator. Windows-to-Windows and Windows-originated control are not possible
- Communication has no authentication (assumes a home LAN)
- Text being composed in an IME is not passed to other machines
- Mission Control / Task View link: a confirmation made by selecting a window of the same app is not conveyed / with rapid successive operations, processing may not keep up and the overview on other machines may remain / F3 is not linked (by design)
- Swipe detection can miss depending on how your fingers touch (fewer fingers read than used, movement falling slightly short of the threshold, etc.)
- The "Hide During Mission Control" detection for the always-visible cursor is an estimate and may not work in some environments

## 15. About Versions

- Versions are written as "Build date-sequence number" (for example, Build 20261031-70). The sequence number goes up every time a feature changes. We recommend aligning the version on all machines, but because the signals are compatible, the basic features work even if versions differ
- **This manual covers v1.1.5 (Build 20261031-70)**
- Distribution packages (Releases) are ad-hoc signed and use the standard icon (no number). A development build you make for yourself has the sequence number at the bottom right of the icon

---

When in trouble, start with "Show Log" and Chapter 13 of this manual.
