import argparse
import os
import re
from datetime import date
from pathlib import Path
from typing import Tuple

from openai import OpenAI

SYSTEM_PROMPT = """
You are an expert technical writer and editor. You turn meeting transcripts into clean, structured meeting notes for Obsidian.

Analyze the transcript provided and produce a markdown summary that captures the key information, main topics, decisions, action items, open questions, and notable points discussed.

The output must be accurate to the transcript. Do not invent facts, decisions, action items, speaker relationships, or context not supported by the transcript.

The structure should reflect the natural flow and content of the transcript itself rather than a strictly rigid template. Use the required sections, but organize the content inside each section according to how the discussion actually unfolded.

Begin the document with YAML frontmatter.

The frontmatter must include:

```yaml
---
title: "Summary - [Short Human-Readable Title]"
created: YYYY-MM-DD
tags:
  - meeting-notes
  - summary
---
```

The `title` field must:

* Begin with `Summary - `
* Be short, useful, and human-readable
* Reflect the actual subject of the transcript
* Be safe for use as a Windows filename

After the frontmatter, repeat the title as an H1 heading.

Use clean markdown only. Do not wrap the response in code fences.

# Structure

Always include these sections:

## Executive Summary

Write one sentence only.

Maximum 25 words.

Place it directly under the `## Executive Summary` heading.

## Main Topics

This should be the most detailed section.

Identify the core topics discussed in the meeting.

For each topic:

* Use a bold topic header or clear bullet structure
* Capture the key arguments, reasoning, tradeoffs, examples, constraints, concerns, and implications
* Attribute insights to speakers when the transcript makes that clear
* Merge repeated points
* Avoid repeating the same idea across bullets
* Explain the significance of points only when the transcript directly supports it

## Action Items

Use checkbox format.

Assign ownership when clear.

If ownership is unclear, use `Unassigned`.

Convert vague statements into action items only when the transcript clearly implies a task or next step.

Do not create action items from general discussion.

# Optional and Adaptive Sections

Include the sections below only when supported by the transcript.

You may also add other high-value sections when the transcript clearly supports them and they improve the usefulness of the notes.

Do not add extra sections just to make the document look complete. Add them only when they make the notes clearer, more useful, or easier to act on.

Possible optional sections include:

## Decisions

Separate actual decisions from discussion.

Only include decisions that were clearly made.

## Key Insights

Extract 3-6 high-value insights that reflect important realizations, framing shifts, or strategic takeaways.

## What Changed

Identify shifts in thinking, direction, assumptions, or decisions compared to earlier assumptions.

Only include this section if the transcript clearly shows a change.

## Discussion Notes

Use this for useful details that do not fit cleanly into Main Topics, Decisions, or Action Items.

## Open Questions

Include unresolved questions, unclear ownership, missing information, or items needing follow-up.

## Risks / Blockers

Include risks, dependencies, blockers, constraints, or concerns raised during the discussion.

## Next Steps

Include only if the transcript clearly identifies next steps beyond the action items.

## Related Notes

Include the source transcript note if provided.

Include 2-6 Obsidian wikilinks only when they are clearly supported by explicit transcript topics.

Use topic-based wikilinks. Do not invent specific note titles that are not supported by the transcript.

Other useful adaptive sections may include:

* Background / Context
* Timeline
* Customer Requirements
* Technical Constraints
* Product Implications
* Stakeholder Concerns
* Follow-Up Needed
* Quotes / Notable Language
* Parking Lot

# Style Rules

* Keep the output high-signal and well structured
* Use headers, bullets, bold text, and other markdown elements where they improve readability
* Organize notes around the natural flow and content of the transcript
* Do not force a rigid template if the transcript does not support it
* Omit empty sections
* Keep wording concise and precise
* Preserve nuance when speakers disagree or discuss tradeoffs
* Do not add outside research, commentary, or interpretation
* Output clean markdown only
* Do not wrap the response in code fences
""".strip()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize a transcript markdown file into structured Obsidian meeting notes."
    )
    parser.add_argument("--input", required=True, help="Path to the transcript markdown file.")
    parser.add_argument("--output", help="Optional output path. Defaults to the generated title.")
    parser.add_argument("--model", default="gpt-4.1", help="OpenAI model name")
    parser.add_argument("--max-output-tokens", type=int, default=2800, help="Maximum output tokens")
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def split_frontmatter(text: str) -> Tuple[str, str]:
    if not text.startswith("---\n"):
        return "", text

    parts = text.split("\n---\n", 1)
    if len(parts) != 2:
        return "", text

    frontmatter = parts[0] + "\n---\n"
    body = parts[1]
    return frontmatter, body


def normalize_transcript_body(body: str) -> str:
    body = body.replace("\r\n", "\n").replace("\r", "\n")
    body = re.sub(r"\n{3,}", "\n\n", body)
    return body.strip()


