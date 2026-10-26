# Echo — Repetition Highlighter for macOS

*Working title. Spec version 0.6 — 2026-10-26. Personal-use tool for a single user.*

## 1. Summary

Echo is a lightweight macOS menu bar app that runs in the background and highlights, directly inside other apps, two things:

1. **Proximity repeats** — the same word used twice (or more) within a configurable number of words of itself.
2. **Watch-list words** — words or phrases the writer knows they overuse (e.g. *just*, *really*, *suddenly*, *began to*).

An **exclude list** (stop words like *the*, *a*, *is*) keeps common words from being flagged as proximity repeats.

Unlike Grammarly, Echo does no grammar, spelling, style rewriting or AI suggestions. It only points at repetition. All processing is local; no text ever leaves the machine.

## 2. Goals and non-goals

**Goals**
- Highlight repetition in real time, in the app the user is already writing in.
- Be simple to configure: one number (distance) and three word lists.
- Stay out of the way: no dock icon, low CPU, click-through highlights.
- Be fully private and offline.

**Non-goals (v1)**
- Grammar, spelling or style checking.
- Suggesting replacement words (OneLook thesaurus integration is planned for v2, see §12).
- Languages other than English.
- Windows, iOS or browser-extension versions.
- Distribution to other people: no App Store, notarization, licensing, or polished onboarding (see §9).
- Support for apps other than the three below, beyond whatever works for free.

## 3. User and target apps

Single user: an author drafting long-form prose. Built and run for personal use only.

