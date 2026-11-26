#!/usr/bin/env python3
"""Writes the README's tool list, the site's tool pages and its tool data from docs/, where each tool is documented once.

Each page in docs/ starts with '# <name>', a blank line, and a paragraph that summarizes the tool. From them, this writes:
  README.md                 the tool list between its tools:start and tools:end markers, one line per tool
  site/index.html           the overview's tool list, between the same markers
  site/tools/<name>/        a page per tool, the Markdown rendered as HTML
  site/data/docs.js         each tool's name, summary and kind, which the site's navigation lists

    python3 site/data/make-docs.py           write them
    python3 site/data/make-docs.py --check   write nothing, and exit with 1 if any is out of date
"""

import argparse
import html
import json
import os
import posixpath
import re
import sys

JIGS_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DOCS = os.path.join(JIGS_ROOT, 'docs')
README = os.path.join(JIGS_ROOT, 'README.md')
OVERVIEW = os.path.join(JIGS_ROOT, 'site', 'index.html')
TOOL_PAGES = os.path.join(JIGS_ROOT, 'site', 'tools')
DATA = os.path.join(JIGS_ROOT, 'site', 'data', 'docs.js')
REPOSITORY = 'https://github.com/MangkorN/jigs'

# The order of the tools in the README and on the site. Pages not named here follow, sorted by name.
ORDER = ['lsf', 'catcs', 'toclip', 'csbundle', 'csapply', 'gdm', 'gitro', 'vs-tabs']

# Extra lines for a tool's plate on the site: (label, link text, address from the tool's page).
PLATE_LINKS = {'gitro': [('Try it', 'Run gitro in your browser', '../../run/'),
                         ('Tested', 'What it refuses, and why', '../../gitro/read-only/'),
                         ('Callers', 'An agent asking gitro', '../../gitro/callers/')]}

# Where a tool's script is, by its name, and what kind of tool that makes it.
SOURCES = [('bash/functions/%s.sh', 'Bash function', 'bash'), ('powershell/%s.ps1', 'PowerShell script', 'PowerShell')]

START = '<!-- tools:start'
END = '<!-- tools:end -->'
README_START = '<!-- tools:start: written by site/data/make-docs.py from docs/, so edit those pages, then run it -->'
OVERVIEW_START = '        <!-- tools:start: written by site/data/make-docs.py from docs/ -->'

PAGE = re.compile(r'# (?P<title>[^\n]+)\n\n(?P<summary>(?:[^\n]+\n)+)')


# MARKDOWN =============================================================================================================

FENCE = re.compile(r'^```([\w+-]*)\s*$')
HEADING = re.compile(r'^(#{1,6})\s+(.*?)\s*$')
ITEM = re.compile(r'^([-*+]|\d+[.)])\s+(.*)$')
TABLE_RULE = re.compile(r'^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$')
CODE = re.compile(r'`([^`]+)`')
LINK = re.compile(r'\[([^\]]+)\]\(([^)\s]+)\)')
BOLD = re.compile(r'\*\*(.+?)\*\*')
SAVED = re.compile('\x00(\\d+)\x00')


def escape(text):
    return html.escape(text, quote=False)


def attribute(text):
    return html.escape(text, quote=True)


def slug(text):
    """A heading's anchor, made the way GitHub makes it, so links to sections work on both."""
    plain = re.sub(r'`|\*\*', '', LINK.sub(r'\1', text)).strip().lower()
    return re.sub(r'[^\w\- ]', '', plain).replace(' ', '-')


def indent_of(line):
    return len(line) - len(line.lstrip(' '))


