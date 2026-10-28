"""Local PDF layout extraction for ReDZ. Input PDFs are never modified."""
import contextlib
from datetime import datetime, timezone
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
from statistics import median
import sys
import unicodedata
import uuid
import zipfile

FORMAT = "pdf-reflow-3"
MAX_BYTES = 150_000_000
MAX_PAGES = 300


def emit(kind, **values):
    print(json.dumps({"type": kind, **values}), flush=True)


def clean(text):
    return text.translate(str.maketrans({"ﬁ": "fi", "ﬂ": "fl", "ﬀ": "ff", "ﬃ": "ffi", "ﬄ": "ffl", "\u00ad": "", "\u00a0": " "}))


def line_text(line):
    result, previous = "", None
    for span in line.get("spans") or []:
        text = clean(span.get("text", ""))
        if not text:
            continue
        if previous and result and not result[-1].isspace() and not text[0].isspace():
            gap = span["bbox"][0] - previous["bbox"][2]
            if gap > max(0.7, min(span["size"], previous["size"]) * 0.15):
                result += " "
        result += text
        previous = span
    return re.sub(r"\s+", " ", result).strip()


def join_text(left, right, vocabulary):
    if not left:
        return right
    if re.search(r"[A-Za-z]-$", left) and re.match(r"[a-z]", right):
        prefix = re.search(r"[A-Za-z-]+$", left).group()[:-1]
        suffix = re.match(r"[a-z]+", right).group()
        keep = (prefix + "-" + suffix).lower() in vocabulary or "-" in prefix
        return left + right if keep else left[:-1] + right
    return left + " " + right


def box_text(box, vocabulary):
    text = ""
    for line in box.get("textlines") or []:
        text = join_text(text, line_text(line), vocabulary)
    return text.strip()


def crop(page, box, target):
    import pymupdf
    rect = pymupdf.Rect(*(box[k] for k in ("x0", "y0", "x1", "y1")))
    rect = (rect + (-2, -2, 2, 2)) & page.rect
    if rect.is_empty or rect.is_infinite:
        raise ValueError("A PDF image has invalid bounds.")
    scale = min(2.5, 3000 / max(rect.width, rect.height))
    page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), clip=rect, alpha=False).save(target)


def order_columns(boxes, width):
    """Read each column to its bottom; full-width blocks separate column bands.

    The layout model sometimes starts a new horizontal band at a short heading,
    jumping into the other column. Only a block spanning the gutter may do that.
    Uncertain and single-column pages retain the model's existing order.
    """
    prose = [b for b in boxes if b.get("boxclass") == "text" and
             width * .23 < b["x1"] - b["x0"] < width * .48]
    left = [b for b in prose if b["x1"] < width * .53]
    right = [b for b in prose if b["x0"] > width * .47]
    if len(left) < 2 or len(right) < 2:
        return boxes
    edge_left, edge_right = median(b["x1"] for b in left), median(b["x0"] for b in right)
    overlap = min(max(b["y1"] for b in left), max(b["y1"] for b in right)) - max(min(b["y0"] for b in left), min(b["y0"] for b in right))
    if not width * .01 < edge_right - edge_left < width * .12 or overlap < 40:
        return boxes
    gutter = (edge_left + edge_right) / 2
    spanning = sorted([b for b in boxes if b["x0"] < gutter - 3 and b["x1"] > gutter + 3], key=lambda b: (b["y0"], b["x0"]))
    column = [b for b in boxes if not any(b is s for s in spanning)]
    ordered = []
    def band(items):
        return sorted(items, key=lambda b: (0 if (b["x0"] + b["x1"]) / 2 < gutter else 1, b["y0"], b["x0"]))
    for wide in spanning:
        above = [b for b in column if (b["y0"] + b["y1"]) / 2 < wide["y0"]]
        ordered.extend(band(above))
        column = [b for b in column if not any(b is a for a in above)]
        ordered.append(wide)
    ordered.extend(band(column))
    return ordered


def mark_margin_notes(page, boxes):
    """Recover small footnote continuations beneath a drawn footnote divider."""
    body_sizes = [span["size"] for box in boxes if box.get("boxclass") == "text"
                  for line in box.get("textlines") or [] for span in line.get("spans") or []
                  if len(span.get("text", "")) > 20]
    if not body_sizes:
        return
    body_size = median(body_sizes)
    rules = []
    for drawing in page.get_drawings():
        for item in drawing["items"]:
            if item[0] == "l":
                a, b = item[1], item[2]
                if abs(a.y - b.y) < 1 and page.rect.height * .65 < a.y and 20 < abs(b.x - a.x) < page.rect.width * .2:
                    rules.append((min(a.x, b.x), a.y))
    for box in boxes:
        sizes = [span["size"] for line in box.get("textlines") or [] for span in line.get("spans") or []]
        if box.get("boxclass") == "text" and sizes and median(sizes) < body_size * .94 and any(abs(box["x0"] - x) < 20 and box["y0"] > y for x, y in rules):
            box["boxclass"] = "footnote"


