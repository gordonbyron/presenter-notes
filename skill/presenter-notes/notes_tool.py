#!/usr/bin/env python3
"""Build and check Presenter Notes files from Google Slides deck data.

The deck data is the JSON returned by the Google Slides `read_presentation`
tool. Standard library only.

  notes_tool.py list  <deck.json>
      Print each slide: number, ID, title, speaker notes and on-slide text.

  notes_tool.py draft <deck.json> [--out PATH] [--deck-id ID]
      Write a notes file holding every slide's speaker notes, word for word.
      Without --out it reuses the file in ~/PresenterNotes that already names
      this deck, or makes a new one named after the deck's title.
      An existing file is first copied to a .bak file beside it.

  notes_tool.py check <notes.txt> (<deck.json> | --ids ID,ID,... [--deck-id ID])
      Confirm the notes file has one note per slide, in deck order, with the
      right slide IDs. Exits 1 on any mismatch.
"""
import argparse
import datetime
import json
import os
import re
import shutil
import sys

NOTES_FOLDER = os.path.expanduser("~/PresenterNotes")


# ---------- reading the deck ----------

def load_deck(path):
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    return data.get("content", data)  # the tool sometimes wraps the deck in "content"


def text_of(shape):
    runs = (shape.get("text") or {}).get("textElements", [])
    text = "".join(run.get("textRun", {}).get("content", "") for run in runs)
    return text.replace("\u000b", "\n")  # Slides uses a vertical tab for a soft line break


def tidy(text):
    lines = [line.rstrip() for line in text.replace("\r", "").split("\n")]
    text = "\n".join(lines).strip()
    return re.sub(r"\n{3,}", "\n\n", text)


def one_line(text):
    return re.sub(r"\s+", " ", text).strip()


def slides_of(deck):
    """One dict per slide: number, id, title, notes, body (on-slide text), skipped."""
    out = []
    for number, slide in enumerate(deck.get("slides", []), 1):
        title, body = "", []
        for element in slide.get("pageElements", []):
            shape = element.get("shape")
            if not shape:
                continue
            text = tidy(text_of(shape))
            if not text:
                continue
            kind = shape.get("placeholder", {}).get("type", "")
            if kind in ("TITLE", "CENTERED_TITLE") and not title:
                title = one_line(text)
            else:
                body.append(one_line(text))
        notes = []
        properties = slide.get("slideProperties", {})
        for element in properties.get("notesPage", {}).get("pageElements", []):
            shape = element.get("shape", {})
            if shape.get("placeholder", {}).get("type") == "BODY":
                text = tidy(text_of(shape))
                if text:
                    notes.append(text)
        out.append({
            "number": number,
            "id": slide["objectId"],
            "title": title or (body[0] if body else f"Slide {number}"),
            "notes": "\n\n".join(notes),
            "body": body,
            "skipped": bool(properties.get("isSkipped")),
        })
    return out


def findings(slides):
    """Things the presenter should know before trusting the notes."""
    empty = [s["number"] for s in slides if not s["notes"]]
    seen, copies = {}, []
    for s in slides:
        if not s["notes"]:
            continue
        key = one_line(s["notes"])
        if key in seen:
            copies.append((s["number"], seen[key]))
        else:
            seen[key] = s["number"]
    skipped = [s["number"] for s in slides if s["skipped"]]
    return empty, copies, skipped


def print_findings(slides):
    empty, copies, skipped = findings(slides)
    print(f"slides: {len(slides)}")
    print("slides with no speaker notes: " + (", ".join(map(str, empty)) or "none"))
    print("slides whose speaker notes copy an earlier slide: "
          + (", ".join(f"{n} (same as {first})" for n, first in copies) or "none"))
    print("slides marked as skipped in the deck: " + (", ".join(map(str, skipped)) or "none"))


# ---------- the notes file ----------

def slug(title):
    name = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return name[:60].strip("-") or "deck"


def label(slide):
    # Shown after the slide ID for the person editing the file. The app ignores it.
    return f"{slide['number']}. {slide['title']}"[:70]


def heading(slide):
    # First line of every note, so the presenter can see the note matches the slide.
    return f"{slide['number']}. {slide['title'].upper()}"


def parse_notes(text):
    """Mirrors how the Presenter Notes app reads a file. Returns (deck_id, [(slide_id, body)])."""
    deck_id, pages, current = None, [], []

    def close():
        nonlocal deck_id
        slide_id, lines = None, list(current)
        while True:
            index = next((i for i, line in enumerate(lines) if line.strip()), None)
            if index is None:
                break
            line = lines[index].strip()
            low = line.lower()
            if not pages and deck_id is None and low.startswith("deck:"):
                value = line[5:].strip()
                match = re.search(r"/presentation/d/([A-Za-z0-9_\-]+)", value)
                deck_id = match.group(1) if match else (value.split(" ")[0] if value else None)
            elif slide_id is None and low.startswith("slide:"):
                value = line[6:].strip()
                match = re.search(r".*slide=id\.([A-Za-z0-9_:\-]+)", value)
                if match:
                    slide_id = match.group(1)
                else:
                    token = value.split(" ")[0] if value else ""
                    if token.startswith("id."):
                        token = token[3:]
                    slide_id = token if token and "/" not in token else None
            else:
                break
            del lines[: index + 1]
        pages.append((slide_id, "\n".join(lines).strip()))
        current.clear()

    for line in text.replace("\r\n", "\n").split("\n"):
        stripped = line.strip()
        if len(stripped) >= 3 and set(stripped) == {"-"}:
            close()
        else:
            current.append(line)
    close()
    if len(pages) > 1 and pages[-1] == (None, ""):
        pages.pop()
    return deck_id, pages


