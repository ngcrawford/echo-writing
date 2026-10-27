# Echo — Repetition Highlighter for macOS

*Spec version 1.0 (as built) — 2026-10-26. Describes Echo 0.1 as released. Where the build differs from the original plan, the plan is noted as "Planned, not built" or "Changed".*

## 1. Summary

Echo is a lightweight macOS menu bar app that runs in the background and highlights two things directly inside **Scrivener** and **Vellum**:

1. **Proximity repeats.** The same word is used twice (or more) within a set number of words. The number grows with how rare the word is.
2. **Watch-list words.** These are words or phrases the writer knows they overuse (e.g. *just*, *suddenly*, *began to*).

An **exclude list** of stop words (*the*, *a*, *is*) keeps common words from being flagged as repeats.

Echo does no grammar, spelling, style rewriting or AI suggestions. It only points at repetition. All processing is local, and no text ever leaves the machine.

## 2. Goals and non-goals

**Goals (all met in 0.1)**
- Highlight repetition in real time, in the app the user is already writing in.
- Be simple to configure: one sensitivity slider, five tier distances and three word lists.
- Stay out of the way: no Dock icon, idle CPU ~0.2%, click-through highlights.
- Be fully private and offline.

**Non-goals (v1)**
- Grammar, spelling or style checking.
- Suggesting replacement words. OneLook integration is planned for v2 (§12).
- Languages other than English.
- Windows, iOS or browser-extension versions.
- In-place highlighting in apps other than Scrivener and Vellum, beyond whatever works for free.

**Changed:** distribution was originally a non-goal. Echo is now published as a public GitHub release with a DMG (§9). It isn't notarized yet.

## 3. User and target apps

The primary user is an author drafting long-form prose. Echo was built for personal use and is now also shared publicly.

The v1 target apps are **Scrivener and Vellum**, which cover about 95% of the user's writing. Word is deferred. Support was measured by the compatibility spike (§11, milestone 0) and confirmed by daily use:

| App | Text technology | Support | Notes |
|---|---|---|---|
| **Scrivener** | Native AppKit (`NSTextView`) | **Works** (3.5.2) | Full text, visible range and exact word bounds are available. Scrivenings view exposes all selected documents as **one** text area, so repeats across scene breaks are caught. The ruler sits inside the scroll area and is trimmed from the overlay. The user reported no issues. |
| **Vellum** | Native AppKit | **Works** (4.1.7) | Standard text area. It exposes **only the current chapter**, so analysis is per chapter. The chapter header and toolbar float over the top of the editor, so highlighted lines there are hit-tested and skipped when covered. |
| **Microsoft Word** | Custom rendering with its own Accessibility layer | **Deferred** (partly tested, 16.114.1) | Whole-document text and word bounds are readable. But Word sends **no** change notifications, and bounds lookups sometimes stall for ~1 s. For now, use Check Text (§5.6), which opens .docx files. |

**TextEdit** is enabled by default for trying Echo out and was the development reference app. Other apps can be added in Settings › Apps, where they work if they use standard Mac text views.

## 4. Core concepts and definitions

### 4.1 Tokenization
- A hand-written UTF-16 scanner splits text into words: runs of letters with internal apostrophes or hyphens. NSRegularExpression was ~15× slower on a full novel. Ranges are UTF-16, matching Accessibility.
- Comparison is **case-insensitive**.
- Contractions are one token (`don't`).
- Possessives are normalized (`Sarah's` → `sarah`). This can be turned off in Settings › Analysis ("Sarah's counts as Sarah").
- Hyphenated words are one token by default (`well-known`). This can be changed in Settings › Analysis ("Split hyphenated words").
- Numbers are ignored.

### 4.2 Matching mode
The setting is **Same root** (the default) or **Exact word**.
- *Exact word*: `walk` and `walked` are different words.
- *Same root*: `NLTagger` lemmatization makes `walk`, `walked` and `walking` the same word. It catches more real repetition, with some false positives (e.g. *left* → *leave*).
- Lemmas are looked up **one distinct word at a time and cached**: first the bare word, then the word inside a verb frame, then inside a noun frame.
  - Tagging a whole novel in context took ~1.1 s. Per-word lookup takes ~120 ms the first time and is free afterwards.
  - Each of these words counts as its own root: words with apostrophes or hyphens, and the ~5% the tagger can't place (mostly rare words and British spellings).