class Markdown:
    """Renders the Markdown these pages use: headings, paragraphs, fenced code, block quotes, lists nested by indentation,
    pipe tables, links, bold and inline code. Anything else comes out as escaped text. 'resolve' turns a link's address
    into the one to use, or None to show the link's text alone."""

    def __init__(self, resolve):
        self.resolve = resolve
        self.ids = set()
        # (level, anchor, HTML) of each heading, for a page's contents.
        self.headings = []

    def render(self, text):
        return self.blocks(text.replace('\r\n', '\n').split('\n'))

    def inline(self, text):
        saved = []

        def keep(markup):
            saved.append(markup)
            return '\x00%d\x00' % (len(saved) - 1)

        def link(match):
            label = BOLD.sub(r'<strong>\1</strong>', escape(match.group(1)))
            address = self.resolve(match.group(2))
            return keep('<a href="%s">%s</a>' % (attribute(address), label) if address else label)

        text = CODE.sub(lambda match: keep('<code>%s</code>' % escape(match.group(1))), text)
        text = LINK.sub(link, text)
        text = BOLD.sub(r'<strong>\1</strong>', escape(text))
        while SAVED.search(text):
            text = SAVED.sub(lambda match: saved[int(match.group(1))], text)
        return text

    def anchor(self, text):
        base = slug(text) or 'section'
        anchor, number = base, 0
        while anchor in self.ids:
            number += 1
            anchor = '%s-%d' % (base, number)
        self.ids.add(anchor)
        return anchor

    @staticmethod
    def starts_block(line):
        return bool(FENCE.match(line) or HEADING.match(line) or line.startswith('>') or ITEM.match(line))

    def blocks(self, lines):
        out = []
        i = 0
        while i < len(lines):
            line = lines[i]
            if not line.strip():
                i += 1
            elif FENCE.match(line):
                language = FENCE.match(line).group(1)
                end = next((j for j in range(i + 1, len(lines)) if lines[j].strip() == '```'), len(lines))
                language_attribute = ' data-language="%s"' % attribute(language) if language else ''
                out.append('<pre%s><code>%s</code></pre>' % (language_attribute, escape('\n'.join(lines[i + 1:end]))))
                i = end + 1
            elif HEADING.match(line):
                hashes, text = HEADING.match(line).groups()
                anchor, markup = self.anchor(text), self.inline(text)
                self.headings.append((len(hashes), anchor, markup))
                out.append('<h%d id="%s">%s</h%d>' % (len(hashes), anchor, markup, len(hashes)))
                i += 1
            elif line.startswith('>'):
                end = i
                while end < len(lines) and lines[end].startswith('>'):
                    end += 1
                quoted = [re.sub(r'^> ?', '', quoted_line) for quoted_line in lines[i:end]]
                out.append('<blockquote>\n%s\n</blockquote>' % self.blocks(quoted))
                i = end
            elif ITEM.match(line):
                markup, i = self.list_block(lines, i)
                out.append(markup)
            elif line.lstrip().startswith('|') and i + 1 < len(lines) and TABLE_RULE.match(lines[i + 1]):
                markup, i = self.table(lines, i)
                out.append(markup)
            else:
                end = i + 1
                while end < len(lines) and lines[end].strip() and not self.starts_block(lines[end]):
                    end += 1
                out.append('<p>%s</p>' % self.inline(' '.join(part.strip() for part in lines[i:end])))
                i = end
        return '\n'.join(out)

    def list_block(self, lines, i):
        """Renders the list starting at line i, and returns it with the line after it. An item holds every line indented
        to its text, so code, quotes and lists nest inside it. As in CommonMark, a blank line between items, or between
        the blocks of one item, makes it a loose list, whose paragraphs keep their spacing."""
        ordered = ITEM.match(lines[i]).group(1)[0].isdigit()
        start = int(re.match(r'\d+', lines[i]).group()) if ordered else 1
        items, loose = [], False
        while i < len(lines):
            match = ITEM.match(lines[i])
            if not match or match.group(1)[0].isdigit() != ordered:
                break
            column = match.start(2)
            body = [match.group(2)]
            i += 1
            while i < len(lines):
                line = lines[i]
                if not line.strip():
                    following = next((k for k in range(i, len(lines)) if lines[k].strip()), None)
                    if following is None or indent_of(lines[following]) < column:
                        break
                    body.append('')
                elif indent_of(line) >= column:
                    body.append(line[column:])
                elif self.starts_block(line) or not body[-1].strip():
                    break
                else:
                    # A paragraph line wrapped without indenting still belongs to the item.
                    body.append(line.strip())
                i += 1
            items.append(body)
            loose = loose or self.has_gap(body)
            following = next((k for k in range(i, len(lines)) if lines[k].strip()), None)
            if following is not None and following > i:
                next_item = ITEM.match(lines[following])
                if next_item and next_item.group(1)[0].isdigit() == ordered:
                    loose = True
                    i = following
                else:
                    break
        rendered = []
        for body in items:
            content = self.blocks(body)
            # In a tight list, an item's first paragraph sits in the item directly.
            if not loose and content.startswith('<p>'):
                content = content[3:].replace('</p>', '', 1)
            rendered.append('<li>%s</li>' % content)
        tag = 'ol' if ordered else 'ul'
        opening = '<ol start="%d">' % start if ordered and start != 1 else '<%s>' % tag
        return '%s\n%s\n</%s>' % (opening, '\n'.join(rendered), tag), i

    @staticmethod
    def has_gap(body):
        """Whether a blank line separates two of an item's own blocks, rather than lines within its code or nested lists."""
        fenced, previous = False, ''
        for index, line in enumerate(body):
            if FENCE.match(line) or (fenced and line.strip() == '```'):
                fenced = not fenced
            elif not line.strip() and not fenced:
                following = next((rest for rest in body[index + 1:] if rest.strip()), None)
                within_list = following is not None and ITEM.match(following) and (ITEM.match(previous) or indent_of(previous) > 0)
                if following is not None and indent_of(following) == 0 and not within_list:
                    return True
            if line.strip():
                previous = line
        return False

    def table(self, lines, i):
        def cells(line):
            return [cell.strip() for cell in line.strip().strip('|').split('|')]

        header = '<tr>%s</tr>' % ''.join('<th>%s</th>' % self.inline(cell) for cell in cells(lines[i]))
        rows = []
        i += 2
        while i < len(lines) and lines[i].lstrip().startswith('|'):
            rows.append('<tr>%s</tr>' % ''.join('<td>%s</td>' % self.inline(cell) for cell in cells(lines[i])))
            i += 1
        return '<table>\n<thead>%s</thead>\n<tbody>\n%s\n</tbody>\n</table>' % (header, '\n'.join(rows)), i