def repair_flow(blocks, vocabulary):
    """Keep floating figures and margin notes from splitting a prose sentence."""
    ordered, notes = [], []
    for entry in blocks:
        kind, text = entry["kind"], entry.get("text", "")
        if kind == "footnote":
            if notes and re.match(r"[a-z]", text) and re.search(r"[a-z,-]$", notes[-1]["text"]):
                notes[-1]["text"] = join_text(notes[-1]["text"], text, vocabulary)
                continue
            notes.append(entry)
            continue
        if kind == "section-header" and re.match(r"[a-z]", text) and text.endswith("."):
            entry["kind"] = kind = "text"
        if kind == "text" and re.match(r"(?:Figure|Fig\.|Table)\s+\d+[.:]", text):
            entry["kind"] = kind = "caption"
        if kind == "text" and re.match(r"[a-z]", text):
            previous = len(ordered) - 1
            while previous >= 0 and ordered[previous]["kind"] in {"picture", "table", "caption"}:
                previous -= 1
            if previous >= 0:
                paragraph = ordered[previous]
                if paragraph["kind"] == "text" and paragraph["page"] == entry["page"] and re.search(r"[a-z,-]$", paragraph["text"]):
                    paragraph["text"] = join_text(paragraph["text"], text, vocabulary)
                    continue
        ordered.append(entry)
    if notes:
        ordered.append({"kind": "section-header", "page": notes[0]["page"], "text": "Footnotes"})
        ordered.extend(notes)
    return ordered


def valid_cache(root, digest):
    try:
        if root.is_symlink():
            return False
        manifest = json.loads((root / "manifest.json").read_text())
        if manifest["format"] != FORMAT or manifest["sha256"] != digest:
            return False
        for relative in manifest["files"]:
            path = root / relative
            if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or not path.is_file():
                return False
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def make_epub(root, title, toc, images, digest):
    escape = html.escape
    nav = '<ol>' + ''.join(f'<li><a href="article.xhtml#{escape(item["anchor"])}">{escape(item["title"])}</a></li>' for item in toc) + '</ol>'
    nav_doc = f'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc" id="toc">{nav}</nav></body></html>'
    manifest = '<item id="article" href="article.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    manifest += ''.join(f'<item id="image{i}" href="{name}" media-type="image/png"/>' for i, name in enumerate(images))
    modified = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    package = f'<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">urn:sha256:{digest}</dc:identifier><dc:title>{escape(title)}</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">{modified}</meta></metadata><manifest>{manifest}</manifest><spine><itemref idref="article"/></spine></package>'
    with zipfile.ZipFile(root / "Reading.epub", "x") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("content.opf", package, compress_type=zipfile.ZIP_DEFLATED)
        archive.writestr("nav.xhtml", nav_doc, compress_type=zipfile.ZIP_DEFLATED)
        for name in ["article.xhtml", *images]:
            archive.write(root / name, name, compress_type=zipfile.ZIP_DEFLATED)


