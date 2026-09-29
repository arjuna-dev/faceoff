#!/usr/bin/env python3
"""Build a local HTML inspection page for one whole-character workflow run.

The page walks through every step in order: character generation,
clean segmentation, pivots, part isolation, repair detection, part repair and
the assembled rest pose. Every model call shows its exact ordered request (text
and images) next to its outputs so a human can see what needs improvement.
"""

from __future__ import annotations

import argparse
import html
import json
import os
from pathlib import Path
from typing import Any


def _load(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None


class Page:
    def __init__(self, run: Path) -> None:
        self.run = run.resolve()
        self.chunks: list[str] = []

    def rel(self, path: str | Path) -> str:
        return html.escape(os.path.relpath(Path(path).resolve(), self.run))

    def add(self, text: str) -> None:
        self.chunks.append(text)

    def image(self, path: str | Path, caption: str, transparent: bool = False) -> str:
        path = Path(path)
        if not path.is_absolute():
            path = self.run / path
        if not path.is_file():
            return f'<figure class="missing"><div>not produced</div><figcaption>{html.escape(caption)}</figcaption></figure>'
        src = self.rel(path)
        cls = ' class="checker"' if transparent else ""
        return (f'<figure><a href="{src}" target="_blank"><img{cls} src="{src}" loading="lazy"></a>'
                f'<figcaption>{html.escape(caption)}</figcaption></figure>')

    def gallery(self, figures: list[str]) -> str:
        return '<div class="gallery">' + "".join(figures) + "</div>"

    def request(self, record: dict[str, Any] | None, fallback: list[dict[str, str]], note: str = "") -> str:
        """Show the ordered request exactly as sent: text blocks and image thumbnails."""
        parts = record["parts"] if record else fallback
        model = record.get("model") if record else None
        header = f"Request sent to <b>{html.escape(model)}</b>" if model else "Request (reconstructed from saved files)"
        rows = []
        for index, part in enumerate(parts, 1):
            if "text" in part:
                rows.append(f'<div class="req-part"><span class="tag">{index} · text</span>'
                            f'<pre>{html.escape(part["text"])}</pre></div>')
            else:
                rows.append(f'<div class="req-part"><span class="tag">{index} · image</span>'
                            + self.image(part["image"], Path(part["image"]).name) + "</div>")
        extra = f'<p class="note">{html.escape(note)}</p>' if note else ""
        return f'<details class="request" open><summary>{header}</summary>{extra}{"".join(rows)}</details>'

    def issues(self, items: list[str]) -> str:
        if not items:
            return '<p class="ok">No automatic issues raised.</p>'
        return '<ul class="issues">' + "".join(f"<li>{html.escape(item)}</li>" for item in items) + "</ul>"

    def section(self, anchor: str, number: int, title: str, body: str) -> None:
        self.add(f'<section id="{anchor}"><h2><span class="num">{number}</span>{html.escape(title)}</h2>{body}</section>')


CSS = """
:root { --bg:#f6f6f4; --panel:#ffffff; --ink:#1d1f23; --muted:#626873; --line:#dcdcd6;
  --accent:#6b3fd4; --bad:#b3261e; --good:#1f7a3a; --tag:#eeeafa; --code:#f1f1ee; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --bg:#15171b; --panel:#1e2126; --ink:#e8e8e6; --muted:#9aa0aa; --line:#30343b;
  --accent:#a98bff; --bad:#ff8a80; --good:#7fd69a; --tag:#2b2540; --code:#23262c; } }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system, system-ui, sans-serif; }
header { padding:24px 16px 8px; max-width:1400px; margin:auto; }
header h1 { margin:0 0 4px; font-size:22px; }
header p { margin:0; color:var(--muted); }
nav { position:sticky; top:0; z-index:2; background:var(--bg); border-bottom:1px solid var(--line);
  padding:8px 16px; display:flex; gap:14px; flex-wrap:wrap; font-size:14px; }
nav a { color:var(--accent); text-decoration:none; }
main { max-width:1400px; margin:auto; padding:0 16px 48px; }
section { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:16px; margin:18px 0; }
h2 { margin:0 0 12px; font-size:18px; display:flex; align-items:center; gap:10px; }
h3 { font-size:15px; margin:18px 0 8px; }
.num { background:var(--accent); color:#fff; border-radius:50%; width:26px; height:26px;
  display:inline-flex; align-items:center; justify-content:center; font-size:14px; }
.gallery { display:flex; flex-wrap:wrap; gap:12px; }
figure { margin:0; width:260px; max-width:100%; }
figure img { width:100%; border:1px solid var(--line); border-radius:6px; display:block; background:#888; }
figure.missing div { height:120px; border:1px dashed var(--line); border-radius:6px; display:flex;
  align-items:center; justify-content:center; color:var(--muted); }
.checker { background-color:#bbb !important; background-image:
  linear-gradient(45deg,#999 25%,transparent 25%), linear-gradient(-45deg,#999 25%,transparent 25%),
  linear-gradient(45deg,transparent 75%,#999 75%), linear-gradient(-45deg,transparent 75%,#999 75%);
  background-size:16px 16px; background-position:0 0,0 8px,8px -8px,-8px 0; }
figcaption { font-size:12px; color:var(--muted); margin-top:4px; word-break:break-all; }
pre { background:var(--code); padding:10px; border-radius:6px; white-space:pre-wrap; word-wrap:break-word;
  font:12.5px/1.45 ui-monospace, Menlo, monospace; margin:4px 0 0; max-height:520px; overflow:auto; }
.request { border:1px solid var(--line); border-radius:8px; padding:8px 12px; margin:8px 0 14px; }
.request summary { cursor:pointer; font-weight:600; }
.req-part { margin:10px 0; }
.req-part figure { width:200px; }
.tag { font-size:11px; background:var(--tag); color:var(--accent); padding:2px 6px; border-radius:4px; }
.issues li { color:var(--bad); }
.ok { color:var(--good); }
.note { color:var(--muted); font-size:13px; }
table { border-collapse:collapse; font-size:13px; width:100%; overflow-x:auto; display:block; }
td, th { border-bottom:1px solid var(--line); padding:4px 8px; text-align:left; white-space:nowrap; }
.status-REPAIRED { color:var(--good); font-weight:600; }
.status-REJECTED { color:var(--bad); font-weight:600; }
.part { border-top:1px solid var(--line); padding-top:12px; margin-top:12px; }
"""


def _text(path: Path) -> list[dict[str, str]]:
    return [{"text": path.read_text(encoding="utf-8")}] if path.is_file() else []


def build(run: Path) -> Path:
    page = Page(run)
    run = page.run
    workflow = _load(run / "workflow.json") or {}
    plan = _load(run / "plan.json") or {}
    analysis = _load(run / "inspection/analysis.json")
    inspection = run / "inspection"

    # 1. Character generation
    fallback = _text(run / "character-prompt.txt")
    note = ""
    if plan.get("resume_character") and not (run / "character.request.json").is_file():
        note = "Resumed from an earlier run; the prompt shown is the one that generated this image."
    body = page.request(_load(run / "character.request.json"), fallback, note)
    frame = plan.get("character_frame_removed")
    figures = [page.image("character.png", "character.png (used by the next steps)")]
    if frame:
        body += page.issues([f"The model drew a {frame['frame_px']}px frame around the canvas; code replaced "
                             "it with the background. The raw output is shown next to the result."])
        figures.insert(0, page.image("character-raw.png", "character-raw.png (model output)"))
    body += page.gallery(figures)
    page.section("character", 1, "Character generation", body)

    # 2. Clean segmentation
    body = page.request(_load(run / "segmentation.request.json"),
                        _text(run / "segmentation-prompt.txt") + [{"image": str(run / "character.png")}])
    body += page.gallery([page.image("segmentation.png", "segmentation.png (model output)"),
                          page.image(inspection / "segmentation-decoded.png", "decoded palette"),
                          page.image(inspection / "part-ownership.png", "ownership snapped to the artwork"),
                          page.image(inspection / "inspection.png", "original / re-assembled / map mismatch")])
    if analysis:
        snapping = analysis.get("segmentation", {}).get("snapping")
        if snapping:
            body += (f'<p class="note">Snapping: {snapping["relabeled_to_nearest_part"]} artwork pixels took the '
                     f'nearest map label; {snapping["merged_fragment_pixels"]} stray fragment pixels were merged '
                     "into their neighboring part.</p>")
        for label, size in analysis.get("segmentation", {}).get("guide_maps_resampled", {}).items():
            body += (f'<p class="note">The {html.escape(label)} map came back at {size["from"][0]}x{size["from"][1]} '
                     f'and was resized to the source size {size["to"][0]}x{size["to"][1]} with nearest neighbor '
                     "(guide maps only; the artwork is never resampled).</p>")
        body += "<h3>Automatic checks</h3>" + page.issues(analysis.get("issues", []))
    page.section("segmentation", 2, "Segmentation", body)

    # 3. Pivots
    body = page.request(_load(run / "pivots.request.json"),
                        _text(run / "pivots-prompt.txt") + [{"image": str(run / "segmentation.png")}])
    body += page.gallery([page.image("pivots.png", "pivots.png (model's dots, a hint only)"),
                          page.image(inspection / "pivots-final.png",
                                     "pivots the rig uses (unused model dots crossed out in red)")])
    if analysis:
        rows = "".join(
            f"<tr><td>{html.escape(name)}</td><td>{joint['center']}</td>"
            f"<td>{' + '.join(joint['connects'])}</td><td>{html.escape(joint.get('method', ''))}</td>"
            f"<td>{joint.get('model_dot')}</td></tr>"
            for name, joint in analysis.get("joints", {}).items())
        body += (f"<h3>{len(analysis.get('joints', {}))} pivots used</h3><table><tr><th>joint</th><th>page xy</th>"
                 f"<th>connects</th><th>how it was set</th><th>model dot</th></tr>{rows}</table>")
        corrections = analysis.get("segmentation", {}).get("snapping", {})
        fixes = corrections.get("bone_corrections", {})
        if corrections.get("near_far_swapped") or fixes:
            items = [f"near/far swapped for the {chain}" for chain in corrections.get("near_far_swapped", [])]
            items += [f"{key}: {value} px" for key, value in fixes.items()]
            body += ("<h3>Ownership fixed with the skeleton</h3><ul>"
                     + "".join(f"<li>{html.escape(item)}</li>" for item in items) + "</ul>")
    page.section("pivots", 3, "Pivots", body)

    # 4. Part isolation
    if analysis:
        figures = [page.image(meta["image"], f"{name} · {meta['crop_size'][0]}x{meta['crop_size'][1]} · "
                              f"{len(meta.get('pivots', {}))} pivots", transparent=True)
                   for name, meta in analysis["parts"].items() if meta.get("status") == "EXTRACTED"]
        overlaps = analysis.get("joint_overlaps", [])
        body = ""
        if overlaps:
            body += ('<p class="note">At every joint, the part drawn underneath also carries its neighbor\'s '
                     "artwork inside the white circle, so a rotation shows overlap instead of a hard cut or gap; "
                     "the part on top stays exact. Circle radius is 1.3x "
                     "the rotating child part's half-width near the pivot, clamped to 32-90 px; near and far joints "
                     "share the larger radius.</p>")
            body += page.gallery([page.image(inspection / "joint-overlaps.png", "joint overlap circles")])
            rows = "".join(f"<tr><td>{html.escape(item['joint'])}</td><td>{item['radius_px']}</td>"
                           f"<td>{' + '.join(item['connects'])}</td><td>{html.escape(item.get('extended_part', ''))}</td>"
                           f"<td>{item['shared_pixels']}</td></tr>"
                           for item in overlaps)
            body += ("<table><tr><th>joint</th><th>radius (px)</th><th>joint of</th><th>extended part</th>"
                     "<th>overlap pixels</th></tr>"
                     f"{rows}</table><h3>Parts (with joint overlaps)</h3>")
        absent = [name for name, meta in analysis["parts"].items() if meta.get("status") == "ABSENT"]
        if absent:
            body += f'<p class="note">Optional parts not present on this character: {html.escape(", ".join(absent))}.</p>'
        body += page.gallery(figures)
        body += page.gallery([page.image(inspection / "reconstructed-on-magenta.png",
                                         "all isolated parts re-assembled (before repair)")])
    else:
        body = "<p>No analysis produced.</p>"
    page.section("isolation", 4, "Part isolation", body)

    # 5. Repair detection
    detection = _load(inspection / "repair-detection/detection.json")
    if detection:
        body = (f'<p class="note">No model call. Method: {html.escape(detection["method"])}. '
                f'Thresholds: {html.escape(json.dumps(detection["thresholds"]))}. In each overlay the part is '
                "white, other parts grey, and the area sent for completion magenta.</p>")
        flagged = detection["parts_needing_repair"]
        if flagged:
            rows = "".join(f"<tr><td>{html.escape(name)}</td><td style='white-space:normal'>"
                           f"{html.escape(entry['reason'])}</td><td>{entry['fill_pixels']}</td></tr>"
                           for name, entry in flagged.items())
            body += ("<table><tr><th>part</th><th>why</th><th>pixels to complete</th></tr>"
                     f"{rows}</table>")
            body += page.gallery([page.image(entry["overlay"], name) for name, entry in flagged.items()])
        else:
            body += '<p class="ok">No part needs repair.</p>'
    else:
        body = "<p>Repair detection did not run.</p>"
    page.section("detection", 5, "Repair detection", body)

    # 6. Part repair
    repair_dir = inspection / "repair"
    report = _load(repair_dir / "repair-report.json")
    body = ""
    if report:
        for entry in report["parts"]:
            name = entry["part"]
            folder = repair_dir / name
            status = entry.get("status", "REPAIRED")
            stats = {key: entry[key] for key in ("added_foreground_pixels", "marked_pixels",
                                                 "marked_pixels_left_empty", "ignored_paint_outside_marked_area",
                                                 "alignment_shift_px", "aligned_mean_difference") if key in entry}
            body += (f'<div class="part"><h3>{html.escape(name)} · '
                     f'<span class="status-{status}">{status}</span></h3>')
            if entry.get("error"):
                body += page.issues([entry["error"]])
            body += page.request(_load(folder / "repair-raw.request.json"),
                                 _text(folder / "repair-prompt.txt") + [{"image": str(folder / "repair-input.png")}])
            body += page.gallery([page.image(folder / "repair-raw.png", "model output"),
                                  page.image(folder / "accepted-fill-mask.png", "new pixels accepted by code"),
                                  page.image(folder / "repaired-part.png", "repaired part", transparent=True)])
            if stats:
                body += f"<pre>{html.escape(json.dumps(stats, indent=1))}</pre>"
            body += "</div>"
        if report["parts"]:
            body += "<h3>All parts after repair</h3>" + page.gallery(
                [page.image(repair_dir / "repaired-parts-sheet.png", "repaired parts sheet")])
        else:
            body += '<p class="ok">Nothing needed repair.</p>'
    else:
        body = "<p>Repair stage did not run.</p>"
    page.section("repair", 6, "Part repair", body)

    # 7. Assembly for human verification
    poses = repair_dir / "poses" if (repair_dir / "poses/rest.png").is_file() else inspection / "poses"
    body = ('<p class="note">The rest pose re-assembles the final parts at their pivots. '
            'It should match the original character; the moved poses reveal hidden gaps.</p>')
    if workflow.get("assembly_reason"):
        body += page.issues([workflow["assembly_reason"]])
    body += page.gallery([page.image("character.png", "original character"),
                          page.image(poses / "rest.png", "assembled rest pose", transparent=True),
                          page.image(poses / "rest-joints.png", "rest pose with pivots", transparent=True)])
    body += page.gallery([page.image(poses / "pose-sheet.png", "test poses")])
    page.section("assembly", 7, "Assembly for human verification", body)

    status = workflow.get("status", "UNKNOWN")
    error = workflow.get("error")
    summary = f"Status: <b>{html.escape(status)}</b>" + (f" · {html.escape(error)}" if error else "")
    nav = "".join(f'<a href="#{anchor}">{label}</a>' for anchor, label in (
        ("character", "1 Character"), ("segmentation", "2 Segmentation"), ("pivots", "3 Pivots"),
        ("isolation", "4 Isolation"), ("detection", "5 Repair detection"), ("repair", "6 Repair"),
        ("assembly", "7 Assembly")))
    document = (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
                f'<meta name="viewport" content="width=device-width, initial-scale=1">'
                f"<title>Rig run {html.escape(run.name)}</title><style>{CSS}</style></head><body>"
                f"<header><h1>{html.escape(run.name)}</h1><p>{summary}</p></header>"
                f"<nav>{nav}</nav><main>{''.join(page.chunks)}</main></body></html>")
    output = run / "report.html"
    output.write_text(document, encoding="utf-8")
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", type=Path)
    print(build(parser.parse_args().run_dir))