### 4.3 Proximity distance (scaled by word rarity)
Rarer words are more noticeable to a reader, so they get a **longer** distance. Repeating *walked* within 50 words is fine. Repeating *cerulean* within 500 words is not.

**Rarity source.** A bundled table gives each word a **Zipf score** (log frequency): *the* 7.7, *walked* 4.7, *glanced* 3.2, *cerulean* 2.3, *crepuscular* 1.9.
- The table is `EchoEngine/Resources/zipf-en.tsv`: 168k words with Zipf ≥ 1.5, about 2 MB, loaded once at launch.
- It is generated from `wordfreq` 3.1.1 (CC BY-SA 4.0) by `Echo/EchoEngine/tools/gen_zipf.py`.
- A word's score is the higher of its root's score and its own.

**Distance tiers** (defaults):

| Tier | Zipf score | Examples | Default distance |
|---|---|---|---|
| Very common | ≥ 5.5 | *the, said, know* | Most are on the exclude list; the rest use 15 words |
| Common | 4.5 – 5.5 | *walked, door* | 40 words |
| Moderate | 3.0 – 4.5 | *glanced, shoulder* | 150 words |
| Uncommon | 2.0 – 3.0 | *cerulean, gossamer* | 500 words |
| Rare / not in table | < 2.0 | *susurrus, crepuscular* | 1,500 words |

- Settings › Analysis has a **Rarity sensitivity** slider (×0.5 to ×3, in steps of 0.25) that scales all distances together. Each tier's distance is also editable, and the row shows the scaled value when the slider isn't at ×1.
- **Planned, not built:** editing the Zipf thresholds in the UI. They're fixed at the values above.
- **Built in the engine only:** per-word distance overrides (`EngineSettings.distanceOverrides`). They have no UI yet.
- Words not in the table are treated as Rare, **except likely proper nouns** (§4.7).

**Distance counting rules:**
- Distance is counted in tokens between occurrences. **Excluded words still count toward distance**, because the reader still reads them. They just aren't flagged themselves.
- **"Don't count repeats across paragraphs"** (off by default) resets distances at paragraph breaks.
- When a word appears 3+ times in a chain (each within the limit of the next), the whole chain is one group.

### 4.4 Word lists
| List | Purpose | Default contents | Where to edit |
|---|---|---|---|
| **Exclude list** | Never flagged as repeats | ~150 English stop words | Settings › Word Lists, Check Text › Tuning, or **Exclude everywhere** in the hover bubble |
| **Watch list** | Flags every occurrence, regardless of distance | Empty, with an **Add starter pack** button (*just, really, very, suddenly, that, began to, started to, seemed, felt, realized, a bit, somehow*) | Settings › Word Lists, Check Text › Tuning |
| **Ignore list** | Words to skip in one document, e.g. character names | Empty | **Ignore in document** in the hover bubble; Check Text › Tuning for pasted text |

- Lists are edited as plain text, one entry per line.
- The watch list accepts single words **and multi-word phrases** (`began to`).
  - Phrase words must be separated only by spaces, so *began. To* doesn't match *began to*.
  - In *Same root* mode an exact watch entry also catches other forms (*realize* flags *realized*).
- **Wildcards** work in all lists: `*ly` flags adverbs, and `look*` catches look/looked/looking.
- A watched word takes priority over the exclude list. If a watched word is also a repeat, only the watch highlight is drawn, but the repeat still counts in the report.
- **Per-document ignores** are saved in UserDefaults. They are keyed by the app's bundle ID plus the window's document path (`AXDocument`), or the window title when there's no path. So a Scrivener project or Vellum book keeps its ignores across launches. Settings › Word Lists has a button to clear them all.
- **Planned, not built:** importing and exporting lists as `.txt` files. Copying and pasting the list text does the same job.

### 4.5 Watch-list thresholds
A watch entry can have a rate threshold. Write it after the word, e.g. `just 3/1000`, which flags *just* only when it appears more than 3 times per 1,000 words. Without a threshold, every occurrence is flagged.