def convert(source, library):
    source = source.resolve(strict=True)
    if not source.is_file() or source.stat().st_size > MAX_BYTES:
        raise ValueError("Choose a PDF smaller than 150 MB.")
    with source.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest()
    cache = library.resolve() / "PDF"
    cache.mkdir(parents=True, exist_ok=True)
    root = cache / (digest + "-" + FORMAT)
    for candidate in [root, *sorted(cache.glob(root.name + "-*"))]:
        if valid_cache(candidate, digest):
            emit("ready", root=str(candidate), cached=True)
            return
    if root.exists():
        root = cache / (root.name + "-" + uuid.uuid4().hex)
    root.mkdir(exist_ok=False)
    (root / "images").mkdir()
    # Libraries may print diagnostics; stdout is reserved for progress messages.
    with contextlib.redirect_stdout(sys.stderr):
        import pymupdf
        import pymupdf4llm
    shutil.copy2(source, root / "original.pdf")
    with (root / "original.pdf").open("rb") as handle:
        if hashlib.file_digest(handle, "sha256").hexdigest() != digest:
            raise ValueError("The PDF changed while opening. Try again.")
    document = pymupdf.open(root / "original.pdf")
    if not document.is_pdf or document.needs_pass:
        raise ValueError("Choose an unlocked PDF.")
    if not 0 < len(document) <= MAX_PAGES:
        raise ValueError("Choose a PDF with 1–300 pages.")
    raw_text = [page.get_text() for page in document]
    if sum(sum(character.isalpha() for character in text) for text in raw_text) < 80:
        raise ValueError("This PDF needs OCR. Choose a PDF with selectable text.")
    vocabulary = set(re.findall(r"[a-z]+(?:-[a-z]+)+", clean(" ".join(raw_text)).lower()))
    title = (document.metadata.get("title") or "").strip()
    if not title or title.lower() in {"untitled", "microsoft word"}:
        title = source.stem
    blocks, images, page_anchors, headings = [], [], [], []
    stats = {"pages": len(document), "figures": 0, "tables": 0, "formulas": 0, "imagePages": []}
    for index, page in enumerate(document):
        number = index + 1
        emit("progress", page=number, total=len(document))
        with contextlib.redirect_stdout(sys.stderr):
            parsed = json.loads(pymupdf4llm.to_json(document, pages=[index], use_ocr=False, force_text=True))
        boxes = parsed["pages"][0]["boxes"]
        mark_margin_notes(page, boxes)
        boxes = order_columns(boxes, page.rect.width)
        page_anchors.append({"title": f"Page {number}", "anchor": f"pdf-page-{number}", "depth": 0})
        blocks.append({"kind": "page", "page": number, "anchor": f"pdf-page-{number}"})
        if sum(character.isalpha() for character in raw_text[index]) < 15:
            boxes = [{"x0": 0, "y0": 0, "x1": page.rect.width, "y1": page.rect.height, "boxclass": "picture"}]
            stats["imagePages"].append(number)
        for box_index, box in enumerate(boxes):
            kind = box.get("boxclass", "text")
            if kind in {"page-header", "page-footer", "page-number"}:
                continue
            text = box_text(box, vocabulary)
            bounds = [box[k] for k in ("x0", "y0", "x1", "y1")]
            entry = {"kind": kind, "page": number, "bbox": bounds, "text": text}
            if kind in {"picture", "table", "formula"}:
                name = f"images/p{number}-{box_index}.png"
                crop(page, box, root / name)
                images.append(name)
                entry["image"] = name
                stats[{"picture": "figures", "table": "tables", "formula": "formulas"}[kind]] += 1
            elif not text:
                continue
            if kind == "title" and index == 0:
                title = text
            entry["depth"] = max(0, min(2, int(box.get("header_level") or 2) - 1))
            blocks.append(entry)
    blocks = repair_flow(blocks, vocabulary)
    for entry in blocks:
        if entry["kind"] in {"title", "section-header"}:
            entry["anchor"] = f"heading-{len(headings)}"
            headings.append({"title": entry["text"], "anchor": entry["anchor"], "depth": entry.get("depth", 0)})
    content = []
    for entry in blocks:
        kind, page = entry["kind"], entry["page"]
        attributes = f'data-source-page="{page}"'
        if "anchor" in entry:
            attributes += f' id="{entry["anchor"]}"'
        if kind == "page":
            content.append(f'<span {attributes} role="doc-pagebreak" aria-label="Page {page}"></span>')
        elif "image" in entry:
            label = {"picture": "Figure", "table": "Table", "formula": "Equation"}[kind]
            content.append(f'<figure {attributes} data-pdf-kind="{kind}"><img src="{entry["image"]}" alt="{label}, page {page}"/></figure>')
        else:
            tag = "h1" if kind == "title" else "h2" if kind == "section-header" else "p"
            css = ' class="pdf-caption"' if kind == "caption" else ' class="pdf-footnote"' if kind == "footnote" else ''
            content.append(f'<{tag} {attributes}{css}>{html.escape(entry["text"])}</{tag}>')
    style = 'body{font:1em/1.6 Georgia,serif;max-width:45em;margin:auto;padding:1em}img{max-width:100%;height:auto}figure{margin:1em 0;break-inside:avoid}.pdf-caption,.pdf-footnote{font-size:.85em}h1,h2{font-family:sans-serif}span[role="doc-pagebreak"]{display:none}'
    article = f'<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>{html.escape(title)}</title><style>{style}</style></head><body>{"".join(content)}</body></html>'
    (root / "article.xhtml").write_text(article)
    toc = headings + page_anchors
    make_epub(root, title, toc, images, digest)
    manifest = {"format": FORMAT, "sha256": digest, "title": title, "chapters": [{"path": "article.xhtml", "title": title}], "contents": toc, "stats": stats,
                "files": ["article.xhtml", "original.pdf", "Reading.epub", *images]}
    (root / "layout.json").write_text(json.dumps({"blocks": blocks, "stats": stats}, ensure_ascii=False))
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False))
    document.close()
    emit("ready", root=str(root), cached=False)


if __name__ == "__main__":
    try:
        convert(Path(sys.argv[1]), Path(sys.argv[2]))
    except Exception as error:
        emit("error", message=str(error))
        sys.exit(1)
