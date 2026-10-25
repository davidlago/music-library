#!/usr/bin/env python3
"""Renders the user guide (docs/guide/*.md) into the website's Docs section (build/site/docs/*.html).

Standard library only, so it runs on the Mac and on GitHub's Ubuntu runner without installing anything. It understands
the Markdown the guide uses, and only that: ATX headings, paragraphs, bullet and numbered lists (nested by indentation),
tables, fenced code, block quotes, images, links, **bold**, *italic* and `code`. Inline HTML is escaped.

Links are rewritten for the site: other guide pages (`search.md#filters`) become `.html`, screenshots
(`../screenshots/album.png`) the site's WebP copies, and other repository files GitHub links.

Usage: scripts/render-docs.py <out dir>   (scripts/build-site.sh calls it with build/site/docs)
"""
import html
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUIDE = ROOT / "docs" / "guide"
REPO = "https://github.com/davidlago/music-library/blob/main/"


def slug(text):
    """GitHub's heading anchors: lowercase, punctuation dropped, spaces to hyphens."""
    text = re.sub(r"<[^>]+>", "", text).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def rewrite_link(url):
    if re.match(r"^[a-z]+:", url) or url.startswith("#"):
        return url
    path, _, anchor = url.partition("#")
    anchor = "#" + anchor if anchor else ""
    if path.startswith("../screenshots/") and path.endswith(".png"):
        return "../screenshots/" + Path(path).stem + ".webp" + anchor
    if "/" not in path and path.endswith(".md"):
        page = "index" if path == "README.md" else path[:-3]
        return page + ".html" + anchor
    # Anything else in the repository: link to it on GitHub.
    target = (GUIDE / path).resolve().relative_to(ROOT)
    return REPO + str(target) + anchor


