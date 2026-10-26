# Echo

Echo is a small Mac menu bar app for fiction writers. It underlines words you've repeated too close together, right inside **Scrivener** and **Vellum**, while you write.

Echo scales "too close" by how common the word is:

- **Common words** ("said", "door") are flagged only when they repeat within a few dozen words.
- **Rare words** ("gossamer", "susurrus") are flagged even hundreds of words apart, because readers notice them.
- **Rare repeats** get the boldest underline.

It also highlights words from your own watch list ("just", "suddenly", "began to").

Echo never changes your text. It only draws on top of it.

Requires macOS 14 (Sonoma) or later.

## Install

1. Download `Echo-<version>.dmg` from the [Releases](../../releases) page.
2. Open it and drag **Echo** onto **Applications**.
3. Open Echo from Applications.
   - If macOS says it can't verify the app, open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway**.
4. Echo appears as a magnifying-glass icon in the menu bar.
   - Choose **Grant Accessibility Access…** and switch **Echo** on in the list that opens.
   - Echo needs this to see the text in your writing app. It starts working a couple of seconds after you switch it on.

## Use

**Highlights.** Open a document in Scrivener or Vellum and start writing. Echo draws:

| Highlight | Meaning |
|---|---|
| Wavy orange underline | A word repeated too close to another use of it. Rarer words get a bolder line and a soft tint. |
| Blue underline | A word or phrase from your watch list. |

Highlights update about a third of a second after you stop typing.

**Hover over a highlighted word** to see why it's flagged, with buttons to:

| Button | What it does |
|---|---|
| Show other | Briefly outlines the nearest other use of the word. |
| Ignore here | Hides just this one highlight. |
| Ignore in document | Stops flagging this word in this Scrivener project or Vellum book. |
| Exclude everywhere | Adds the word to your exclude list, for all documents. |

**The menu bar menu** has:
- The current counts.
- An on/off switch, also available from any app with **⌃⌥⌘E**.
- **Pause for 1 Hour**.
- **Check This Document**, which opens the whole document in the Check Text window with a report: most-used words, watch-list rates per 1,000 words, and repeats by rarity.

**Check Text** (⌘K) is a separate window for any other text. Paste it in, or open a .txt, .rtf, .docx or .html file. It works for Word documents, which Echo can't highlight in place yet.

**Settings** (⌘, from the menu) has these tabs:

| Tab | What's in it |
|---|---|
| General | On/off, open at login, underline or background style. |
| Analysis | Same-root vs. exact matching, and how close counts as "too close" for each rarity level. A sensitivity slider stretches or shrinks them all. |
| Word Lists | Your watch list (add “3/1000” after a word to flag it only above 3 per 1,000 words) and the exclude list. |
| Apps | Which apps Echo highlights in. TextEdit is included for trying it out. |

## Build from source

You need Xcode 26 or later (Swift 6.2).

```sh
cd Echo/EchoEngine && swift test        # analysis engine and its tests
cd Echo/EchoApp && ./build.sh --install # build, sign, copy to /Applications, launch
cd Echo/EchoApp && ./make_dmg.sh        # build a shareable DMG in Echo/EchoApp/build
```

**Signing.** `build.sh` signs with your "Apple Development" certificate. Using the same certificate every time keeps the Accessibility permission across rebuilds.

**Notarizing.** With a "Developer ID Application" certificate and saved notarization credentials, `make_dmg.sh` signs the DMG for distribution and has Apple notarize it. Recipients then skip the "Open Anyway" step. See the comments at the top of the script.

**Where things are:**

| Path | Contents |
|---|---|
| `Echo/EchoEngine` | The analysis: tokenizing, word roots, rarity, repeats, watch list, report. |
| `Echo/EchoApp` | The menu bar app: Accessibility tracking, the overlay, Check Text, Settings. |
| `SPEC.md` | The design, decisions and milestone notes. |
| `spike/` | The Accessibility compatibility probe used to test Scrivener, Vellum and Word. |

## Credits

Word frequencies come from [wordfreq](https://github.com/rspeer/wordfreq) by Robyn Speer, licensed CC BY-SA 4.0.