def transcript_note_name(input_path: Path) -> str:
    return input_path.stem


def build_user_prompt(transcript_body: str, source_name: str, source_note_name: str) -> str:
    return f"""
Create structured meeting notes from the transcript below.

Requirements:
- Use markdown.
- Start with YAML frontmatter containing title, tags, source_transcript, and generated date.
- Generate a strong human-readable title based on the content.
- The title must begin with "Summary - " and must be safe for use as a Windows filename.
- Put a one-line executive summary directly under the title.
- Include a short Summary section.
- Include Main Topics when useful.
- Separate Decisions from Discussion Notes.
- Include Action Items as checkboxes.
- Include Next Steps when supported.
- Include Open Questions when supported.
- Include Related Notes with Obsidian wikilinks.
- Include [[{source_note_name}]] in Related Notes.
- Omit empty sections.
- Keep it concise and practical.

Source transcript file: {source_name}
Source transcript note name: {source_note_name}

Transcript:
{transcript_body}
""".strip()


def call_openai(model: str, prompt: str, max_output_tokens: int) -> str:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set.")

    client = OpenAI(api_key=api_key)

    response = client.responses.create(
        model=model,
        instructions=SYSTEM_PROMPT,
        input=prompt,
        max_output_tokens=max_output_tokens,
    )

    text = getattr(response, "output_text", None)
    if text:
        return text.strip()

    chunks = []
    for item in getattr(response, "output", []):
        for content in getattr(item, "content", []):
            if getattr(content, "type", "") == "output_text":
                chunks.append(getattr(content, "text", ""))

    result = "\n".join(chunk for chunk in chunks if chunk).strip()
    if not result:
        raise RuntimeError("Model returned no text output.")
    return result


def unquote_yaml_value(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1]
    return value.strip()


def extract_summary_title(summary_text: str) -> str | None:
    frontmatter, _ = split_frontmatter(summary_text)
    if frontmatter:
        for line in frontmatter.splitlines():
            match = re.match(r"^\s*title\s*:\s*(.+?)\s*$", line)
            if match:
                title = unquote_yaml_value(match.group(1))
                if title:
                    return title

    h1_match = re.search(r"(?m)^#\s+(.+?)\s*$", summary_text)
    if h1_match:
        title = h1_match.group(1).strip()
        if title:
            return title

    return None


def sanitize_windows_filename(name: str, fallback: str = "summary") -> str:
    safe = name.strip()
    safe = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "", safe)
    safe = re.sub(r"\s+", " ", safe)
    safe = safe.rstrip(" .")

    reserved_names = {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    }

    if not safe or safe.upper() in reserved_names:
        safe = fallback

    return safe[:180].rstrip(" .") or fallback


def make_unique_path(path: Path) -> Path:
    if not path.exists():
        return path

    for counter in range(2, 1000):
        candidate = path.with_name(f"{path.stem} {counter}{path.suffix}")
        if not candidate.exists():
            return candidate

    raise RuntimeError(f"Could not create a unique output path near: {path}")


def build_output_path(input_path: Path, explicit_output: str | None, summary_text: str) -> Path:
    if explicit_output:
        return Path(explicit_output)

    title = extract_summary_title(summary_text)
    if title:
        file_stem = sanitize_windows_filename(title, fallback=f"summary.{input_path.stem}")
        return make_unique_path(input_path.with_name(f"{file_stem}.md"))

    if input_path.suffix.lower() == ".md":
        fallback = input_path.with_name(f"summary.{input_path.stem}.md")
    else:
        fallback = input_path.with_name(f"summary.{input_path.name}.md")

    return make_unique_path(fallback)


def ensure_frontmatter_has_generated(summary_text: str) -> str:
    if summary_text.startswith("---\n"):
        return summary_text

    today = date.today().isoformat()

    return (
        f"---\n"
        f'title: "Summary - Untitled"\n'
        f"tags: [meeting, summary, review]\n"
        f"generated: {today}\n"
        f"---\n\n"
        f"{summary_text.strip()}\n"
    )


def main() -> None:
    args = parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        raise FileNotFoundError(f"Input file not found: {input_path}")

    raw_text = read_text(input_path)
    _, body = split_frontmatter(raw_text)
    cleaned_body = normalize_transcript_body(body)

    source_note = transcript_note_name(input_path)

    prompt = build_user_prompt(
        transcript_body=cleaned_body,
        source_name=input_path.name,
        source_note_name=source_note,
    )

    summary_md = call_openai(
        model=args.model,
        prompt=prompt,
        max_output_tokens=args.max_output_tokens,
    )

    summary_md = ensure_frontmatter_has_generated(summary_md)

    output_path = build_output_path(input_path, args.output, summary_md)
    output_path.write_text(summary_md.strip() + "\n", encoding="utf-8")
    print(f"Saved summary to: {output_path}")


if __name__ == "__main__":
    main()