def files_for_deck(folder, deck_id):
    """Notes files in the folder whose `deck:` line names this deck."""
    found = []
    if not os.path.isdir(folder):
        return found
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".txt"):
            continue
        path = os.path.join(folder, name)
        try:
            with open(path, encoding="utf-8") as handle:
                other_deck, _ = parse_notes(handle.read())
        except (OSError, UnicodeDecodeError):
            continue
        if other_deck == deck_id:
            found.append(path)
    return found


# ---------- commands ----------

def command_list(args):
    deck = load_deck(args.deck)
    slides = slides_of(deck)
    print(f"deck: {deck.get('title', '(no title)')}  id: {deck.get('presentationId', '(not in data)')}")
    print_findings(slides)
    for s in slides:
        print(f"\n=== slide {s['number']}  id {s['id']}{'  SKIPPED' if s['skipped'] else ''}")
        print(f"title: {s['title']}")
        print("speaker notes:" + ("\n" + s["notes"] if s["notes"] else " (none)"))
        if s["body"]:
            print("on the slide: " + " | ".join(s["body"])[:1500])


def command_draft(args):
    deck = load_deck(args.deck)
    slides = slides_of(deck)
    deck_id = args.deck_id or deck.get("presentationId")
    if not deck_id:
        sys.exit("The deck ID is not in the data. Pass --deck-id, or ask for presentationId in the field mask.")
    if not slides:
        sys.exit("The deck data holds no slides.")
    existing = files_for_deck(NOTES_FOLDER, deck_id)
    out = args.out or (existing[0] if existing else os.path.join(NOTES_FOLDER, slug(deck.get("title", "deck")) + ".txt"))
    out = os.path.expanduser(out)
    os.makedirs(os.path.dirname(out), exist_ok=True)

    blocks = []
    for s in slides:
        lines = [f"slide: {s['id']} ({label(s)})", heading(s)]
        if s["notes"]:
            lines.append(s["notes"])
        blocks.append("\n".join(lines))
    text = (f"deck: https://docs.google.com/presentation/d/{deck_id}/edit\n\n"
            + "\n---\n".join(blocks) + "\n")

    if os.path.exists(out):
        # Not .txt: the app scans the folder for .txt files and must not pick up the backup.
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = f"{out}.{stamp}.bak"
        shutil.copy2(out, backup)
        print(f"existing file backed up to: {backup}")
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(text)
    print(f"wrote: {out}")
    print_findings(slides)

    # Two notes files for one deck confuse the app, which opens the first it finds.
    for other in files_for_deck(os.path.dirname(out), deck_id):
        if os.path.abspath(other) != os.path.abspath(out):
            print(f"WARNING: another notes file names the same deck: {other}")


def command_check(args):
    with open(os.path.expanduser(args.notes), encoding="utf-8") as handle:
        text = handle.read()
    deck_id, pages = parse_notes(text)
    if args.ids:
        expected_ids = [i.strip() for i in args.ids.split(",") if i.strip()]
        expected_deck = args.deck_id
    elif args.deck:
        deck = load_deck(args.deck)
        expected_ids = [s["id"] for s in slides_of(deck)]
        expected_deck = args.deck_id or deck.get("presentationId")
    else:
        sys.exit("Give the deck data file, or --ids.")

    problems = []
    found_ids = [slide_id for slide_id, _ in pages]
    if expected_deck and deck_id != expected_deck:
        problems.append(f"deck ID in the file is {deck_id}, expected {expected_deck}")
    if len(pages) != len(expected_ids):
        problems.append(f"the file has {len(pages)} notes, the deck has {len(expected_ids)} slides")
    if found_ids != expected_ids:
        missing = [i for i in expected_ids if i not in found_ids]
        extra = [i for i in found_ids if i not in expected_ids]
        if missing:
            problems.append("slides with no note: " + ", ".join(missing))
        if extra:
            problems.append("notes that match no slide: "
                            + ", ".join(i or "(a note with no slide: line)" for i in extra))
        if not missing and not extra:
            problems.append("the notes are not in the same order as the slides")
    empty = [str(n) for n, (_, body) in enumerate(pages, 1) if not body]
    line_counts = [len([l for l in body.split("\n") if l.strip()]) for _, body in pages]
    longest = max((len(l) for _, body in pages for l in body.split("\n")), default=0)

    print(f"notes: {len(pages)}  slides: {len(expected_ids)}")
    print(f"lines per note: {line_counts}")
    print(f"longest line: {longest} characters")
    print("notes with no text: " + (", ".join(empty) or "none"))
    print(f"em dashes: {text.count(chr(0x2014))}")
    if problems:
        print("PROBLEMS:")
        for problem in problems:
            print("  - " + problem)
        sys.exit(1)
    print("OK: one note per slide, in deck order, with matching slide IDs")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    lister = commands.add_parser("list")
    lister.add_argument("deck")
    drafter = commands.add_parser("draft")
    drafter.add_argument("deck")
    drafter.add_argument("--out")
    drafter.add_argument("--deck-id")
    checker = commands.add_parser("check")
    checker.add_argument("notes")
    checker.add_argument("deck", nargs="?")
    checker.add_argument("--ids")
    checker.add_argument("--deck-id")
    args = parser.parse_args()
    {"list": command_list, "draft": command_draft, "check": command_check}[args.command](args)


if __name__ == "__main__":
    main()