# PAGES ================================================================================================================

def read(path):
    with open(path, encoding='utf-8', newline='') as source:
        return source.read()


def read_page(name):
    """A page's name, title, summary on one line, and Markdown after the summary, with its tool's kind and script."""
    path = os.path.join(DOCS, name + '.md')
    text = read(path).replace('\r\n', '\n')
    match = PAGE.match(text)
    if not match or match.group('summary').startswith(('#', '```', '- ', '|', '>')):
        sys.exit('%s must start with "# <name>", a blank line, then a paragraph summarizing the tool.' % path)
    page = {'id': name, 'title': match.group('title').strip(),
            'summary': ' '.join(line.strip() for line in match.group('summary').splitlines()),
            'body': text[match.end():].strip('\n') + '\n', 'kind': None, 'short': None, 'source': None}
    for pattern, kind, short in SOURCES:
        if os.path.isfile(os.path.join(JIGS_ROOT, pattern % name)):
            page.update(kind=kind, short=short, source=pattern % name)
            break
    return page


def page_names():
    found = sorted(name[:-3] for name in os.listdir(DOCS) if name.endswith('.md'))
    return [name for name in ORDER if name in found] + [name for name in found if name not in ORDER]


def link_resolver(names, here):
    """Resolves a link in a page of docs/ for a page at 'here' on the site: another tool's page goes to its site page,
    any other file in the repository to GitHub, and an address with a scheme other than http, https or mailto nowhere."""
    def resolve(address):
        if re.match(r'^(https?:|mailto:|#)', address):
            return address
        if re.match(r'^[a-z][a-z0-9+.-]*:', address, re.I):
            return None
        path, _, fragment = address.partition('#')
        target = posixpath.normpath(posixpath.join('docs', path))
        if target == '..' or target.startswith('../'):
            return None
        suffix = '#' + fragment if fragment else ''
        directory, name = posixpath.split(target)
        if directory == 'docs' and name.endswith('.md') and name[:-3] in names:
            return here(name[:-3]) + suffix
        return '%s/blob/main/%s%s' % (REPOSITORY, target, suffix)
    return resolve


TOOL_PAGE = '''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>{title} | jigs</title>
<link rel="stylesheet" href="../../assets/site.css">
<link rel="stylesheet" href="../tools.css">
<script src="../../data/docs.js"></script>
<script src="../../assets/site.js"></script>
</head>
<!-- Written by site/data/make-docs.py from docs/{id}.md. Edit that page, then run it again. -->
<body data-page="tool-{id}">
<main class="page tool">
    <section class="plate" aria-labelledby="title">
        <div>
            <h1 id="title">{title}</h1>
            <p class="job">{summary}</p>
        </div>
        <dl>
{plate}
        </dl>
    </section>
{contents}
    <article class="doc">
{body}
    </article>
</main>
</body>
</html>
'''