Target apps for v1 — **Scrivener and Vellum** (about 95% of the user's writing). Word is deferred to a later version. Support below is from the compatibility spike (§11, milestone 0; results in `spike/results/`):

| App | Text technology | Expected support | Notes |
|---|---|---|---|
| **Scrivener** | Native AppKit (`NSTextView`) | **Verified** (3.5.2) | Full text, visible range and exact word bounds; ~10–20 ms per full refresh; value and resize notifications fire. Scrivenings view exposes all selected documents as **one** text area, so repeats across scene breaks are caught. Build against it first. |
| **Vellum** | Native AppKit | **Verified** (4.1.7) | Standard text area, same as Scrivener: exact bounds, ~20 ms refresh, value and selection notifications fire. Exposes **only the current chapter**, so analysis (and the long rare-word distances) is per chapter. |
| **Microsoft Word** | Custom rendering with its own Accessibility layer | **Deferred** (partly tested, 16.114.1) | Print Layout, 100%, page 1: whole-document text readable in ~2 ms and word bounds exact. But Word sends **no** change notifications (needs polling), and bounds lookups sometimes stall for ~1 s, apparently while Word is redrawing. Not tested: 150% zoom or later pages. Until then, use the Check Text window (§5.6). |

TextEdit is used as the development reference app (perfect Accessibility support) but isn't a target. All other apps are disabled by default.

## 4. Core concepts and definitions

### 4.1 Tokenization
- Text is split into words by a hand-written UTF-16 scanner: runs of letters with internal apostrophes or hyphens. (NSRegularExpression was ~15× slower on a full novel; `NLTokenizer` was not needed.) Ranges are UTF-16, matching Accessibility.
- Comparison is **case-insensitive** (`The` = `the`).
- Contractions are one token (`don't`). Possessives are normalized (`Sarah's` → `sarah`) — configurable.
- Hyphenated words are one token by default (`well-known`) — configurable.
- Numbers and URLs are ignored.

### 4.2 Matching mode
Setting: **Same root** (default) or **Exact**.
- *Exact*: `walk` and `walked` are different words.
- *Same root*: uses `NLTagger` lemmatization so `walk`, `walked`, `walking` count as the same word. Catches more real repetition, with some false positives (e.g. *left* → *leave*).
- Lemmas are looked up **one distinct word at a time and cached** (bare word, then inside a verb frame, then a noun frame). Tagging a whole novel in context took ~1.1 s; per-word lookup takes ~120 ms the first time and is free afterwards. Words with apostrophes or hyphens, and the ~5% the tagger can't place (mostly rare words and British spellings), are their own root.

### 4.3 Proximity distance (scaled by word rarity)
Rarer words are more noticeable to a reader, so they get a **longer** distance. Repeating *walked* within 50 words is fine; repeating *cerulean* within 1,000 words is not.

**Rarity source.** A bundled English word-frequency table (generated from the open `wordfreq` 3.1.1 dataset by `Echo/EchoEngine/tools/gen_zipf.py`: 168k words with Zipf ≥ 1.5, 2 MB) gives each word a **Zipf score** (log frequency: *the* 7.7, *walked* 4.7, *glanced* 3.2, *cerulean* 2.3, *crepuscular* 1.9). In *Same root* mode the lemma's score is used.

**Distance tiers** (defaults, all editable in Settings):

| Tier | Zipf score | Examples | Default distance |
|---|---|---|---|
| Very common | ≥ 5.5 | *the, said, was, know, very* | Most are on the exclude list; the rest use 15 words |
| Common | 4.5 – 5.5 | *walked, door, looked, back* | 40 words |
| Moderate | 3.0 – 4.5 | *glanced, countenance* | 150 words |
| Uncommon | 2.0 – 3.0 | *cerulean, gossamer, ephemeral, murmured* | 500 words |
| Rare / not in table | < 2.0 | *susurrus, crepuscular* | 1,500 words |

Thresholds were lowered from the first draft (5.5 / 4.5 / 3.5 / 2.5) after checking real wordfreq scores, so the example words land in the intended tiers. A word's score is the higher of its root's and its own.

- Settings expose one **"Rarity sensitivity" slider** that scales all tiers together (×0.5 to ×3), plus an Advanced table to edit each tier's threshold and distance.
- Any word can have a **manual distance override** (e.g. force *suddenly* to 2,000).
- Words not in the frequency table are treated as Rare — **except likely proper nouns** (see §4.7), which would otherwise flood the screen with character and place names.
- The hover popover shows the tier: *"'gossamer' (uncommon) repeated 312 words earlier — limit 500."*

**Distance counting rules:**
- Distance is counted in tokens between the two occurrences. **Excluded words still count toward distance** (they are still words the reader reads), they just aren't flagged themselves.
- Option: **Reset at paragraph / section break** (off by default). Useful if the user doesn't care about a repeat that spans a scene break.
- When a word appears 3+ times in a cluster (each within N of the next), the whole chain is highlighted as one group.

### 4.4 Word lists
| List | Purpose | Default contents |
|---|---|---|
| **Exclude list** | Never flagged as proximity repeats | ~150 English stop words (articles, pronouns, prepositions, auxiliaries, conjunctions) |
| **Watch list** | Always flagged, every occurrence, regardless of distance | Empty, with an optional starter pack (*just, really, very, suddenly, that, began to, started to, seemed, felt, realized, a bit, somehow*) |
| **Ignore list** (per-document, optional) | Words to skip in this document only, e.g. character names | Empty |

- Lists accept single words **and multi-word phrases** (`began to`, `in order to`).
- Optional **wildcards**: `*ly` to flag adverbs, `look*` to catch look/looked/looking.
- A word on the watch list takes priority over the exclude list. If a watched word is also a proximity repeat, only the watch highlight is drawn; the repeat still counts in the report.
- Exclude and ignore lists use single words (with wildcards); phrases only apply to the watch list. Phrase words must be separated only by spaces, so *began. To* doesn't match *began to*.
- In *Same root* mode an exact watch entry also catches other forms (*realize* flags *realized*).
- Lists can be imported/exported as plain `.txt` (one entry per line).

### 4.5 Watch-list thresholds (optional per word)
Each watch-list entry may have a threshold instead of always-on, e.g. *"flag `just` only if it appears more than 3 times per 1,000 words."* Default: always flag.

### 4.6 Analysis scope
Rare-word distances (up to 1,500 words) can exceed what's visible on screen, so the engine always analyzes the **whole text the app exposes** (in Scrivener that's usually the current document/scene, or the full Scrivenings view if several are shown together). Repeats that cross document boundaries in Scrivener aren't detected unless the documents are shown together in Scrivenings mode.

