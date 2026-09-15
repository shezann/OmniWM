---
title: Tips
description: Mouse, trackpad, and workspace tricks that make OmniWM faster to drive.
sidebar:
  order: 6
---

## Pause tiling for a moment

Click the **Tiling** tile in the status bar menu, bind **Toggle Window Management** under **Settings > Hotkeys**, or run `omniwmctl command toggle-window-management`. Pausing hands every window back to macOS where it sits, brings windows parked for inactive workspaces back onto their monitor, and drops borders, tab rails, and the workspace bar; scratchpad windows stay hidden. While paused only the toggle shortcut and **Bring Focused Window Front and Center** stay registered, and the menu bar icon shows a pause glyph. Resuming re-applies the remembered layouts in one animation, snapping moved windows back and admitting anything you opened in between. The pause is never saved across relaunches.

## Find a lost window

Press **Option + Shift + F** (**Bring Focused Window Front and Center** under **Settings > Hotkeys**) or run `omniwmctl command bring-focused-window-front-and-center`. The window the frontmost app has focused is floated, sized to 70% of the monitor under the pointer, centered there, and raised on top, whether it was parked for an inactive workspace, tucked into a scratchpad, minimized, hidden with its app, or sitting on another monitor. Change the size, globally or per display, under **Settings > Monitors > Front and Center**. Press it again to put the window back: a tiled window rejoins the layout of the workspace it is on now, a floating window returns to its previous spot. It also works while tiling is paused, where the second press restores the previous frame.

## Name your workspaces

Create named workspaces in Settings to organize by project or context — emojis work too 🥳.

## Tame problem apps with rules

Use [App Rules](/features/app-rules/) to exclude problematic apps from tiling or assign them to specific workspaces.

## Swap windows by dragging

Hold the configured mouse-move modifier and drag a tiled window onto another to swap them; this works in both layouts. On Niri, add `Shift` to insert into a column instead. In Dwindle the drag swaps whole tiles, so a tab group moves with all of its members, the drop target is outlined while you hover it, releasing anywhere else changes nothing, and `Shift` has no effect. The modifier defaults to `Option` and can be changed or disabled in **Settings → Mouse & Trackpad**. In [Overview](/features/overview/), `Option + drag` targets a workspace, window position, or Niri column gap.

## Resize with a right-drag

Hold the configured right-mouse resize modifier (`Option` by default) and right-drag a tiled window to resize it in either layout.

## Scroll the strip with a mouse wheel

Hold `Option + Shift + Mouse Scroll Wheel` (default, configurable) to scroll along the active Niri primary axis: left/right in horizontal orientation or up/down in vertical orientation.

## Trackpad gestures

Use 2/3/4-finger gestures (configurable) along the active Niri primary axis; direction can be inverted (local hardware validation is limited).

The **Trackpad Scroll Style** picker in **Settings → Mouse & Trackpad** chooses how the strip responds:

- **Snap to Columns** (default) — the scroll snaps to the nearest column.
- **Momentum** — free inertial scrolling with rubber-band edges.

## Workspace swipe (opt-in)

Opt in under **Settings → Mouse & Trackpad**: swipe with a configurable finger count (2/3/4) and axis (horizontal/vertical) to switch to the next/previous workspace on the monitor under the cursor, one switch per swipe. Sharing the column-scroll finger count locks the axis to vertical. Workspace swipes have their own **Invert Direction (Natural)** toggle, independent of column scrolling: turn it off so swiping right goes to the next workspace and swiping left goes to the previous one. The **Swipe Distance** slider sets how far the fingers travel before the switch fires; a quick flick switches sooner.

:::caution[macOS gestures can intercept swipes]
With three or four fingers, macOS has its own swipe on the same axis: Mission Control for vertical swipes and **Swipe between full-screen applications** for horizontal ones. Turn on **Turn Off Conflicting macOS Gesture** in the Workspace Swipe section and OmniWM switches that macOS gesture off while workspace swipe is on and back on when it is off or OmniWM quits. Otherwise turn it off yourself in System Settings → Trackpad → More Gestures.
:::
