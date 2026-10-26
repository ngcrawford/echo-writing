# Compatibility spike (SPEC.md §11, milestone 0)

`AXProbe/axprobe` checks whether Echo can read text and locate words on screen in a given app.

## Setup (once)
1. System Settings › Privacy & Security › Accessibility → enable your terminal app (Terminal, iTerm, or whichever runs Claude Code).
2. Build: `AXProbe/build.sh`

## Running a test
```
cd spike/AXProbe
./axprobe --delay 5 --live 20 --screenshot --out ../results
```
1. Within 5 seconds, switch to the target app and **click inside the document text** (use a document with a few pages of real prose).
2. The report prints, then red boxes appear over each visible word for 20 seconds.
3. During those 20 seconds: **scroll, type a few words, and resize the window.** Watch whether the boxes stay on the words.
4. The report is saved to `spike/results/`.

`--screenshot` needs Screen Recording permission for the terminal; skip it if you'd rather not grant that. `--enhanced` sets extra Accessibility flags some apps need — try it if a run finds no text.

## Test matrix
| # | App | Condition |
|---|---|---|
| 1 | TextEdit | baseline (should be perfect) |
| 2 | Scrivener | normal editor |
| 3 | Scrivener | Scrivenings view (several documents together) |
| 4 | Vellum | chapter text editor |
| 5 | Word | Print Layout, 100% zoom, page 1 |
| 6 | Word | Print Layout, 150% zoom, a later page |

For each run note: did boxes line up? did they follow scrolling and typing?