def inline(text):
    """Escapes text and applies inline Markdown. Code spans are cut out first so nothing inside them is touched."""
    codes = []

    def keep_code(m):
        codes.append("<code>" + html.escape(m.group(1)) + "</code>")
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"`([^`]+)`", keep_code, text)
    text = html.escape(text, quote=False)

    def image(m):
        return f'<img src="{html.escape(rewrite_link(m.group(2)))}" alt="{html.escape(m.group(1))}" loading="lazy">'

    def link(m):
        url = rewrite_link(m.group(2))
        external = ' rel="noopener"' if url.startswith("http") and "davidlago.github.io" not in url else ""
        return f'<a href="{html.escape(url)}"{external}>{m.group(1)}</a>'

    text = re.sub(r"!\[([^\]]*)\]\(([^)\s]+)\)", image, text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", text)
    return re.sub(r"\x00(\d+)\x00", lambda m: codes[int(m.group(1))], text)


LIST_ITEM = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")


def render_list(lines, i, indent):
    """Renders the list starting at lines[i] (items indented by `indent`); returns (html, next index)."""
    ordered = LIST_ITEM.match(lines[i]).group(2)[0].isdigit()
    out = ["<ol>" if ordered else "<ul>"]
    while i < len(lines):
        m = LIST_ITEM.match(lines[i])
        if not m or len(m.group(1)) != indent:
            break
        text = [m.group(3)]
        child = ""
        i += 1
        while i < len(lines) and lines[i].strip():
            sub = LIST_ITEM.match(lines[i])
            if sub and len(sub.group(1)) > indent:
                block, i = render_list(lines, i, len(sub.group(1)))
                child += block
            elif sub:
                break
            else:
                text.append(lines[i].strip())
                i += 1
        # A blank line between items of the same list doesn't end it.
        if i < len(lines) and not lines[i].strip() and i + 1 < len(lines):
            nxt = LIST_ITEM.match(lines[i + 1])
            if nxt and len(nxt.group(1)) >= indent:
                i += 1
                if len(nxt.group(1)) > indent:
                    block, i = render_list(lines, i, len(nxt.group(1)))
                    child += block
        out.append("<li>" + inline(" ".join(text)) + child + "</li>")
    out.append("</ol>" if ordered else "</ul>")
    return "\n".join(out), i


def render_table(rows):
    cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
    head, body = cells[0], cells[2:]
    out = ['<div class="table-wrap"><table>', "<thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead>", "<tbody>"]
    for r in body:
        out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>")
    out.append("</tbody></table></div>")
    return "\n".join(out)


def render(markdown):
    """Returns (title, body html, [(level, text, id)] for the page's table of contents)."""
    lines = markdown.splitlines()
    out, toc, title = [], [], ""
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
        elif line.startswith("```"):
            i += 1
            code = []
            while i < len(lines) and not lines[i].startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            out.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
        elif m := re.match(r"^(#{1,4})\s+(.*)$", line):
            level, text = len(m.group(1)), m.group(2).strip()
            if level == 1:
                title = text
                out.append(f"<h1>{inline(text)}</h1>")
            else:
                anchor = slug(text)
                toc.append((level, text, anchor))
                out.append(f'<h{level} id="{anchor}"><a class="anchor" href="#{anchor}" aria-hidden="true">#</a>{inline(text)}</h{level}>')
            i += 1
        elif line.lstrip().startswith("|"):
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                rows.append(lines[i])
                i += 1
            out.append(render_table(rows))
        elif line.startswith(">"):
            quote = []
            while i < len(lines) and lines[i].startswith(">"):
                quote.append(lines[i][1:].strip())
                i += 1
            out.append('<aside class="note"><p>' + inline(" ".join(quote)) + "</p></aside>")
        elif LIST_ITEM.match(line):
            block, i = render_list(lines, i, len(LIST_ITEM.match(line).group(1)))
            out.append(block)
        else:
            para = []
            while i < len(lines) and lines[i].strip() and not re.match(r"^(#{1,4}\s|```|>|\s*\|)", lines[i]) and not LIST_ITEM.match(lines[i]):
                para.append(lines[i].strip())
                i += 1
            text = " ".join(para)
            if re.fullmatch(r"!\[[^\]]*\]\([^)\s]+\)", text):
                out.append('<figure class="doc-shot">' + inline(text) + "</figure>")
            else:
                out.append("<p>" + inline(text) + "</p>")
    return title, "\n".join(out), toc


def pages():
    """The guide's pages in the order its index lists them, then any others."""
    index = (GUIDE / "README.md").read_text()
    order = ["README.md"] + re.findall(r"\]\(([\w-]+\.md)\)", index)
    seen = []
    for name in order + sorted(p.name for p in GUIDE.glob("*.md")):
        if name not in seen and (GUIDE / name).exists():
            seen.append(name)
    return seen


def main():
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    template = (ROOT / "site" / "docs-template.html").read_text()
    names = pages()
    titles = {}
    rendered = {}
    for name in names:
        titles[name], body, toc = render((GUIDE / name).read_text())
        rendered[name] = (body, toc)

    for name in names:
        body, toc = rendered[name]
        page = "index" if name == "README.md" else name[:-3]
        nav = []
        for other in names:
            href = "index.html" if other == "README.md" else other[:-3] + ".html"
            label = "Overview" if other == "README.md" else titles[other]
            current = ' aria-current="page"' if other == name else ""
            nav.append(f'<li><a href="{href}"{current}>{html.escape(label)}</a></li>')
        on_page = "".join(
            f'<li class="l{level}"><a href="#{anchor}">{inline(text)}</a></li>' for level, text, anchor in toc if level <= 3
        )
        position = names.index(name)
        pager = []
        if position > 0:
            prev = names[position - 1]
            href = "index.html" if prev == "README.md" else prev[:-3] + ".html"
            pager.append(f'<a class="prev" href="{href}"><small>Previous</small>{html.escape(titles[prev] if prev != "README.md" else "Overview")}</a>')
        if position + 1 < len(names):
            nxt = names[position + 1]
            pager.append(f'<a class="next" href="{nxt[:-3]}.html"><small>Next</small>{html.escape(titles[nxt])}</a>')
        title = "Music Library Docs" if name == "README.md" else f"{titles[name]} · Music Library Docs"
        source = REPO + "docs/guide/" + name
        page_html = (
            template.replace("{{title}}", html.escape(title))
            .replace("{{nav}}", "\n".join(nav))
            .replace("{{toc}}", on_page)
            .replace("{{body}}", body)
            .replace("{{pager}}", "".join(pager))
            .replace("{{source}}", source)
        )
        (out_dir / f"{page}.html").write_text(page_html)
    print(f"Rendered {len(names)} docs pages into {out_dir}")


if __name__ == "__main__":
    main()
