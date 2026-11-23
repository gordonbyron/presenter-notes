# Presenter Notes

A small Mac app that shows your speaker notes in very large print and keeps them in step with a Google Slides slideshow.

I am visually impaired and could not read the speaker notes that slideshow tools put under the slide. This app puts the notes on their own screen, in text as large as you need, and changes the note when the slide changes.

## What it does

- Shows one note per slide in large, bold, high-contrast text on a black screen.
- Follows Google Slides. When the slide changes, the note for that slide appears. This works in the editor, in a slideshow, and when you jump to any slide.
- Lets you drive the slideshow with the mouse. Left click goes forward, right click goes back, and the wheel scrolls a long note.
- Runs from keyboard shortcuts and a menu bar item. It has no Dock icon and never takes keyboard focus from your slides.
- Keeps several sets of notes, one per slideshow, with a large-print editor to create and change them.
- Reloads the notes file when you save it.

## Requirements

- macOS 14 or later.
- Xcode command line tools, to build it.
- Google Chrome for slide following. See [Limits](#limits) for other browsers.
- Two screens work best: slides on one, notes on the other.

## Build and run

```sh
./build.sh
open "build/Presenter Notes.app"
```

The build script signs the app with an Apple Development identity if your keychain has one. macOS then remembers the app's permissions between builds. Without one it signs ad hoc, and macOS asks for the permissions again after each build.

The first time it runs, the app creates `~/PresenterNotes/notes.txt` with a short sample.

## The notes window and Present

Opening the app shows the notes window. The app stays running in the menu bar when you close it.

- **Your sets of notes** are listed on the left. Each set is one file in `~/PresenterNotes`, usually one per slideshow.
- **The editor** on the right shows the selected set in large text. Changes save as you type.
- **New set** asks for a name and creates a set. If a Google Slides deck is showing in your browser, the new set is linked to it.
- **Add a note for the slide on screen** adds a note tied to the slide showing in your browser, or moves to that slide's note if it has one.
- **Delete** moves the set to the Trash.
- **Present** closes the window and shows the notes screen with that set.

To stop presenting, press Ctrl+Opt+N or choose Stop presenting from the menu bar. To get the window back, choose Edit notes from the menu bar, press Ctrl+Opt+E, or open the app again.

## Permissions macOS will ask for

| Permission | Needed for | When it is asked |
|---|---|---|
| Automation, for your browser | Following the slides | The first time Google Slides is in front |
| Accessibility | Mouse control | The first time you press Ctrl+Opt+K |
| Screen Recording | The optional "check notes are hidden" test | The first time you press Ctrl+Opt+T |

Notes cannot follow the slides until you allow the Automation prompt. If the prompt goes unanswered, the app says so on the notes screen.

## Writing notes

Notes are plain text files in `~/PresenterNotes`. A line of three dashes starts the next note.

```
deck: https://docs.google.com/presentation/d/YOUR-DECK-ID/edit

slide: g2f1b_0_5 (1. Title)
Welcome everyone
Thank the team
---
slide: g2f1b_0_9 (2. Results)
Revenue is up
Mention the launch
```

- `deck:` is optional. With it, the app opens this file by itself when that deck is showing in your browser.
- `slide:` ties a note to a slide. Use the slide's ID or paste a link to the slide. Text after the ID is a label for you and is ignored.
- Without `slide:` lines, notes are shown in order and you turn them yourself.

To find a slide's ID, select the slide in Google Slides and look at the end of the address: `#slide=id.g2f1b_0_5`.

A note can be longer than one screen. Scroll it with the wheel or with Ctrl+Opt+Down.

## Writing notes with Claude

The [skill/presenter-notes](skill/presenter-notes) folder holds a skill for Claude Code. Give Claude a Google Slides link and ask for presenter notes. It reads the deck's speaker notes, writes a notes file with one note per slide and the `slide:` lines filled in, and checks the file against the deck. It writes short keyword notes by default, or the speaker notes word for word if you ask for "full".

To install it, copy the folder into your Claude skills folder:

```sh
cp -R skill/presenter-notes ~/.claude/skills/
```

It needs the Google Slides connector in Claude. The helper script, `notes_tool.py`, uses only the Python standard library and can also be run by hand. Run it with `--help` to see how.

## Shortcuts

| Shortcut | What it does |
|---|---|
| Ctrl+Opt+N | Start or stop presenting |
| Ctrl+Opt+Right / Left | Next or previous note |
| Ctrl+Opt+0 | Back to the first note |
| Ctrl+Opt+Down / Up | Scroll a long note |
| Ctrl+Opt+Plus / Minus | Bigger or smaller text |
| Ctrl+Opt+C | Change text colour |
| Ctrl+Opt+L | Change layout: full screen, top half, bottom half |
| Ctrl+Opt+M | Move the notes to the next display |
| Ctrl+Opt+E | Edit notes in the notes window |
| Ctrl+Opt+O | Open another notes file |
| Ctrl+Opt+F | Follow slides on or off |
| Ctrl+Opt+K | Mouse control on or off |
| Ctrl+Opt+I | Show status |
| Ctrl+Opt+T | Check notes are hidden from screen sharing |
| Ctrl+Opt+H | Show or hide help |
| Ctrl+Opt+Shift+Q | Quit |

## Menu bar

The app adds a **Notes** item to the menu bar. Its menu uses larger text than a normal menu and offers:

- Present or stop presenting, and open the notes window.
- Bigger text, smaller text, or a text size picked from a list.
- Mouse control on or off, and slide following on or off. A tick shows which are on.
- Every notes file in `~/PresenterNotes`, with a tick on the one in use. Choose one to switch slideshows.
- Choose another file, or open the notes folder.
- Quit.

The notes window sits just under the menu bar, so the menu stays reachable on the screen that shows the notes.

A notes file with a `deck:` line opens by itself when that deck comes up in the browser. A file you pick by hand stays in use until a different deck comes up.

## Mouse control

Mouse control acts only while a slideshow is running full screen and the pointer is over the slides or the notes.

- Left click: next slide.
- Right click: previous slide.
- Wheel or trackpad: scroll the note.

Everywhere else the mouse behaves as normal, so you can still click in a meeting window.

## How following works

Google Slides keeps the ID of the current slide in the page address. A few times a second the app asks the browser for the address of its Google Slides tab and shows the note whose `slide:` line matches. It reads the address only. It does not read the page.

## Limits

- **Browsers.** Tested with Google Chrome. Brave, Microsoft Edge and Safari are wired up the same way and are untested. Firefox and browsers built on it, such as Zen, do not let other apps read the address, so following and mouse control cannot work there.
- **Google Slides only.** Keynote and PowerPoint are not supported.
- **Screen sharing.** The app marks its window as excluded from screen sharing. On macOS 15 and later, some meeting apps ignore that mark when you share an entire screen. Keep the notes on a screen you are not sharing, or share a single window.
- **Mirrored displays.** A mirrored projector shows the notes to the room. Use extended displays.
- **Changed decks.** If you add or duplicate slides, add `slide:` lines for the new slides. A slide with no note shows "No note for this slide".

## Troubleshooting

Press Ctrl+Opt+I for a status screen. It shows which slide the app can see and whether mouse control is ready.

The app writes a short log to `~/Library/Logs/PresenterNotes.log`. It holds slide and deck IDs and what the app did. It never holds the text of your notes or full web addresses.

## Self-test

```sh
"build/Presenter Notes.app/Contents/MacOS/PresenterNotes" --snapshot /tmp/presenter-notes-test
```

This runs the built-in checks, prints the results, writes a picture of each screen to the folder, and quits. The clicks and key presses in the self-test are simulated inside the app. The one real event it sends is a scroll of zero distance, to confirm the mouse watcher receives events.

## Code

The whole app is one Swift file, [Sources/main.swift](Sources/main.swift), using AppKit with no dependencies.

## Licence

MIT. See [LICENSE](LICENSE).