### 4.6 Analysis scope
Rare-word distances (up to 1,500 words) can exceed what's on screen, so the engine always analyzes the **whole text the app exposes**. Only the visible part is drawn.
- In Scrivener that's the current document, or the full Scrivenings view if several documents are shown together.
- In Vellum it's the current chapter.
- Repeats that cross Scrivener documents are caught only when the documents are shown together in Scrivenings mode.

### 4.7 Proper nouns (character and place names)
Because unknown words get the longest distance, names would otherwise be flagged constantly.
- A word is treated as a name, and **not flagged**, if **every** occurrence is capitalized and **at least one** is mid-sentence.
- This uses capitalization only. Being in the frequency table says nothing about names: wordfreq includes *elara* (1.4) and *sarah* (4.5).
- Words capitalized only at sentence starts (*Suddenly*) and words also used in lowercase (*Hope* / *hope*) are still checked.
- `NLTagger` name tagging was dropped: it took ~0.85 s per novel, and the capitalization rule caught the names in testing (*Bingley, Darcy, Elizabeth*).
- **Ignore in document** in the hover bubble handles names the rule misses.
- The rule can be turned off with **"Skip character and place names"** in Settings › Analysis.

## 5. Features

### 5.1 Menu bar app
- Echo runs as a background agent (`LSUIElement`): menu bar icon only, with no Dock icon. The Dock icon appears only while the Check Text or Settings window is open.
- The menu contains:
  - A status line: "Highlighting is off", "Needs Accessibility access", "Waiting for Scrivener or Vellum", "No document found in ‹App›", or "‹App›: 12 repeats, 3 watch words".
  - The on/off toggle.
  - **Pause for 1 Hour**, which becomes **Resume Now** while paused.
  - **Grant Accessibility Access…**, shown only when permission is missing.
  - **Check Text…** (⌘K).
  - **Check This ‹App› Document** (⇧⌘K), shown only while highlighting is active.
  - **Settings…** (⌘,).
  - **Quit**.
- A global hotkey **⌃⌥⌘E** toggles highlighting from any app. It uses Carbon `RegisterEventHotKey`, which needs no extra permission. ⌃⌥E was the first choice but clashed with Rectangle.
  - **Planned, not built:** a configurable hotkey.
- **Open Echo at login** (`SMAppService`) is in Settings › General and is off by default.

### 5.2 Highlighting
- Highlights are drawn in a transparent, click-through overlay window. The host app's text is never modified.
  - The overlay is sized to the editor's visible content area, with rulers and scroll bars trimmed. This clips partly scrolled-off lines for free.
  - It floats just above the host's windows and is shown only while that app is frontmost.
- Styles:
  - Repeats get an **orange wavy underline**, and their strength follows rarity:
    - Rare repeats are boldest, common ones faintest (strength 0.3 → 1.0 from very common to rare).
    - Uncommon and rare repeats also get a soft tint, because they're the ones readers notice.
  - Watch-list words get a **blue straight underline**.
  - The **Background** style (Settings › General) uses tinted boxes instead of underlines.
  - **Planned, not built:** custom colors, and per-word colors in the watch list.
- Highlights update ~300 ms after typing stops. Until then, existing highlights shift with each edit so they stay on the right words.
- Highlights also update when the window scrolls, moves or resizes, and when focus or the front window changes. Scrolling is tracked with Accessibility notifications, scroll-wheel events and a light position poll.
- Echo finds the editor as the **largest text area in the focused window**, rather than relying on keyboard focus. Focus is often elsewhere, e.g. Scrivener's binder.
  - Only real text areas that report word bounds count, so secure (password) fields are never read.
  - Highlights hide when the app loses focus, is hidden, or has no editor.

### 5.3 Hover details
Hovering a highlighted word shows a small bubble. Hover is detected with a global mouse monitor, so the overlay stays click-through.
- The bubble explains why the word is flagged:
  - For a repeat: *"“gossamer” (uncommon) — 312 words after the previous one. Limit: 500 words."*
  - For a watch word: *"Watch list: “just” — 6× in this text (2.1 per 1,000 words)."*
- It has these buttons:

| Button | Behavior |
|---|---|
| **Show other** | Flashes the nearest other use of the word, or selects it if it's off screen. |
| **Ignore here** | Hides this one highlight until the document changes. |
| **Ignore in document** | Saves the word, in every form, to this document's ignore list (§4.4). |
| **Exclude everywhere** | Adds the word and its root to the exclude list. |

