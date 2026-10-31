# How to Use OneManCursor

A menu bar app that bundles Finder swipe gestures, cursor sharing, and an always-visible cursor.
For more detail and troubleshooting, see [Manual.md](Manual.md).
The concept is "one driver drives every machine with a single cursor." While you hand control to another machine via cursor sharing, the always-visible cursor on the machine you handed off from is automatically hidden (so you never get a double cursor).

## What It Can Do

### Finder Swipe Gestures
These work only while the app is enabled and Finder is frontmost. System settings are not changed.

| Gesture | Action |
|---|---|
| Two-finger flick right (fast and large) | Back (⌘[) |
| Two-finger flick left | Forward (⌘]) |
| Three-finger swipe down | Go up one level (⌘↑) |
| Three-finger swipe up | Open (⌘O) |

### Cursor Sharing
Hand control to the neighboring machine at the edge of the screen. Discovery of and connection to other machines happen automatically. Set up the layout from the menu item "Edit Layout…" (see "Changing the Layout" below). Transfers use a direct TCP connection (port 45988; UDP 45987 is used only for discovery), which makes dropped keystrokes unlikely. While control is handed off, the cursor on the originating machine stays fixed at the point where it left. ⌘Esc is the emergency exit (it ends the session, and on the machine where you pressed it the cursor returns to the center of the screen). A plain Esc is sent to the other machine as an ordinary key.

On a machine used standalone, turn on "Solo mode" in the menu. The cursor then won't leave the screen edge for other machines, and any cursor that arrives is sent back, so you won't get lost at the screen edge.

### Changing the Layout (GUI Editor)

Open the menu item "Edit Layout…" and the machines it has discovered appear as tiles shaped like their screens.

- Drag the tiles to match your actual arrangement. **Machines whose edges touch become "neighbors"**
- When you change the arrangement, it is automatically distributed to all machines. **You only need to configure this one machine**; nothing is required on the child machines (including Windows)
- You can also offset tiles, for example by sliding one upward, so that only part of an edge overlaps. In that case, the cursor can pass only through the overlapping part
- Tiles that touch only at a corner are not connected. Overlap the edges at least slightly
- Arrangements like a triangle or a ring (where child machines are adjacent to each other) are also possible. The cursor can travel all the way around the ring back to where it started
- When "Snap" is on, tiles snap to the edges, top edges, bottom edges, and centers of other tiles. Turn it off when you want to place tiles freely
- While the editor is open, each tile shows a thumbnail of that machine's screen (updated with a delay of a few seconds). On a Mac, the "Screen Recording" permission is required (System Settings > Privacy & Security > Screen & System Audio Recording). Machines without the permission, or from which nothing has arrived, are shown as a plain color
- The circle at the top right of a tile changes that machine's "color." When you move the cursor close to an edge, the outline of the screen glows in the color of the destination machine. When two neighbors share the same edge, the point where the glowing color changes is the boundary
- Merely opening the editor does not distribute anything. As soon as you move even one tile (or change a color), the arrangement at that moment is distributed to all machines
- Pressing the "Make This Machine the Host" button makes only that machine able to distribute the layout (edits on other machines are not distributed). This prevents an old layout from overwriting the others and breaking every machine's neighbors. Press it on the machine you want to be the host. The host is shown in the window title
- The strip at the bottom is the holding area for unplaced machines. Moving a tile back to the strip removes it from the layout

### Screen Transition Settings

You can change the values in the menu item "Screen Transition Settings."

- **Edge push amount**: Control is not handed off by merely touching the edge; it is handed off when the amount you push outward reaches this value (px). Use this if the cursor flutters at the edge. "None" is the traditional behavior. It applies whenever the cursor leaves this machine (whether it is the originating machine or the holding machine)
- **Movement multiplier**: The multiplier applied to the movement the originating machine sends. Use it when you want the cursor to move faster or slower on the other machine's screen
- On Windows, only the push amount can be set, via `push=` (px) in the ini file. The multiplier is a setting on the originating (Mac) side

### Cursor Display
- "Always Show Cursor": Overlays a conspicuous cursor on top of the real cursor (shapes: arrow / circle / lookalike of the real cursor)
- "Cursor Display Settings…": Per-shape size, color, outline, blur, and opacity; tracking (lookahead, etc.); the ripple for a lone Command tap; and more
- It is hidden automatically while control is handed off via cursor sharing

## Getting Started

1. Get the app: download `OneManCursor.zip` from [Releases](https://github.com/riryo3/OneManCursor/releases) and unzip it. To build it yourself, run `sh build.sh` in the repository folder to produce `OneManCursor.app`
2. If you used the earlier standalone apps (FinderSwipe / AlwaysCursor), **quit them before** launching this one (running both makes gestures and cursor display conflict). Your settings (machine ID, layout, cursor shape and color, etc.) are carried over automatically on first launch
3. Permissions are required: in System Settings → Privacy & Security, allow "OneManCursor" under both **Device Control and Data Access** and **Input Monitoring** (the menu has items that open these)

## Notes

- The signaling (UDP) and cursor sharing (TCP) have no authentication. This is a prototype intended for use on a home LAN
- During cursor sharing, text being composed in an IME is not passed correctly to the other machine's screen (typing in Latin characters is recommended)

## Move the Cursor to a Dialog's Default Button

Turn on "Move Cursor to Dialog's Default Button" in the menu, and when a dialog or sheet appears, the cursor automatically moves to the center of the default button (such as "OK"). It works the same way as "Automatically move pointer to the default button in a dialog box" in the Windows mouse settings. It may not work in some apps. It does not operate during a cursor sharing session.

## Linked Search (Beta)

This feature is in beta. Searching with half-width alphanumeric characters is practical, but differences in each machine's search UI can cause variations, such as in how Esc behaves.

When "Linked Search" in the menu is on (the default), pressing ⌘+Space on any Mac opens Spotlight on the other Macs and Search (Win+S) on Windows. If you then start typing, the keys you type are sent as-is to all machines, and each machine reproduces the same keys in its own search field. Japanese input is not supported (the target is searching with half-width alphanumeric characters). Because results depend on each machine's IME settings (one of the reasons for the beta label), please align the IME state (such as alphanumeric input) on all machines. Pressing Enter presses Enter on each machine too, opening the top hit. Pressing Esc, clicking, or switching to another app closes the search on all machines. It does not trigger while the cursor is on another machine through cursor sharing (only while the cursor is on the originating Mac).

- Only a Mac can be the originator (Windows is the receiving side).
- The link ends automatically after 30 seconds.

## Mission Control / Task View Link

When "Mission Control / Task View Link" in the menu is on, opening Mission Control (Mac) or Task View (Win+Tab, Windows) on any machine opens the overview on the other machines too. ⌘+Tab (Mac) and Alt+Tab (Windows) are not linked. App Exposé (Ctrl+↓ / swipe down) is not linked either (the swipe down is used only to "confirm" while an overview is open). When you pick a window and confirm on any one machine (including closing with Esc), the overview on the remaining machines closes automatically. Nothing happens on machines that don't have an overview open. However, if you select the app or window that is already frontmost, or perform operations in rapid succession, processing may not keep up and the overview on other machines may stay open. Close it on that machine with Esc or similar.