### 4.7 Proper nouns (character and place names)
Because unknown words get the longest distance, names would be flagged constantly. Default handling:
- A word **not in the frequency table that appears capitalized mid-sentence** (in at least one occurrence) is treated as a proper noun and **not flagged**.
- Being in the frequency table says nothing about names: wordfreq includes *elara* (1.4) and *sarah* (4.5). The engine uses capitalization only: a word is a name if **every** occurrence is capitalized and **at least one** is mid-sentence. Words only capitalized at sentence starts (*Suddenly*) and words also used in lowercase (*Hope* / *hope*) are still checked.
- `NLTagger` name tagging was dropped: ~0.85 s per novel, and the capitalization rule caught the names in testing (*Bingley, Darcy, Elizabeth* in *Pride and Prejudice*).
- A per-document **Ignore list** (§4.4) handles names the heuristic misses; one click from the hover popover adds them.
- Setting to turn this off.

## 5. Features

### 5.1 Menu bar app
- Runs as a background agent (`LSUIElement`): menu bar icon only, no Dock icon.
- Menu shows: on/off toggle, current app status ("Active in Scrivener" / "Not supported in this app"), counts for the current document (e.g. "12 repeats, 7 watch words"), Pause for 1 hour, Settings…, Check Text window…, Quit.
- Global hotkey to toggle highlighting (default ⌃⌥⌘E — ⌃⌥E clashes with Rectangle; configurable later).
- Launch at login (via `SMAppService`).

### 5.2 Highlighting
- Highlights are drawn in a transparent, click-through overlay window positioned over the text — the host app's text is never modified.
- Styles (configurable color per category):
  - Proximity repeats: amber wavy underline.
  - Watch-list words: blue underline.
  - Option: soft background highlight instead of underline.
- Highlights update after the user pauses typing (debounce ~300 ms) and when the window scrolls, moves, resizes, or focus changes.
- Only the **visible** portion of the document is drawn; the full document is analyzed so off-screen repeats still count.
- Highlights hide immediately when the text field loses focus, the app is hidden, or a secure (password) field is focused.

### 5.3 Hover details
Hovering a highlighted word (detected via a global mouse-move monitor, so the overlay stays click-through) shows a small popover:
- Why it's flagged: *"Repeated 18 words earlier"* or *"Watch list: 'just' (6× in this document)"*.
- Actions: **Show other occurrence** (briefly flashes it), **Ignore here**, **Add to exclude list**, **Ignore in this document**.

### 5.4 Per-app control
- Allow-list of apps by bundle ID. Default: Scrivener, Vellum, plus TextEdit for testing. Everything else is off; the user can add other apps to try them.
- Per-app override of the rarity sensitivity (optional, later).

### 5.5 Settings window (SwiftUI)
Tabs:
1. **General** — on/off, launch at login, hotkey, matching mode, rarity sensitivity slider + advanced tier table, per-word distance overrides, proper-noun handling, paragraph reset, highlight styles/colors.
2. **Watch list** — editable table: word/phrase, color (optional), threshold.
3. **Exclude list** — editable list, "Restore defaults", import/export.
4. **Apps** — enabled/disabled apps.
5. **Permissions** — Accessibility status with a button that opens System Settings › Privacy & Security › Accessibility.

### 5.6 Fallback: Check Text window
For cases where in-place highlighting doesn't work (most likely parts of Word): a standalone window where the user pastes text, or presses a hotkey that pulls the focused document's full text via Accessibility (falling back to select-all + copy), and sees the same highlights. Read-only; edits are made back in the original app. Also useful for checking a whole chapter at once. 

