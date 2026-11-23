# Presenter Notes

A small Mac app that shows your speaker notes in very large print and keeps them in step with a Google Slides slideshow.

I am visually impaired and could not read the speaker notes that slideshow tools put under the slide. This app puts the notes on their own screen, in text as large as you need, and changes the note when the slide changes.

## What it does

- Shows one note per slide in large, bold, high-contrast text on a black screen.
- Follows Google Slides. When the slide changes, the note for that slide appears. This works in the editor, in a slideshow, and when you jump to any slide.
- Lets you drive the slideshow with the mouse. Left click goes forward, right click goes back, and the wheel scrolls a long note.
- Runs from keyboard shortcuts. It has no Dock icon and never takes keyboard focus from your slides.
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

## Shortcuts

| Shortcut | What it does |
|---|---|
| Ctrl+Opt+N | Show or hide notes |
| Ctrl+Opt+Right / Left | Next or previous note |
| Ctrl+Opt+0 | Back to the first note |
| Ctrl+Opt+Down / Up | Scroll a long note |
| Ctrl+Opt+Plus / Minus | Bigger or smaller text |
| Ctrl+Opt+C | Change text colour |
| Ctrl+Opt+L | Change layout: full screen, top half, bottom half |
| Ctrl+Opt+M | Move the notes to the next display |
| Ctrl+Opt+E | Edit the notes file |
| Ctrl+Opt+O | Open another notes file |
| Ctrl+Opt+F | Follow slides on or off |
| Ctrl+Opt+K | Mouse control on or off |
| Ctrl+Opt+I | Show status |
| Ctrl+Opt+T | Check notes are hidden from screen sharing |
| Ctrl+Opt+H | Show or hide help |
| Ctrl+Opt+Shift+Q | Quit |

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