def tool_page(page, names):
    markdown = Markdown(link_resolver(names, lambda name: '../%s/' % name))
    body = markdown.render(page['body'])
    plate = []
    if page['kind']:
        plate.append(('Kind', escape(page['kind'])))
        plate.append(('Script', '<a href="%s/blob/main/%s"><code>%s</code></a>' % (REPOSITORY, page['source'], page['source'])))
    plate.append(('Page', '<a href="%s/blob/main/docs/%s.md"><code>docs/%s.md</code></a>' % (REPOSITORY, page['id'], page['id'])))
    for label, text, address in PLATE_LINKS.get(page['id'], []):
        plate.append((escape(label), '<a href="%s">%s</a>' % (attribute(address), escape(text))))
    sections = [(level, anchor, markup) for level, anchor, markup in markdown.headings if level in (2, 3)]
    contents = ''
    if sum(1 for level, _, _ in sections if level == 2) >= 2:
        entries = ''.join('            <li class="level-%d"><a href="#%s">%s</a></li>\n' % (level, anchor, markup)
                          for level, anchor, markup in sections)
        contents = ('    <nav class="contents" aria-label="On this page">\n        <h2>On this page</h2>\n'
                    '        <ul>\n%s        </ul>\n    </nav>\n' % entries)
    return TOOL_PAGE.format(
        id=page['id'], title=escape(page['title']), summary=Markdown(lambda address: None).inline(page['summary']),
        plate='\n'.join('            <dt>%s</dt><dd>%s</dd>' % row for row in plate), contents=contents.rstrip('\n'),
        # Not indented, since indenting would change the text of code blocks.
        body=body)


def with_list(current, start_line, items, path):
    """The file's text with the lines between its markers replaced by start_line and the items."""
    lines = current.replace('\r\n', '\n').split('\n')
    starts = [i for i, line in enumerate(lines) if line.strip().startswith(START)]
    ends = [i for i, line in enumerate(lines) if line.strip() == END]
    if len(starts) != 1 or len(ends) != 1 or ends[0] < starts[0]:
        sys.exit('%s needs one line starting with "%s" and, after it, one "%s".' % (path, START, END))
    end_line = lines[ends[0]][:len(lines[ends[0]]) - len(lines[ends[0]].lstrip())] + END
    return '\n'.join(lines[:starts[0]] + [start_line] + items + [end_line] + lines[ends[0] + 1:])


def readme_text(pages):
    items = ['- **[%s](docs/%s.md):** %s' % (page['title'], page['id'], page['summary']) for page in pages]
    return with_list(read(README), README_START, items, README)


def overview_text(pages, names):
    inline = Markdown(link_resolver(names, lambda name: 'tools/%s/' % name)).inline
    items = []
    for page in pages:
        kind = ' <span class="kind">%s</span>' % escape(page['short']) if page['short'] else ''
        items.append('        <dt><a href="tools/%s/">%s</a>%s</dt>' % (page['id'], escape(page['title']), kind))
        items.append('        <dd>%s</dd>' % inline(page['summary']))
    return with_list(read(OVERVIEW), OVERVIEW_START, items, OVERVIEW)


def data_text(pages):
    tools = [{'id': page['id'], 'title': page['title'], 'summary': page['summary'], 'kind': page['kind']} for page in pages]
    return ('/* Generated by make-docs.py from docs/: the tools, for the site\'s navigation. Run it again rather than editing this file. */\n'
            'window.JIGS_DOCS = %s;\n' % json.dumps(tools, indent=1))


# OUTPUT ===============================================================================================================

def same(path, text):
    """Whether the file holds this text, whichever line endings it was checked out with."""
    return os.path.isfile(path) and read(path).replace('\r\n', '\n') == text


def write(path, text):
    """Writes the text with the line endings the file already has, so a CRLF checkout stays CRLF."""
    crlf = os.path.isfile(path) and '\r\n' in read(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='') as target:
        target.write(text.replace('\n', '\r\n') if crlf else text)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--check', action='store_true', help='write nothing, and exit with 1 if any output is out of date')
    args = parser.parse_args()

    names = page_names()
    pages = [read_page(name) for name in names]
    outputs = [(README, readme_text(pages)), (OVERVIEW, overview_text(pages, names)), (DATA, data_text(pages))]
    outputs += [(os.path.join(TOOL_PAGES, page['id'], 'index.html'), tool_page(page, names)) for page in pages]
    stale = [path for path, text in outputs if not same(path, text)]
    # A tool page whose doc is gone isn't removed here, since removing files is left to git.
    orphans = sorted(name for name in (os.listdir(TOOL_PAGES) if os.path.isdir(TOOL_PAGES) else [])
                     if os.path.isdir(os.path.join(TOOL_PAGES, name)) and name not in names)

    for name in orphans:
        print('site/tools/%s/ has no page in docs/ any more. Remove it: git rm -r site/tools/%s' % (name, name))
    if args.check:
        for path in stale:
            print('%s is out of date. Run python3 site/data/make-docs.py.' % os.path.relpath(path, JIGS_ROOT).replace(os.sep, '/'))
        sys.exit(1 if stale or orphans else 0)
    for path, text in outputs:
        if path in stale:
            write(path, text)
            print('wrote ' + os.path.relpath(path, JIGS_ROOT).replace(os.sep, '/'))
    if not stale:
        print('Everything made from docs/ is up to date.')


if __name__ == '__main__':
    main()
