#!/usr/bin/env python3
"""Tests site/data/make-docs.py: its Markdown renderer, how it resolves links, and that what it made from docs/ is current.

    python3 tests/make-docs-test.py

Exits with the number of failed checks.
"""

import importlib.util
import os
import re
import subprocess
import sys

JIGS_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR = os.path.join(JIGS_ROOT, 'site', 'data', 'make-docs.py')

# Loading the generator as a module would otherwise leave a __pycache__ folder in site/data.
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('make_docs', GENERATOR)
make_docs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_docs)

failed = 0
passed = 0


def check(section, name, ok, detail=''):
    global failed, passed
    if ok:
        passed += 1
    else:
        failed += 1
    line = '%-6s%-12s%s' % ('ok' if ok else 'FAIL', section, name)
    print(line + ('\n      got: %r' % (detail,) if not ok and detail != '' else ''))


def render(text, resolve=lambda address: address):
    return make_docs.Markdown(resolve).render(text).replace('\n', '|')


def inline(text, resolve=lambda address: address):
    return make_docs.Markdown(resolve).inline(text)


# Anchors are made the way GitHub makes them, so a link to a section works on GitHub and on the site.
for text, expected in [('Per-project wrapper', 'per-project-wrapper'), ('Why not `clip.exe`', 'why-not-clipexe'),
                       ('Connecting a caller', 'connecting-a-caller'), ('A **bold** [link](x.md)', 'a-bold-link')]:
    check('anchors', '%r becomes %r' % (text, expected), make_docs.slug(text) == expected, make_docs.slug(text))
got = render('## Same\n\n## Same')
check('anchors', 'a repeated heading gets a numbered anchor', 'id="same"' in got and 'id="same-1"' in got, got)

got = inline('`a <b> & c`')
check('inline', 'code is escaped', got == '<code>a &lt;b&gt; &amp; c</code>', got)
got = inline('**bold** and <tag>')
check('inline', 'bold, and other text escaped', got == '<strong>bold</strong> and &lt;tag&gt;', got)
got = inline('[see `x`](page.md#part)')
check('inline', 'a link with code in its text', got == '<a href="page.md#part">see <code>x</code></a>', got)
got = inline('[run](javascript:alert(1))', make_docs.link_resolver([], lambda name: name))
check('inline', 'a link with another scheme is shown as text', '<a' not in got and 'run' in got, got)
got = inline('`**not bold**`')
check('inline', 'code isn\'t formatted', got == '<code>**not bold**</code>', got)

got = render('```bash\necho "<hi>"\n\n  indented\n```')
check('blocks', 'fenced code keeps its text and language',
      got == '<pre data-language="bash"><code>echo "&lt;hi&gt;"||  indented</code></pre>', got)
got = render('A paragraph\nwrapped.\n\n> Quoted\n> text.')
check('blocks', 'paragraphs join their lines, and quotes hold blocks',
      got == '<p>A paragraph wrapped.</p>|<blockquote>|<p>Quoted text.</p>|</blockquote>', got)
got = render('| A | B |\n|---|:-:|\n| `1` | 2 |')
check('blocks', 'a pipe table', '<th>A</th><th>B</th>' in got and '<td><code>1</code></td><td>2</td>' in got, got)

# Lists follow CommonMark: a blank line between items, or between an item's own blocks, makes a list loose.
for source, expected, name in [
        ('- a\n- b', '<ul>|<li>a</li>|<li>b</li>|</ul>', 'a tight list'),
        ('- a\n\n- b', '<ul>|<li><p>a</p></li>|<li><p>b</p></li>|</ul>', 'blank lines between items make it loose'),
        ('1. a\n2. b\n\n   more\n3. c', '<ol>|<li><p>a</p></li>|<li><p>b</p>|<p>more</p></li>|<li><p>c</p></li>|</ol>',
         'a blank line between an item\'s blocks makes it loose'),
        ('- a\n  - x\n\n  - y\n- b', '<ul>|<li>a|<ul>|<li><p>x</p></li>|<li><p>y</p></li>|</ul></li>|<li>b</li>|</ul>',
         'a nested list\'s blank lines leave the outer list tight'),
        ('1. a\n   ```\n   x\n\n   y\n   ```\n2. b', '<ol>|<li>a|<pre><code>x||y</code></pre></li>|<li>b</li>|</ol>',
         'blank lines in an item\'s code leave the list tight'),
        ('3. c\n4. d', '<ol start="3">|<li>c</li>|<li>d</li>|</ol>', 'an ordered list keeps its first number'),
        ('1. Step:\n   > Say this.\n2. Next', '<ol>|<li>Step:|<blockquote>|<p>Say this.</p>|</blockquote></li>|<li>Next</li>|</ol>',
         'a quote inside an item')]:
    got = render(source)
    check('lists', name, got == expected, got)

resolve = make_docs.link_resolver(['gitro', 'toclip'], lambda name: '../%s/' % name)
for address, expected, name in [
        ('toclip.md', '../toclip/', 'another tool\'s page goes to its site page'),
        ('gitro.md#browser-ui', '../gitro/#browser-ui', 'with its section'),
        ('../README.md#install', make_docs.REPOSITORY + '/blob/main/README.md#install', 'another file goes to GitHub'),
        ('../../outside.md', None, 'a file outside the repository goes nowhere'),
        ('https://example.com/x', 'https://example.com/x', 'a web address stays'),
        ('#here', '#here', 'a section of the same page stays'),
        ('file:///etc/passwd', None, 'another scheme goes nowhere')]:
    got = resolve(address)
    check('links', name, got == expected, got)

for name in make_docs.page_names():
    page = make_docs.read_page(name)
    text = re.sub(r'<pre.*?</pre>|<code>.*?</code>', '', make_docs.tool_page(page, make_docs.page_names()), flags=re.S)
    leftovers = [marker for marker in ('```', '**', '](') if marker in text]
    check('pages', 'docs/%s.md renders with no Markdown left over' % name, not leftovers, leftovers)

result = subprocess.run([sys.executable, GENERATOR, '--check'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                        universal_newlines=True)
check('pages', 'the README, the overview, the tool pages and docs.js are up to date', result.returncode == 0, result.stdout.strip())

print('%d passed, %d failed' % (passed, failed))
sys.exit(failed)