**Summary report panel** (side panel in the Check Text window):
- Top 25 most-repeated non-excluded words (grouped by root), with count and rarity tier.
- Watch-list words: count and rate per 1,000 words, with the threshold if set.
- Total proximity repeats by rarity tier.
- Clicking any row highlights and scrolls through its occurrences.
- "Copy report" as plain text.

### 5.7 First launch
Minimal, since it's personal use: if Accessibility permission is missing, show one window with a button that opens the right System Settings pane, and detect when it's granted.

## 6. Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Menu bar app (AppKit + SwiftUI)                           │
│                                                          │
│  FocusTracker ── AXObserver on frontmost app             │
│      │   (focus changed, value changed, selection         │
│      │    changed, window moved/resized; polling fallback)│
│      ▼                                                   │
│  TextReader ── reads AXValue (full text) and              │
│      │          AXVisibleCharacterRange                   │
│      ▼                                                   │
│  AnalysisEngine (pure Swift, no UI, unit-tested)          │
│      │   tokenize → normalize → find repeats + watch hits │
│      ▼   → [Match(range, kind, relatedRange, reason)]     │
│  GeometryResolver ── AXBoundsForRange for visible matches │
│      ▼                                                   │
│  OverlayController ── borderless, transparent,            │
│                       ignoresMouseEvents NSWindow per     │
│                       screen; draws underlines            │
│                                                          │
│  SettingsStore ── UserDefaults + JSON files for lists     │
└──────────────────────────────────────────────────────────┘
```

Key points:
- **Language/stack:** Swift 6, AppKit for the overlay and Accessibility, SwiftUI for Settings. Minimum macOS 14 (Sonoma).
- **Accessibility API** (`AXUIElement`) is the only way to read text and on-screen positions in other apps. Requires the user to grant Accessibility permission.
- **App adapters:** a small per-app adapter layer (`ScrivenerAdapter`, `VellumAdapter`, `GenericAdapter`; `WordAdapter` later) handles each app's quirks — which element holds the text, how to get the visible range, whether bounds need correcting for zoom, how to detect scrolling. Keeps app-specific hacks out of the core.
- **Rarity table:** bundled as a compact binary or SQLite resource, loaded once at launch into a dictionary.
- **AnalysisEngine** is a separate Swift package with no AppKit dependency, so it can be tested thoroughly and reused by the Check Text window.
- Analysis runs off the main thread; incremental re-analysis (only the edited paragraph ± N words) for large documents.

## 7. Performance targets
- Analysis of a 100,000-word document: < 150 ms; incremental update after a keystroke: < 20 ms.
- Idle CPU: ~0%. While typing: < 5% of one core.
- Memory: < 80 MB.
- Highlights should never lag the text by more than ~0.5 s after typing stops, and must never be drawn in the wrong place for more than one frame after scrolling (hide during scroll, redraw after).

## 8. Privacy and security
- No network access in v1 (no analytics, no update checks). The v2 OneLook integration (§12) adds network calls only when the user asks for synonyms, and sends only the single word (plus, if enabled, a few surrounding words).
- Document text is held in memory only, never written to disk or logs.
- Secure text fields (`AXSecureTextField`) are never read.
- Per-document ignore lists are keyed by a hash of the window title/document path, not by content.

## 9. Build and install (personal use)
- Built as a Swift package (`Echo/EchoApp`, depends on `Echo/EchoEngine`) by `Echo/EchoApp/build.sh`, which assembles and signs `build/Echo.app`; the package also opens in Xcode. Run from `/Applications` once Accessibility features arrive. Not sandboxed (Accessibility apps can't be).
- No paid Apple Developer account needed. Sign with a **stable** local identity (the free "Apple Development" certificate from a personal Apple ID). This matters: macOS ties the Accessibility permission to the code signature, so ad-hoc signing makes you re-grant the permission after every rebuild.
- No notarization, installer, auto-update, or licensing.

## 10. Known risks / limitations
- **Microsoft Word (deferred).** Spike findings are in §3. If picked up later: poll instead of waiting for notifications, run bounds lookups off the main thread with a timeout so a ~1 s stall never freezes Echo, and finish testing 150% zoom on a later page. Fallbacks: Check Text window with "sync from Word", or, as a last resort, Word's own scripting.
- **Overlay clipping (all apps).** Boxes for lines that are partly scrolled off spill over rulers, toolbars and footers. Clip highlights to the text view's enclosing scroll area.
- **Finding the editor.** Keyboard focus is often elsewhere (e.g. Scrivener's binder after selecting documents). Locate the main editor as the largest text area in the front window instead of relying on focus.
- **Positioning accuracy** generally depends on each app's Accessibility implementation; some return wrong or no bounds for text ranges.
- **Frequency table licensing:** the chosen word list must allow personal use (SUBTLEX and `wordfreq` both do).
- **Scrolling** isn't always reported by Accessibility notifications; needs a lightweight poll of visible range while the window is active.
- Very large documents in some apps return the full text slowly via AX; may need to read only the visible range ± buffer.
- Full-screen apps and multiple Spaces/monitors need the overlay window set to join all Spaces and handle each screen.

## 11. Milestones

0. ~~**Compatibility spike**~~ — **done 2026-10-26.** Tool in `spike/AXProbe`, reports in `spike/results/`. Scrivener (normal and Scrivenings view) and Vellum pass; Word deferred (§3).
1. ~~**Engine**~~ — **done 2026-10-26.** `Echo/EchoEngine` (Swift package, Swift 6). 29 tests (plus a benchmark), run with `Echo/EchoEngine/test.sh`. *Pride and Prejudice* (130k words): 80 ms per analysis, 235 ms the first time while root words are cached.
2. ~~**Check Text window**~~ — **first version done 2026-10-26.** `Echo/EchoApp`: menu bar app (⌘K opens the window). Paste or open .txt/.rtf/.docx/.html; orange underlines for repeats, blue for watch words, hover for the reason; Report tab (click a row to step through occurrences, Copy Report) and Tuning tab (live sliders, per-tier distances, watch/ignore/exclude lists, saved between launches). Not yet: the hotkey that pulls text from the front app (needs milestone 3's Accessibility code).
3. ~~**Overlay in Scrivener**~~ — **done 2026-10-26.** `LiveHighlighter` follows the frontmost app, finds the editor as the largest text area in the window, analyzes the whole text off the main thread, and draws visible matches in a click-through overlay sized to the editor's content area (rulers and scroll bars trimmed). Highlights shift with edits until re-analysis (300 ms debounce); scrolling is tracked via notifications, scroll-wheel events and a 0.1 s position poll. Hover bubble explains each mark. Install with `Echo/EchoApp/build.sh --install` (Accessibility granted to `/Applications/Echo.app`). User reported no issues in Scrivener.
4. ~~**Vellum**~~ — **done 2026-10-26.** Works as in Scrivener. Vellum's chapter header and toolbar float over the top of the scroll area, so each highlighted line is hit-tested (`AXUIElementCopyElementAtPosition`) and skipped unless the editor is what's showing there (~8 ms per redraw). Note: the pale blue/red underlines seen in both apps are macOS's own proofreading, not Echo.
5. ~~**Settings, menu bar, hover popover**~~ — **done 2026-10-26.** Settings window (⌘, from the menu): General (on/off, launch at login via `SMAppService`, highlight style, Accessibility status), Analysis (the Check Text tuning controls), Word Lists (watch list, exclude list, clear per-document ignores), Apps (toggle Scrivener/Vellum/TextEdit, add other apps). Menu: status line, on/off, Pause for 1 Hour / Resume Now, Check Text…, Settings…. Global hotkey ⌃⌥⌘E (Carbon `RegisterEventHotKey`; ⌃⌥E clashed with Rectangle). Hover bubble buttons: Show other (flashes the nearest other use, or selects it if off screen), Ignore here (this one highlight, until the document changes), Ignore in document (saved per Scrivener project / Vellum book / file, covers every form of the word), Exclude everywhere (adds the word and its root to the exclude list). Not yet: a configurable hotkey; per-word colors in the watch list.
6. ~~**Polish**~~ — **done 2026-10-26.** Measured with a 130k-word document (*Pride and Prejudice*, 763k characters) in TextEdit: reading the text 0.5 ms; analysis ~200–275 ms on a background thread, with 0.4 ms left on the main thread; a keystroke costs ~0.1 ms; redraws median 11 ms, max 27 ms. Changes: highlight list built off the main thread; redraws throttled to ~30/s (each one makes the host app answer Accessibility queries on its main thread); covered-line hit tests only near the top and bottom edges; a 150 ms budget per redraw and a 0.2 s Accessibility timeout so a busy host can't stall Echo (previously 1.3–1.5 s stalls when clicking into a huge document); adaptive polling (0.1 s while active, 0.5 s after 2 s idle) → idle CPU ~0.2%; editor tracking survives switching between windows of the same app. Also: "Check This ‹App› Document" (⇧⌘K in the menu) loads the current document into Check Text; the report shows words as written ("George", not the root "georg"). Launch at login is in Settings › General (not switched on by default). Rare/uncommon repeats are drawn boldest with a soft tint, common ones faintest (user request).

## 12. Future versions

### 12.1 OneLook thesaurus integration (v2, planned)
Goal: when a word is flagged, find a replacement quickly.

- **Level 1 — open in browser.** A "Look up on OneLook" button in the hover popover and a right-click/hotkey action open `https://onelook.com/thesaurus/?s=<word>` in the default browser. Trivial to build; could even ship in v1.
- **Level 2 — suggestions in the popover.** Show the top ~10 synonyms directly in the hover popover using the **Datamuse API** (`https://api.datamuse.com/words?ml=<word>`), the free, keyless API from the team behind OneLook that powers much of its thesaurus. Each suggestion shows its rarity tier (from Echo's own frequency table), so you can avoid swapping one rare word for another.
  - Optional **context-aware ranking**: pass the words immediately before and after (`lc` / `rc` parameters) so suggestions fit the sentence. Off by default for privacy.
  - Filter out suggestions that are already used nearby in the document (no point replacing one repeat with another).
  - Clicking a suggestion copies it to the clipboard. Replacing text directly in the host app (via Accessibility `AXSelectedText`) is possible in Scrivener and Vellum; decide after v1.
  - Cache results locally; respect Datamuse's usage limits (100k requests/day, far above personal use).
  - "More on OneLook…" link at the bottom of the list.
- Network access is opt-in via a Settings toggle; with it off, only Level 1 is available.

### 12.2 Other ideas
- Sentence-opening repetition (three sentences in a row starting with *She*).
- Repeated phrases / n-grams detected automatically, not just from the watch list.
- Per-project profiles (different lists per novel).
- Document-level report: most-used words, watch-word density over time.
- Microsoft Word support (spike findings in §3 and §10).
- Chrome extension for Google Docs.

## 13. Decisions

| Question | Decision |
|---|---|
| Target apps | Scrivener and Vellum (Word deferred) |
| Distance model | Scaled by word rarity (§4.3) |
| Audience | Personal use only |
| Character names | Auto-detected proper nouns ignored by default, plus per-document ignore list (§4.7) — *tentative* |
| Matching default | Same root (*walk* = *walked* = *walking*) |
| Word view | Print Layout (when Word is picked up) |
| Summary report | Yes, in the Check Text window (§5.6) |
| Language | English only |
| Thesaurus | OneLook integration in v2 (§12.1) |

## 14. Open questions

None blocking. Next step: run the compatibility spike (§11, milestone 0).