- The bubble is a non-activating panel, so clicking its buttons leaves the writing app in front.

### 5.4 Per-app control
- Highlighting runs only in apps on an allow list, keyed by bundle ID. The defaults are Scrivener, Vellum and TextEdit, and each can be switched off.
- **Add App…** in Settings › Apps adds any other app, which can later be removed.
- **Planned, not built:** per-app sensitivity.

### 5.5 Settings window (SwiftUI)
The window opens with ⌘, from the menu and has four tabs:

| Tab | Contents |
|---|---|
| **General** | On/off, the hotkey (shown, not editable), pause status with Resume, open at login, highlight style (underline or background), and Accessibility status with a button to open System Settings. |
| **Analysis** | Matching mode, rarity sensitivity slider, per-tier distances, the four options from §4, and Restore default settings. These are the same controls as Check Text's Tuning tab. |
| **Word Lists** | Watch list (with starter pack), exclude list, and clear all per-document ignores. |
| **Apps** | The allow list (§5.4). |

**Changed:** the original plan had five tabs. Permissions moved into General, and the watch and exclude lists share one tab.

### 5.6 Check Text window
Check Text is for text that can't be highlighted in place (e.g. Word documents) and for whole-chapter review.
- Open it with ⌘K. Paste text, or open a .txt, .rtf, .docx or .html file.
- **Check This ‹App› Document** (⇧⌘K) loads the current Scrivener, Vellum or TextEdit document through Accessibility.
  - **Changed:** the planned select-all + copy fallback wasn't needed, so it wasn't built.
- The window uses the same highlights and hover explanations as the overlay. It is read-only; edits are made back in the original app.
- The **Report** tab shows:
  - The 25 most-repeated non-excluded words, grouped by root but shown as written ("George", not "georg"), with count and rarity tier.
  - Watch-list words with count, rate per 1,000 words, and threshold.
  - Total repeats by rarity tier.
  - Clicking a row steps through its occurrences.
  - **Copy Report** copies the report as plain text. This version still lists roots rather than written forms.
- The **Tuning** tab holds the analysis controls and word lists, including a per-text ignore list. Changes apply live and are saved between launches.

### 5.7 First launch
If Accessibility permission is missing:
- The menu shows **Grant Accessibility Access…**, which triggers the system prompt and opens the right pane in System Settings.
- Echo polls for the permission and starts highlighting within a couple of seconds of it being granted.
- There is no separate onboarding window.

