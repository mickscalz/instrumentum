#!/usr/bin/env python3
"""Writes the in-app updater's feed (a Sparkle appcast) for one build.

    python3 Scripts/make-appcast.py <build> <zip> "<sign_update output>" <release-notes.md> "<headline>" <out.xml>

The heading is the newest notes' `<!-- title: … -->` line when there is one, else <headline> (the commit subject).

The appcast has one item, the build: its zip on the build's GitHub release, the zip's EdDSA signature and length, and
the release notes (the newest part of Packaging/release-notes.md, before `<!-- older -->`) as the "what's new" HTML the
update window shows. Sparkle only needs the newest build to offer it.
"""
import email.utils
import html
import os
import re
import sys


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", text)
    return text


def markdown_to_html(md):
    out, in_list = [], False
    for block in re.split(r"\n\s*\n", md.strip()):
        lines = [l for l in block.split("\n") if l.strip()]
        if not lines:
            continue
        if all(re.match(r"\s*- ", l) for l in lines):
            out.append("<ul>" + "".join(f"<li>{inline(re.sub(r'^\s*- ', '', l))}</li>" for l in lines) + "</ul>")
        elif re.match(r"\s*- ", lines[0]) is None and any(re.match(r"\s*- ", l) for l in lines):
            head = [l for l in lines if not re.match(r"\s*- ", l)]
            items = [l for l in lines if re.match(r"\s*- ", l)]
            out.append("<p>" + inline(" ".join(head)) + "</p>")
            out.append("<ul>" + "".join(f"<li>{inline(re.sub(r'^\s*- ', '', l))}</li>" for l in items) + "</ul>")
        else:
            out.append("<p>" + inline(" ".join(l.strip() for l in lines)) + "</p>")
    return "\n".join(out)


def main():
    build, zip_path, signed, notes_path, headline, out_path = sys.argv[1:7]
    sig = re.search(r'sparkle:edSignature="([^"]+)"', signed)
    if not sig:
        sys.exit(f"no EdDSA signature in: {signed!r}")
    length = os.path.getsize(zip_path)
    notes = open(notes_path, encoding="utf-8").read().split("<!-- older -->")[0]
    # A `<!-- title: … -->` line in the newest notes is the update window's heading (the build's commit subject is only
    # the fallback: it may be a technical line, as build 159's was).
    title = re.search(r"<!--\s*title:\s*(.+?)\s*-->", notes)
    if title:
        headline = title.group(1)
        notes = notes.replace(title.group(0), "")
    # The install paragraph is for the release page, not the update window.
    notes = "\n\n".join(b for b in re.split(r"\n\s*\n", notes) if not b.startswith("**Install:**"))
    body = f"<h3>{inline(headline)}</h3>\n" + markdown_to_html(notes)
    url = f"https://github.com/mickscalz/instrumentum/releases/download/build-{build}/{os.path.basename(zip_path)}"
    item = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>In Strum Meants</title>
    <item>
      <title>Build {build}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>0.1.{build}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
<style>body {{ font: 13px -apple-system, sans-serif; }} li {{ margin-bottom: 4px; }}</style>
{body}
      ]]></description>
      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{sig.group(1)}"/>
    </item>
  </channel>
</rss>
"""
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(item)
    print(f"appcast: build {build}, {length} bytes, {url}")


if __name__ == "__main__":
    main()
