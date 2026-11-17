/* jigs site: applies the color theme, builds the header and navigation around each page's <main>,
   and keeps folder links working when pages are opened straight from disk.
   Load it in <head>, so the theme applies before the page draws. */
(function () {
    'use strict';

    /* PAGES ============================================================================================================ */

    // The navigation, in order: [path from the site root, label, the page's data-page value].
    const NAV = [
        { title: 'Start', pages: [['', 'Overview', 'home']] },
        { title: 'gitro', pages: [['run/', 'Run gitro', 'run']] },
    ];
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
            for (const link of document.querySelectorAll('main a[href$="/"]')) {
                if (!/^[a-z]+:/i.test(link.getAttribute('href'))) link.href = pageUrl(new URL(link.href).href);
            }
        }
    }

    document.addEventListener('DOMContentLoaded', buildShell);

    window.Jigs = { el, pageUrl, fromDisk, REPOSITORY };
})();