## 6. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│ Echo/EchoApp — menu bar app (AppKit + SwiftUI)                │
│                                                              │
│  AppModel ── settings, lists, allow list, pause, hotkey,      │
│      │       launch at login (UserDefaults)                   │
│      ▼                                                       │
│  LiveHighlighter ── follows the frontmost app; AXObserver     │
│      │   (focus, window, value, selection, scroll bar         │
│      │    changes) + adaptive poll; finds the editor;         │
│      │    reads AXValue; shifts marks on edits                │
│      ▼                                                       │
│  EchoEngine.Analyzer (detached task)                          │
│      │   tokenize → lemmatize → rarity → repeats + watch hits │
│      ▼                                                       │
│  Geometry ── AXBoundsForRange for visible matches,            │
│      │       hit-tests covered lines near the clip edges      │
│      ▼                                                       │
│  OverlayWindow + HoverBubble                                  │
│                                                              │
│  Check Text window / Settings window (SwiftUI)               │
└──────────────────────────────────────────────────────────────┘
```

- **Stack:** Swift 6 (needs Xcode 26+ / Swift 6.2). AppKit is used for the overlay and Accessibility, SwiftUI for the windows. Minimum macOS 14 (Sonoma).
- **Accessibility API** (`AXUIElement`) is the only way to read text and on-screen positions in other apps. It requires the user to grant Accessibility permission.
- **Changed: no per-app adapters.** Scrivener and Vellum both use standard text views, so one generic path handles them. App-specific quirks are handled generically:
  - The ruler is trimmed out of the scroll area.
  - Floating headers are caught by hit-testing.
- **EchoEngine** is a separate Swift package with no AppKit dependency, used by both the overlay and Check Text. It has 30 unit tests, run with `swift test`.
- **Analysis** runs on a background task, including building the list of marks to draw. **Changed:** the planned incremental re-analysis wasn't needed, because full analysis of a novel runs in the background in ~200–275 ms.
- **Protection against a busy host app:**
  - Accessibility calls time out after 0.2 s.
  - Each redraw has a 150 ms budget and retries after 250 ms.
  - Redraws are throttled to ~30/s, because each one makes the host answer Accessibility queries on its main thread.

## 7. Performance

Measured on *Pride and Prejudice* (130k words, 763k characters) in TextEdit:

| Measure | Target | Measured |
|---|---|---|
| Full analysis, 100k+ words | < 150 ms | 80 ms in the engine benchmark; ~200–275 ms in the app, on a background thread, with 0.4 ms on the main thread |
| Cost of a keystroke | < 20 ms | ~0.1 ms (marks shift; re-analysis follows after the debounce) |
| Redraw | under one frame after scrolling stops | median 11 ms, max 27 ms |
| Idle CPU | ~0% | ~0.2% (poll every 0.1 s while active, 0.5 s after 2 s idle) |
| Reading the text | — | 0.5 ms |

Before the timeouts, clicking into a huge document could stall Echo for 1.3–1.5 s. That no longer happens.

## 8. Privacy and security
- Echo makes no network access: no analytics and no update checks.
- Document text is held in memory only, never written to disk or logs.
- Secure text fields are never read (§5.2).
- Per-document ignore lists store only the ignored words, keyed by app and document path or window title.
- **Changed:** the plan said the key would be hashed. It's stored as plain text in Echo's preferences, which is local only.
- **Repo hygiene:** the spike's reports quote manuscript text. They live in `spike/results/`, which is gitignored and was scrubbed from the public repo's history.

## 9. Build, install and distribution
- **Source layout:** `Echo/EchoApp` is a Swift package that depends on `Echo/EchoEngine`. It also opens in Xcode. It isn't sandboxed, because Accessibility apps can't be.
- **`Echo/EchoApp/build.sh`** builds and signs `build/Echo.app`.
  - `--open` relaunches the app.
  - `--install` copies it to `/Applications` and launches it.
  - It signs with the stable "Apple Development" certificate, so the Accessibility permission survives rebuilds. Ad-hoc signing would force a re-grant every time.
- **`Echo/EchoApp/make_dmg.sh`** builds `build/Echo-<version>.dmg` (the app plus an Applications shortcut).
  - It signs with hardened runtime and a secure timestamp.
  - It uses a Developer ID certificate if present and notarizes when the `echo-notary` keychain profile exists. Otherwise it uses Apple Development.
- **Releases:**
  - Repo: https://github.com/ngcrawford/echo-writing (public).
  - Release **v0.1**: https://github.com/ngcrawford/echo-writing/releases/tag/v0.1.
  - The DMG isn't notarized yet, because there's no Developer ID certificate. Recipients approve it once in System Settings › Privacy & Security › **Open Anyway**.
- To release a new version:
  1. Bump `CFBundleShortVersionString` in `Echo/EchoApp/Support/Info.plist`.
  2. Run `make_dmg.sh`.
  3. Commit, tag, and create a GitHub release with the DMG attached.
- **No auto-update or licensing.**

## 10. Known risks / limitations
- **Microsoft Word (deferred).** Spike findings are in §3. If Word is picked up later:
  - Poll instead of waiting for notifications.
  - Rely on the existing 0.2 s Accessibility timeout and redraw budget to survive Word's ~1 s bounds stalls.
  - Finish testing 150% zoom on a later page.
- **Other apps.** Positioning depends on each app's Accessibility implementation. Apps with custom text rendering may misplace highlights or show none.
- **Cross-document repeats** in Scrivener are caught only in Scrivenings view. Vellum is always per chapter.
- **Same-root false positives** come from the lemmatizer (*left* → *leave*). Switch to Exact word, or use Ignore in document.
- **Multiple displays and Spaces:** the overlay joins all Spaces and follows the editor, but it's been tested mainly on one display.
- **Unsigned for distribution:** first launch from the DMG needs "Open Anyway" until Developer ID signing and notarization are set up.
- **Frequency table licensing:** wordfreq data is CC BY-SA 4.0, credited in the README.

## 11. Milestones

All v1 milestones are **done**, as of 2026-10-26.

0. **Compatibility spike.**
   - The tool is in `spike/AXProbe`. Its reports are in `spike/results/`, which is local only (§8).
   - Scrivener (normal and Scrivenings view) and Vellum pass. Word is deferred (§3).
1. **Engine.**
   - Built as `Echo/EchoEngine`, with 30 tests plus a benchmark.
   - *Pride and Prejudice*: 80 ms per analysis, or 235 ms the first time, while root words are cached.
2. **Check Text window.**
   - Paste or open .txt/.rtf/.docx/.html.
   - It has highlights, hover explanations, and Report and Tuning tabs.
3. **Overlay in Scrivener.**
   - `LiveHighlighter` finds the editor, analyzes in the background and draws visible matches in a click-through overlay. Marks shift with edits.
   - Installed with `build.sh --install`. The user reported no issues.
4. **Vellum.**
   - Works as in Scrivener. Floating headers are handled by hit-testing covered lines.
   - The pale blue/red underlines seen in both apps are macOS proofreading, not Echo.
5. **Settings, menu bar, hover popover.**
   - Everything in §5.1, §5.3, §5.4 and §5.5.
6. **Polish.**
   - The performance work in §7.
   - Editor tracking survives switching between windows of the same app.
   - Check This Document, and written forms in the report.
   - Rarity-weighted highlight strength, at the user's request.
7. **Release** (added).
   - README, `make_dmg.sh`, the public GitHub repo, and the v0.1 release with its DMG.
   - The hardened-runtime build from the DMG was verified, and it kept the Accessibility permission.

## 12. Future versions

### 12.1 OneLook thesaurus integration (v2, planned)
The goal is to find a replacement quickly when a word is flagged.

- **Level 1: open in browser.** A "Look up on OneLook" button in the hover bubble opens `https://onelook.com/thesaurus/?s=<word>`.
- **Level 2: suggestions in the bubble.** Show the top ~10 synonyms from the **Datamuse API** (`https://api.datamuse.com/words?ml=<word>`), each with its rarity tier from Echo's own table.
  - Optional context-aware ranking (`lc` / `rc`), off by default for privacy.
  - Filter out suggestions already used nearby.
  - Clicking a suggestion copies it. Direct replacement through `AXSelectedText` is possible in Scrivener and Vellum, but that decision is deferred.
  - Cache results and respect Datamuse's limits.
