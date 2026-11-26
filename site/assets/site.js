/* jigs site: applies the color theme, builds the header and navigation around each page's <main>,
   keeps folder links working when pages are opened straight from disk, and adds Copy buttons to code.
   Load it in <head>, after data/docs.js, so the theme applies before the page draws. */
(function () {
    'use strict';

    /* PAGES ============================================================================================================ */

    // The navigation, in order: [path from the site root, label, the page's data-page value].
    // The tools come from data/docs.js, which make-docs.py writes from docs/.
    const TOOLS = (window.JIGS_DOCS || []).map((tool) => [`tools/${tool.id}/`, tool.title, `tool-${tool.id}`]);
    const NAV = [
        { title: 'Start', pages: [['', 'Overview', 'home']] },
        { title: 'Tools', pages: TOOLS },
        { title: 'gitro', pages: [
            ['run/', 'Run gitro', 'run'],
            ['gitro/read-only/', 'Read-only is hard', 'gitro-read-only'],
            ['gitro/callers/', 'Agents and callers', 'gitro-callers'],
        ] },
    ].filter((group) => group.pages.length);
    const REPOSITORY = 'https://github.com/MangkorN/jigs';

    const root = new URL('..', document.currentScript.src);
    const fromDisk = location.protocol === 'file:';

    /** Address of a page given its path from the site root. Opened from disk, a folder address gets index.html,
     *  since file:// shows a folder listing instead. */
    function pageUrl(path) {
        const url = new URL(path, root);
        if (fromDisk && url.pathname.endsWith('/')) url.pathname += 'index.html';
        return url.href;
    }

    /* THEME ============================================================================================================ */

    const THEME_KEY = 'jigs.theme';

    function storedTheme() {
        try { return localStorage.getItem(THEME_KEY); } catch (_) { return null; }
    }

    function setTheme(theme, remember) {
        document.documentElement.dataset.theme = theme;
        if (remember) {
            try { localStorage.setItem(THEME_KEY, theme); } catch (_) { /* storage can be off; the choice lasts this visit */ }
        }
        const toggle = document.getElementById('theme-toggle');
        if (toggle) toggle.textContent = theme === 'dark' ? 'Light theme' : 'Dark theme';
    }

    setTheme(storedTheme() || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'), false);

    /* DOM HELPERS ====================================================================================================== */

    /** Creates an element. Attributes go through setAttribute, except 'class', 'text' and 'on<event>' handlers;
     *  children can be nodes, strings, or null to skip. */
    function el(tag, attributes, ...children) {
        const node = document.createElement(tag);
        for (const [key, value] of Object.entries(attributes || {})) {
            if (value === null || value === undefined || value === false) continue;
            if (key === 'class') node.className = value;
            else if (key === 'text') node.textContent = value;
            else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
            else node.setAttribute(key, value === true ? '' : value);
        }
        for (const child of children.flat(Infinity)) {
            if (child !== null && child !== undefined && child !== false) node.append(child);
        }
        return node;
    }

    /* COPY BUTTONS ===================================================================================================== */

    /** Puts text on the clipboard. Where the Clipboard API is missing or refuses, as it can for a page opened from disk,
     *  a hidden text area and the older copy command stand in. */
    async function copyText(text) {
        if (navigator.clipboard && window.isSecureContext) {
            try {
                await navigator.clipboard.writeText(text);
                return;
            }
            catch (_) { /* fall through to the copy command */ }
        }
        const area = el('textarea', { class: 'copy-buffer', readonly: true });
        area.value = text;
        document.body.append(area);
        area.select();
        const copied = document.execCommand('copy');
        area.remove();
        if (!copied) throw new Error('The browser refused to copy.');
    }

    /** Adds a Copy button to a code block or quote, taking its text as it is now. */
    function addCopyButton(block) {
        const text = block.matches('pre') ? block.textContent : block.innerText.trim();
        const button = el('button', { type: 'button', class: 'copy quiet', 'aria-label': 'Copy to the clipboard' }, 'Copy');
        button.addEventListener('click', async () => {
            try {
                await copyText(text);
                button.textContent = 'Copied';
            }
            catch (_) {
                button.textContent = 'Select and copy it instead';
            }
            setTimeout(() => { button.textContent = 'Copy'; }, 1800);
        });
        // A code block scrolls sideways, so the button sits on a frame around it rather than in it.
        const frame = el('div', { class: 'copyable' });
        block.replaceWith(frame);
        frame.append(block, button);
    }

    /* SHELL ============================================================================================================ */

    function buildShell() {
        const current = document.body.dataset.page;
        const header = el('header', { class: 'site-header' },
            el('a', { class: 'wordmark', href: pageUrl('') }, 'jigs'),
            el('p', { class: 'tagline' }, 'Small, purpose-built tools for repetitive dev tasks'),
            el('span', { class: 'spacer' }),
            el('button', { class: 'quiet', id: 'theme-toggle', type: 'button', onclick: () => {
                setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark', true);
            } }),
            el('a', { class: 'plain', href: REPOSITORY }, 'GitHub'));

        const nav = el('nav', { 'aria-label': 'Pages' }, NAV.map((group) => [
            el('h2', {}, group.title),
            el('ul', {}, group.pages.map(([path, label, page]) => el('li', {},
                el('a', { href: pageUrl(path), 'aria-current': page === current ? 'page' : null }, label)))),
        ]));

        const layout = el('div', { class: 'layout' }, el('aside', { class: 'rail' }, nav));
        layout.append(...document.body.childNodes);
        document.body.append(header, layout);
        setTheme(document.documentElement.dataset.theme, false);

        if (fromDisk) {
            // Folder links within the site, with or without a #section, get index.html.
            for (const link of document.querySelectorAll('main a[href]')) {
                const href = link.getAttribute('href');
                if (/^[a-z]+:/i.test(href) || href.startsWith('#')) continue;
                const url = new URL(link.href);
                if (url.pathname.endsWith('/')) {
                    url.pathname += 'index.html';
                    link.href = url.href;
                }
            }
        }

        for (const block of document.querySelectorAll('main > pre, main .doc pre, main .doc blockquote')) addCopyButton(block);
    }

    document.addEventListener('DOMContentLoaded', buildShell);

    window.Jigs = { el, pageUrl, fromDisk, REPOSITORY, addCopyButton };
})();
