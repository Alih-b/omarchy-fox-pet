<div align="center">
  <img width="800" height="604" alt="folio" src="https://github.com/user-attachments/assets/ca0bd050-72f6-4384-b217-44354abc265c" />

  # Fox Pet

  A desktop companion plugin for **Omarchy** featuring **Folio** the fox.
</div>

---

**Fox Pet** (`fox-pet`) adds Folio, a desktop companion fox, to your Omarchy workspace. She wanders along the bottom of your screens, rests when you are inactive, wakes with smooth stretch transitions, and responds to mouse interactions and physics.

## Installation

Install via the Omarchy plugin manager:

```bash
omarchy plugin add https://github.com/Alih-b/omarchy-fox-pet --enable
```

Or link directly for local development:

```bash
mkdir -p ~/.config/omarchy/plugins
ln -s "$(pwd)" ~/.config/omarchy/plugins/fox-pet
omarchy plugin rescan
omarchy plugin enable fox-pet
```

To update to the latest release:

```bash
omarchy plugin update fox-pet
```

## Controls

You can summon or dismiss Folio using the **Fox Pet** status bar widget, or interact directly with her using the mouse:

| Input | Folio's Response |
|---|---|
| **Left-click** | Pokes Folio — she greets with an ear wag, or wakes gently from sleep |
| **Double-click** | Toggles sleep state — she curls into a loaf or stretches awake |
| **Scroll down** | Puts her to sleep |
| **Scroll up** | Prompts her to leap |
| **Click & drag** | Moves her across screens (she stays asleep if moved while resting) |
| **Fling** | Releasing during a fast drag tosses her horizontally with momentum |
| **Petting** | Stroking the cursor back and forth across her fur triggers a playful jump |
| **Right-click** | Centers her on the active display |

## Commands

Control Folio from scripts or your terminal via `omarchy-shell`:

<div align="center">
  <img width="800" height="604" alt="folio-jump" src="https://github.com/user-attachments/assets/76b877af-9641-4d07-8a92-815c29c4a65a" />
</div>

```bash
omarchy-shell fox-pet toggle       # summon or hide Folio
omarchy-shell fox-pet sleepToggle  # toggle sleep / wake
omarchy-shell fox-pet jump         # make Folio leap
omarchy-shell fox-pet reset        # center Folio on the active display
omarchy-shell fox-pet state        # query state (on/off, state, direction, frame)
```

## Frame atlas

Every sprite frame in `assets/spritesheet.webp` has a unique name in `assets/frame-names.json` — use these names (e.g. `sleep-deep-curl`, `turn-quarter-right`) when discussing animation or rendering issues.

A private viewer with every named frame, row metadata, and live cadence previews can be regenerated locally (output is gitignored):

```bash
python3 tools/build-frame-atlas.py
xdg-open scratch/frame-atlas.html
```