- Network access is opt-in through a Settings toggle. With it off, only Level 1 is available.

### 12.2 Backlog from v1
These items were planned or discussed for v1 but not built:
- Developer ID signing and notarization (needs the paid Apple Developer Program; `make_dmg.sh` is ready for it).
- Configurable hotkey.
- Per-word watch-list colors, and custom highlight colors.
- UI for per-word distance overrides (already in the engine) and for tier thresholds.
- Import and export of word lists as `.txt` files.
- Per-app sensitivity.
- Copy Report using written forms instead of roots.

### 12.3 Other ideas
- Sentence-opening repetition (three sentences in a row starting with *She*).
- Automatic detection of repeated phrases (n-grams), not just watch-list phrases.
- Per-project profiles (different lists per novel).
- Watch-word density over the course of a document.
- Microsoft Word support (§3, §10).
- A Chrome extension for Google Docs.

## 13. Decisions

| Question | Decision |
|---|---|
| Target apps | Scrivener and Vellum, with TextEdit for testing. Word deferred. |
| Distance model | Scaled by word rarity (§4.3) |
| Audience | Built for personal use. Now also shared publicly through GitHub releases. |
| Character names | Capitalization rule plus Ignore in document (§4.7) |
| Matching default | Same root |
| Highlight emphasis | Rare repeats boldest, with a tint for uncommon and rare |
| Hotkey | ⌃⌥⌘E (⌃⌥E clashes with Rectangle) |
| Summary report | Yes, in the Check Text window (§5.6) |
| Language | English only |
| Thesaurus | OneLook / Datamuse in v2 (§12.1) |
| Commit identity | GitHub noreply address |
| Manuscript text | Never committed; spike reports stay local |

## 14. Open questions

None blocking. Candidates for the next version are in §12.2.
