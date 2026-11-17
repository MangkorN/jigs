/* Run page: starts, watches and stops gitro servers through the gitro ui companion on 127.0.0.1.
   The page works without the companion: its status window says gitro ui isn't running, and, opened from a file,
   the page connects by itself once it runs, by watching the session file the companion writes.
   A demo with the same interface, built from data/gitro-demo.js, plays on request. */
(function () {
    'use strict';

    const { el } = window.Jigs;

    /* CONFIG =========================================================================================================== */

    // The companion's API version this page speaks. Matches API_VERSION in the companions.
    const API_VERSION = 1;
    const SESSION_KEY = 'jigs.gitro-ui.session';
    const RECENT_KEY = 'jigs.gitro-ui.recent';
    const RECENT_LIMIT = 6;
    const REQUEST_LIMIT = 300;
    const SUGGESTION_LIMIT = 12;
    const LOG_LIMIT = 200;
    const RETRY_MS = 3000;
    // A page opened from a file finds the companion through the session file it writes in this clone.
    const FROM_FILE = location.protocol === 'file:';
    const SESSION_SCRIPT = '../../.gitro-ui/session.js';
    const DISCOVER_MS = 2000;
    const STALE_RETRY_MS = 10000;
    const SUGGESTED = ['status --short --branch', 'log --oneline -10', 'diff --stat', 'diff --cached --stat', 'branch -vv'];
    const PLATFORM_NAMES = { windows: 'Windows', macos: 'macOS', linux: 'Linux' };
    const PLACEHOLDERS = {
        windows: ['D:\\Repos\\MyProject', 'D:\\Exchange\\myproject'],
        macos: ['~/Repos/MyProject', '~/Exchange/myproject'],
        linux: ['~/Repos/MyProject', '~/Exchange/myproject'],
        demo: ['~/Repos/MyProject', '~/Exchange/myproject'],
    };

    /* HELPERS ========================================================================================================== */

    function load(storage, key) {
        try { return JSON.parse(storage.getItem(key)); } catch (_) { return null; }
    }

    function save(storage, key, value) {
        try { storage.setItem(key, JSON.stringify(value)); } catch (_) { /* storage can be off; nothing depends on it */ }
    }

    function sleep(ms) {
        return new Promise((resolve) => setTimeout(resolve, ms));
    }

    function pad(number) {
        return String(number).padStart(2, '0');
    }

    function formatTime(ms) {
        const date = new Date(ms);
        return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
    }

    function baseName(path) {
        return path.replace(/[\\/]+$/, '').split(/[\\/]/).pop() || path;
    }

    /** Splits a request typed like a shell command into gitro's arguments. Spaces separate arguments, and quotes
     *  group them (--format="%h %s"). Backslashes stay as typed, for Windows paths, except \" inside double quotes.
     *  A leading 'gitro' is dropped, since the command is gitro's already. */
    function splitArgs(text) {
        const args = [];
        let current = '';
        let started = false;
        let quote = null;
        for (let i = 0; i < text.length; i++) {
            const c = text[i];
            if (quote) {
                if (c === quote) quote = null;
                else if (quote === '"' && c === '\\' && text[i + 1] === '"') current += text[++i];
                else current += c;
            }
            else if (c === '"' || c === "'") { quote = c; started = true; }
            else if (/\s/.test(c)) {
                if (started) args.push(current);
                current = '';
                started = false;
            }
            else { current += c; started = true; }
        }
        if (quote) throw new Error('A quote is left open.');
        if (started) args.push(current);
        if (args[0] === 'gitro') args.shift();
        return args;
    }

    /* SESSION ========================================================================================================== */

    /** The companion this tab was opened for, from the link's fragment, which is then removed from the address bar,
     *  or from an earlier visit in the same tab. The hosted page gets its session this way. */
    function takeSession() {
        const fragment = new URLSearchParams(location.hash.slice(1));
        const port = Number(fragment.get('port'));
        const token = fragment.get('token');
        if (port && token) {
            save(sessionStorage, SESSION_KEY, { port, token });
            history.replaceState(null, '', location.pathname + location.search);
            return { port, token };
        }
        return load(sessionStorage, SESSION_KEY);
    }

    /** Reads the session file by loading it as a script, which a page opened from a file may do, though it may not
     *  fetch it. Resolves with the session, null if the companion has stopped, or undefined if there's no file. */
    function readSessionFile() {
        return new Promise((resolve) => {
            window.JIGS_GITRO_UI = undefined;
            const script = document.createElement('script');
            const finish = (value) => {
                script.remove();
                window.JIGS_GITRO_UI = undefined;
                resolve(value);
            };
            script.onload = () => {
                const value = window.JIGS_GITRO_UI;
                if (value === null) finish(null);
                else finish(value && value.port && value.token ? value : undefined);
            };
            script.onerror = () => finish(undefined);
            script.src = `${SESSION_SCRIPT}?${Date.now()}`;
            document.head.append(script);
        });
    }

    /* LIVE API ========================================================================================================= */

    /** Calls the companion on 127.0.0.1. Failures throw an Error with 'status' set for HTTP errors,
     *  or 'offline' when the companion couldn't be reached. */
    function liveApi(port, token) {
        const base = `http://127.0.0.1:${port}`;

        async function call(method, path, body) {
            let response;
            try {
                response = await fetch(base + path, {
                    method,
                    headers: body === undefined ? { 'X-Gitro-Token': token }
                        : { 'X-Gitro-Token': token, 'Content-Type': 'application/json' },
                    body: body === undefined ? undefined : JSON.stringify(body),
                    cache: 'no-store',
                });
            }
            catch (_) {
                throw Object.assign(new Error(`Can't reach gitro ui on 127.0.0.1:${port}.`), { offline: true });
            }
            const json = (response.headers.get('content-type') || '').startsWith('application/json');
            const value = json ? await response.json() : await response.text();
            if (!response.ok) {
                const message = (json && value.error) || value || `${response.status} ${response.statusText}`;
                throw Object.assign(new Error(message), { status: response.status });
            }
            return value;
        }

        return {
            mode: 'live',
            port,
            status: () => call('GET', '/api/status'),
            events: (after) => call('GET', `/api/events?after=${after}`),
            pickFolder: (title, start) => call('POST', '/api/pick-folder', { title, start }),
            folders: (path) => call('GET', `/api/folders?path=${encodeURIComponent(path)}`),
            addServer: (repo, dir) => call('POST', '/api/servers', { repo, dir }),
            act: (id, action) => call('POST', `/api/servers/${id}/${action}`, {}),
            request: (id, args) => call('POST', '/api/request', { server: id, args }),
            response: (id, name) => call('GET', `/api/response?server=${id}&name=${encodeURIComponent(name)}`),
            quit: () => call('POST', '/api/quit', {}),
        };
    }

    /* DEMO API ========================================================================================================= */

    /** A companion simulated in the page, with the same calls as liveApi: one server for the recorded repository,
     *  an outside caller replaying the recorded requests, and recorded answers to the suggested requests. */
    function demoApi(data) {
        const events = [];
        const kept = new Map();
        const view = { id: 1, repo: data.repo, dir: data.dir, state: 'stopped', exitCode: null, startedAt: null };
        let seq = 0;
        let waiting = [];
        let timers = [];
        let next = 0;
        let removed = false;

        function emit(entry) {
            entry.seq = ++seq;
            entry.time = Date.now();
            entry.server = 1;
            events.push(entry);
            for (const resolve of waiting.splice(0)) resolve();
        }

        function answer(request, own) {
            const recorded = data.answers[request];
            const name = own ? `ui-${Date.now()}` : `req-${Date.now()}${String(next).padStart(6, '0')}-${4100 + next}`;
            kept.set(name, recorded.response);
            emit({ kind: 'request', clock: formatTime(Date.now()), name, request, exit: recorded.exit, own });
            return name;
        }

        function callNext() {
            if (next >= data.caller.length) return;
            timers.push(setTimeout(() => {
                answer(data.caller[next], false);
                next++;
                callNext();
            }, next === 0 ? 1200 : 2400));
        }

        function start() {
            view.state = 'running';
            view.startedAt = Date.now();
            emit({ kind: 'state', state: 'running', exitCode: null });
            emit({ kind: 'log', text: data.serving });
            callNext();
        }

        function stop() {
            timers.forEach(clearTimeout);
            timers = [];
            view.state = 'stopped';
            emit({ kind: 'state', state: 'stopped', exitCode: null });
        }

        function server(id) {
            if (Number(id) !== 1 || removed) throw Object.assign(new Error(`There's no server #${id}.`), { status: 404 });
            return view;
        }

        emit({ kind: 'added', view: { ...view } });
        start();

        return {
            mode: 'demo',
            close: () => timers.forEach(clearTimeout),
            status: async () => ({ api: API_VERSION, platform: 'demo', picker: false, servers: removed ? [] : [{ ...view }], seq }),
            events: (after) => new Promise((resolve) => {
                const reply = () => resolve({ events: events.filter((entry) => entry.seq > after), last: seq, missed: false });
                if (seq > after) reply();
                else waiting.push(reply);
            }),
            pickFolder: async () => { throw new Error('The demo has no folder dialog.'); },
            addServer: async () => {
                throw new Error('The demo serves one recorded repository. Start gitro ui to serve your own.');
            },
            act: async (id, action) => {
                server(id);
                if (action === 'stop' && view.state === 'running') stop();
                else if (action === 'restart') {
                    if (view.state === 'running') stop();
                    start();
                }
                else if (action === 'remove') {
                    if (view.state === 'running') stop();
                    removed = true;
                    emit({ kind: 'removed' });
                }
                return { ...view };
            },
            request: async (id, args) => {
                server(id);
                if (view.state !== 'running') throw Object.assign(new Error("Server #1 isn't running."), { status: 409 });
                const request = args.join(' ');
                if (!data.answers[request]) {
                    throw new Error('The demo has answers only for the suggested requests. Start gitro ui to send any request.');
                }
                const name = `ui-${Date.now()}`;
                timers.push(setTimeout(() => {
                    kept.set(name, data.answers[request].response);
                    emit({ kind: 'request', clock: formatTime(Date.now()), name, request, exit: data.answers[request].exit, own: true });
                }, 350));
                return { name };
            },
            response: async (id, name) => {
                if (!kept.has(name)) throw Object.assign(new Error(`No kept response is named ${name}.`), { status: 404 });
                return kept.get(name);
            },
            quit: async () => { throw new Error('The demo has no companion to stop.'); },
        };
    }

    /* STATE ============================================================================================================ */

    const state = {
        api: null,
        // Raised on every new connection; loops from an older one see the change and stop.
        generation: 0,
        // idle, connecting, live, lost, denied, outdated or demo.
        mode: 'idle',
        // Why the page is idle: null, 'stopped' (gitro ui stopped), or 'stale' (its session names one that doesn't answer).
        note: null,
        info: null,
        session: null,
        // The last session tried, and when, so a stale one is retried only now and then.
        tried: { token: null, at: 0 },
        // On a page opened from a file: the session file's last reading, which the demo offers to connect to.
        found: undefined,
        // Set while the page is being left, when failed requests mean nothing.
        leaving: false,
        last: 0,
        servers: new Map(),
    };

    function newEntry(view) {
        return { view: { ...view }, requests: [], log: [] };
    }

    function clearServers() {
        state.servers.clear();
        state.last = 0;
    }

    /** Applies one companion event to the state. */
    function apply(event) {
        const entry = state.servers.get(event.server);
        switch (event.kind) {
            case 'added':
                if (!entry) state.servers.set(event.server, newEntry(event.view));
                break;
            case 'state':
                if (entry) {
                    entry.view.state = event.state;
                    entry.view.exitCode = event.exitCode;
                }
                break;
            case 'log':
                if (entry) {
                    entry.log.push(event.text);
                    if (entry.log.length > LOG_LIMIT) entry.log.shift();
                }
                break;
            case 'request':
                if (entry) {
                    entry.requests.unshift(event);
                    if (entry.requests.length > REQUEST_LIMIT) entry.requests.pop();
                }
                break;
            case 'removed':
                state.servers.delete(event.server);
                break;
        }
    }

    function closeDemo() {
        if (state.api && state.api.close) state.api.close();
    }

    /** Becomes idle, forgetting the companion's servers. */
    function goIdle(note) {
        state.generation++;
        closeDemo();
        state.api = null;
        state.mode = 'idle';
        state.note = note;
        clearServers();
        render();
    }

    /** Starts over with a companion: takes the servers from its status, then replays every event it still has,
     *  which brings back their requests, and follows new ones. A quiet connection keeps the current view until
     *  the companion answers, for the retries the page makes by itself. */
    async function connect(session, quiet) {
        const generation = ++state.generation;
        closeDemo();
        const api = liveApi(session.port, session.token);
        state.api = api;
        state.session = session;
        state.tried = { token: session.token, at: Date.now() };
        if (!quiet) {
            state.mode = 'connecting';
            clearServers();
            render();
        }
        try {
            const info = await api.status();
            if (generation !== state.generation) return;
            state.info = info;
            state.note = null;
            clearServers();
            if (info.api !== API_VERSION) {
                state.mode = 'outdated';
                render();
                return;
            }
            for (const view of info.servers) state.servers.set(view.id, newEntry(view));
            state.mode = 'live';
            render();
            follow(generation);
        }
        catch (error) {
            if (generation !== state.generation || state.leaving) return;
            if (error.status === 401) {
                state.mode = 'denied';
                clearServers();
            }
            else if (FROM_FILE) {
                // The session file is the only way to find gitro ui from here, so the page waits for it to change.
                if (state.mode !== 'lost') {
                    state.mode = 'idle';
                    state.note = 'stale';
                    clearServers();
                }
            }
            else {
                state.mode = 'lost';
                setTimeout(() => { if (generation === state.generation) connect(session, true); }, RETRY_MS);
            }
            render();
        }
    }

    /** Waits for events and applies them until a newer connection replaces this one. A companion that stops answering
     *  is retried; one that refuses the token is left, since it was restarted with a new one. */
    async function follow(generation) {
        while (generation === state.generation) {
            try {
                const batch = await state.api.events(state.last);
                if (generation !== state.generation) return;
                if (batch.missed) {
                    connect(state.session, true);
                    return;
                }
                batch.events.forEach(apply);
                state.last = batch.last;
                if (state.mode === 'lost') state.mode = 'live';
                render();
            }
            catch (error) {
                // Leaving the page cancels its requests, which isn't the companion's doing, so it isn't shown.
                await sleep(400);
                if (generation !== state.generation || state.leaving) return;
                if (error.status === 401) {
                    state.mode = 'denied';
                    clearServers();
                    render();
                    return;
                }
                state.mode = 'lost';
                render();
                await sleep(RETRY_MS);
            }
        }
    }

    /** On a page opened from a file: reads the session file, and connects when it names a companion
     *  this page isn't connected to, or goes idle when it says the companion stopped. */
    async function discover() {
        if (!FROM_FILE || state.leaving || document.visibilityState === 'hidden') return;
        const mode = state.mode;
        if (mode === 'live' || mode === 'connecting') return;
        const found = await readSessionFile();
        if (state.mode !== mode || state.leaving) return;
        const changed = Boolean(state.found) !== Boolean(found) || (found && state.found && found.token !== state.found.token);
        state.found = found;
        if (mode === 'demo') {
            if (changed) render();
            return;
        }
        if (found) {
            const other = found.token !== state.tried.token;
            if (other) connect(found, mode === 'lost');
            else if (mode === 'idle' && state.note === 'stale' && Date.now() - state.tried.at > STALE_RETRY_MS) {
                connect(found, true);
            }
        }
        else if (mode === 'lost' || mode === 'denied' || (mode === 'idle' && state.note === 'stale')) {
            goIdle(found === null ? 'stopped' : null);
        }
    }

    function startDemo() {
        const data = window.JIGS_GITRO_DEMO;
        if (!data) return;
        const generation = ++state.generation;
        closeDemo();
        const api = demoApi(data);
        state.api = api;
        state.session = null;
        state.mode = 'demo';
        clearServers();
        api.status().then((info) => {
            if (generation !== state.generation) return;
            state.info = info;
            for (const view of info.servers) state.servers.set(view.id, newEntry(view));
            render();
            follow(generation);
        });
        render();
    }

    function leaveDemo() {
        goIdle(null);
        state.tried = { token: null, at: 0 };
        if (FROM_FILE) discover();
        else {
            const session = takeSession();
            if (session) connect(session, false);
        }
    }

    /** Picks up again after the page comes back from the browser's back-forward cache, or after leaving it
     *  turned out not to happen, since its requests may have been cancelled meanwhile. */
    function resume() {
        state.leaving = false;
        if (state.session && ['live', 'lost', 'connecting'].includes(state.mode)) connect(state.session, true);
        else discover();
    }

    /* CONNECTION ======================================================================================================= */

    function command(text) {
        return el('pre', {}, el('code', {}, text));
    }

    function demoButton(label) {
        if (!window.JIGS_GITRO_DEMO) return null;
        return el('button', { type: 'button', onclick: startDemo }, label);
    }

    /** The status window: a lamp in the shop signal colors, what's going on, and what can be done about it.
     *  It's always there, and changes in place as gitro ui comes and goes. */
    function statusWindow(lamp, title, body, actions) {
        return el('div', { class: 'status-window', 'data-lamp': lamp },
            el('span', { class: 'lamp', 'aria-hidden': 'true' }),
            el('h2', {}, title),
            el('div', { class: 'status-actions' }, actions || []),
            el('div', { class: 'status-body' }, body));
    }

    function startHelp() {
        if (FROM_FILE) {
            return [command('gitro ui'),
                el('p', { class: 'aside' }, 'On Windows, run it in Git Bash. On macOS and Linux, it needs Python 3. ' +
                    'It runs in the background, so the terminal can be closed.')];
        }
        return [command('gitro ui -o hosted'),
            el('p', { class: 'aside' }, 'That opens this page with a link that connects to it. ',
                'The copy of this page in your clone, site/run/index.html, connects by itself instead.')];
    }

    function renderIdle() {
        const port = state.session ? state.session.port : '';
        const title = state.note === 'stopped' ? 'gitro ui stopped' : "gitro ui isn't running";
        let lead;
        if (state.note === 'stopped') lead = 'Its servers stopped with it. Start it again from a terminal';
        else if (state.note === 'stale') lead = `Its last session, on 127.0.0.1:${port}, didn't end cleanly. Start it again from a terminal`;
        else lead = 'Start it from a terminal';
        lead += FROM_FILE ? ', and this page connects to it by itself:' : ':';
        return statusWindow('off', title, [el('p', {}, lead), startHelp()], [demoButton('Watch a demo')]);
    }

    function renderLive() {
        const info = state.info;
        const since = info.started ? formatTime(info.started).slice(0, 5) : null;
        const runs = [`on ${PLATFORM_NAMES[info.platform] || info.platform}`];
        if (info.background !== undefined) runs.push(info.background ? 'in the background' : 'in a terminal');
        if (since) runs.push(`since ${since}`);
        return statusWindow('green', 'Connected to gitro ui',
            el('dl', { class: 'status-facts' },
                el('dt', {}, 'Address'), el('dd', {}, `127.0.0.1:${state.session.port}`, info.pid ? `, process ${info.pid}` : ''),
                el('dt', {}, 'Runs'), el('dd', {}, runs.join(', ')),
                el('dt', {}, 'gitro runs with'), el('dd', {}, el('code', {}, info.bash))),
            [quitButton()]);
    }

    function renderConnection() {
        const box = document.getElementById('connection');
        const port = state.session ? state.session.port : '';
        const hosted = location.protocol === 'https:';
        let content;
        switch (state.mode) {
            case 'connecting':
                content = statusWindow('yellow', 'Connecting to gitro ui', el('p', {}, `On 127.0.0.1:${port}.`));
                break;
            case 'live':
                content = renderLive();
                break;
            case 'lost':
                content = statusWindow('yellow', "gitro ui isn't answering", [
                    el('p', {}, `It was on 127.0.0.1:${port}. This page keeps trying, and shows its servers as they were.`),
                    hosted ? el('p', {}, 'If your browser asked whether this site may access apps and services on this device, ' +
                        'it needs that permission to reach gitro ui.') : null,
                    el('p', {}, FROM_FILE ? 'If it stopped, start it again, and this page connects to it by itself:'
                        : 'If it stopped, start it again:'),
                    startHelp()]);
                break;
            case 'denied':
                content = statusWindow('red', 'gitro ui refused this page', [
                    el('p', {}, FROM_FILE
                        ? "Its session file names a token it doesn't accept. Restart it: gitro ui stop, then gitro ui."
                        : "Its token changed, which means it was restarted. Open this page through gitro ui again:"),
                    FROM_FILE ? null : startHelp()], [demoButton('Watch a demo')]);
                break;
            case 'outdated':
                content = statusWindow('yellow', "This page and gitro ui don't match", el('p', {},
                    `The page speaks version ${API_VERSION} of gitro ui's API, and gitro ui speaks version ${state.info.api}. ` +
                    'Use the page from the clone gitro ui runs from, or update jigs.'));
                break;
            case 'demo': {
                const found = FROM_FILE && state.found;
                content = statusWindow('blue', 'Demo', [
                    el('p', {}, window.JIGS_GITRO_DEMO
                        ? 'It replays real gitro answers recorded from the jigs repository: an outside caller reviewing it, ' +
                          'and answers to the suggested requests. Nothing here runs on your computer.'
                        : 'Its recorded data is missing (data/gitro-demo.js).'),
                    found ? el('p', { class: 'found' }, el('strong', {}, 'gitro ui is running on this computer. '),
                        el('button', { type: 'button', onclick: () => connect(found, false) }, 'Connect to it')) : null],
                    [el('button', { type: 'button', onclick: leaveDemo }, 'Leave the demo')]);
                break;
            }
            default:
                content = renderIdle();
        }
        box.replaceChildren(content);
    }

    let quitArmed = null;

    /** Stopping gitro ui ends every server, so the first click asks, and the second stops it. */
    function quitButton() {
        const count = [...state.servers.values()].filter((entry) => entry.view.state === 'running').length;
        return el('button', { type: 'button', class: 'stop', onclick: async () => {
            if (!quitArmed) {
                quitArmed = setTimeout(() => { quitArmed = null; render(); }, 4000);
                render();
                return;
            }
            clearTimeout(quitArmed);
            quitArmed = null;
            try {
                await state.api.quit();
                // The session file still names it for a moment, and it mustn't be reconnected to meanwhile.
                state.tried = { token: state.session.token, at: Date.now() };
                save(sessionStorage, SESSION_KEY, null);
                goIdle('stopped');
            }
            catch (error) {
                state.mode = 'lost';
                render();
            }
        } }, quitArmed ? `Stop gitro ui and ${count === 1 ? 'its server' : `its ${count} servers`}?` : 'Stop gitro ui');
    }

    /* START FORM ======================================================================================================= */

    const form = document.getElementById('start-form');
    const startError = document.getElementById('start-error');

    function recentPairs() {
        return load(localStorage, RECENT_KEY) || [];
    }

    function remember(repo, dir) {
        const pairs = recentPairs().filter((pair) => pair.repo !== repo || pair.dir !== dir);
        pairs.unshift({ repo, dir });
        save(localStorage, RECENT_KEY, pairs.slice(0, RECENT_LIMIT));
    }

    function forget(target) {
        save(localStorage, RECENT_KEY, recentPairs().filter((pair) => pair.repo !== target.repo || pair.dir !== target.dir));
    }

    /** A path without the separator a suggestion leaves at its end, except a root's: D:\ and / stay. */
    function trimPath(path) {
        let trimmed = path;
        while (/[\\/]$/.test(trimmed) && !/^([A-Za-z]:)?[\\/]$/.test(trimmed)) trimmed = trimmed.slice(0, -1);
        return trimmed;
    }

    async function startServer(repo, dir) {
        repo = trimPath(repo);
        dir = trimPath(dir);
        startError.textContent = '';
        if (state.mode !== 'live') {
            startError.textContent = 'Start gitro ui first.';
            return;
        }
        if (!repo || !dir) {
            startError.textContent = 'Fill in both folders.';
            return;
        }
        const button = document.getElementById('start-button');
        button.disabled = true;
        try {
            await state.api.addServer(repo, dir);
            remember(repo, dir);
            render();
        }
        catch (error) {
            startError.textContent = error.message;
        }
        finally {
            button.disabled = state.mode !== 'live';
        }
    }

    // Whether a folder dialog is open, which keeps the Browse buttons off until it closes.
    let picking = false;

    async function browse(button) {
        const input = document.getElementById(button.dataset.for);
        const title = button.dataset.for === 'repo' ? 'Choose the repository' : 'Choose the request folder';
        startError.textContent = '';
        picking = true;
        button.disabled = true;
        button.textContent = 'Choosing';
        try {
            const result = await state.api.pickFolder(title, input.value.trim());
            if (result.path) input.value = result.path;
        }
        catch (error) {
            startError.textContent = error.message;
        }
        finally {
            picking = false;
            button.textContent = 'Browse';
            render();
        }
    }

    form.addEventListener('submit', (event) => {
        event.preventDefault();
        startServer(document.getElementById('repo').value.trim(), document.getElementById('dir').value.trim());
    });
    for (const button of form.querySelectorAll('.browse')) button.addEventListener('click', () => browse(button));

    function renderStart() {
        const live = state.mode === 'live';
        const platform = live && state.info ? state.info.platform : 'demo';
        const [repoHint, dirHint] = PLACEHOLDERS[platform] || PLACEHOLDERS.linux;
        document.getElementById('repo').placeholder = repoHint;
        document.getElementById('dir').placeholder = dirHint;
        document.getElementById('path-forms').textContent = platform === 'windows'
            ? 'Windows paths and Git Bash paths both work.' : '';
        // Browse stays in view while gitro ui isn't connected, switched off, so it's clear the page has it.
        // It's hidden only where a connected companion has no folder dialog.
        for (const button of form.querySelectorAll('.browse')) {
            button.hidden = live && !state.info.picker;
            button.disabled = !live || picking;
            button.title = live ? '' : 'Browsing needs gitro ui running.';
        }
        document.getElementById('start-button').disabled = !live;
        document.getElementById('start-note').textContent = live ? ''
            : state.mode === 'demo' ? "Starting servers needs gitro ui. The server below is the demo's recording."
            : 'Starting servers needs gitro ui running.';

        const box = document.getElementById('recent');
        const pairs = live ? recentPairs() : [];
        if (!pairs.length) {
            box.replaceChildren();
            return;
        }
        box.replaceChildren(el('h3', {}, 'Recent'), el('ul', {}, pairs.map((pair) => el('li', {},
            el('div', { class: 'paths' }, pair.repo, el('br'), el('span', {}, 'requests in '), pair.dir),
            el('button', { type: 'button', onclick: () => startServer(pair.repo, pair.dir) }, 'Start'),
            el('button', { type: 'button', class: 'quiet', onclick: () => { forget(pair); render(); } }, 'Forget')))));
    }

    /* PATH SUGGESTIONS ================================================================================================= */

    /** Suggests subfolders while a path is typed, from the companion, which can list folders where the page can't.
     *  The text up to the last separator names the folder to list, and the rest picks among its subfolders.
     *  Tab takes the first or chosen one when part of a name is typed, so a second Tab moves on as usual.
     *  Up and Down choose, Enter takes the chosen one, and Escape closes the list. Folders starting with a dot
     *  are suggested once a dot is typed. */
    function suggestPaths(input) {
        const list = el('ul', { class: 'suggestions', role: 'listbox', id: `${input.id}-suggestions`, hidden: true });
        input.after(list);
        input.setAttribute('role', 'combobox');
        input.setAttribute('aria-autocomplete', 'list');
        input.setAttribute('aria-expanded', 'false');
        input.setAttribute('aria-controls', list.id);

        // One listing per folder, kept while the field has focus, so typing filters without asking again.
        const listings = new Map();
        let items = [];
        let chosen = -1;
        let partial = '';
        let asked = 0;

        function close() {
            items = [];
            chosen = -1;
            list.hidden = true;
            list.replaceChildren();
            input.setAttribute('aria-expanded', 'false');
            input.removeAttribute('aria-activedescendant');
        }

        function show(truncated) {
            list.replaceChildren(...items.map((item, index) => el('li', {
                role: 'option',
                id: `${list.id}-${index}`,
                'aria-selected': String(index === chosen),
                onmousedown: (event) => {
                    // Before the input loses focus, which would close the list.
                    event.preventDefault();
                    take(index);
                },
            }, el('span', { class: 'name' }, item.name), item.repo ? el('span', { class: 'tag' }, 'repository') : null)),
            ...(truncated ? [el('li', { class: 'more', 'aria-hidden': 'true' }, 'More folders than these. Keep typing to narrow them.')] : []));
            list.hidden = false;
            input.setAttribute('aria-expanded', 'true');
            if (chosen >= 0) {
                input.setAttribute('aria-activedescendant', `${list.id}-${chosen}`);
                document.getElementById(`${list.id}-${chosen}`).scrollIntoView({ block: 'nearest' });
            }
            else input.removeAttribute('aria-activedescendant');
        }

        async function update() {
            const text = input.value;
            const cut = Math.max(text.lastIndexOf('/'), text.lastIndexOf('\\'));
            if (state.mode !== 'live' || document.activeElement !== input || cut < 0) {
                close();
                return;
            }
            const parent = text.slice(0, cut + 1);
            partial = text.slice(cut + 1);
            const ask = ++asked;
            if (!listings.has(parent)) listings.set(parent, state.api.folders(parent).catch(() => null));
            const listing = await listings.get(parent);
            if (ask !== asked) return;
            const typed = partial.toLowerCase();
            const matches = listing ? listing.folders.filter((folder) => (typed.startsWith('.') || !folder.name.startsWith('.'))
                && folder.name.toLowerCase().startsWith(typed)) : [];
            // A name typed in full, with nothing else to choose, needs no list.
            if (!matches.length || (matches.length === 1 && matches[0].name === partial)) {
                close();
                return;
            }
            items = matches.slice(0, SUGGESTION_LIMIT).map((folder) => ({ ...folder, path: parent + folder.name + text[cut] }));
            chosen = -1;
            show(listing.truncated || matches.length > SUGGESTION_LIMIT);
        }

        function take(index) {
            input.value = items[index].path;
            update();
        }

        input.addEventListener('input', update);
        input.addEventListener('focus', () => {
            listings.clear();
            update();
        });
        input.addEventListener('blur', close);
        input.addEventListener('keydown', (event) => {
            if (list.hidden) return;
            if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
                event.preventDefault();
                const step = event.key === 'ArrowDown' ? 1 : -1;
                chosen = (chosen + step + items.length + 1) % (items.length + 1);
                if (chosen === items.length) chosen = -1;
                show(list.querySelector('.more') !== null);
            }
            else if (event.key === 'Enter' && chosen >= 0) {
                event.preventDefault();
                take(chosen);
            }
            else if (event.key === 'Tab' && !event.shiftKey && partial) {
                event.preventDefault();
                take(Math.max(chosen, 0));
            }
            else if (event.key === 'Escape') {
                event.preventDefault();
                close();
            }
        });
    }

    suggestPaths(document.getElementById('repo'));
    suggestPaths(document.getElementById('dir'));

    /* SERVERS ========================================================================================================== */

    // One panel per server, built once and updated in place, so typing and open answers survive new events.
    const panels = new Map();

    function resetPanels() {
        for (const panel of panels.values()) panel.root.remove();
        panels.clear();
    }

    function stateLabel(view) {
        if (view.state === 'running') return 'Running';
        if (view.state === 'exited') return `Exited with code ${view.exitCode}`;
        return 'Stopped';
    }

    /** A response, with diff lines colored when it's a diff or patch. */
    function renderAnswer(text) {
        const lines = text.replace(/\n$/, '').split('\n');
        const isDiff = lines.some((line) => line.startsWith('diff --git') || line.startsWith('@@'));
        return el('pre', {}, lines.map((line, index) => {
            let kind = null;
            if (index === 0 && line.startsWith('# gitro exit=')) kind = 'line-head';
            else if (isDiff && line.startsWith('@@')) kind = 'line-hunk';
            else if (isDiff && line.startsWith('+') && !line.startsWith('+++')) kind = 'line-add';
            else if (isDiff && line.startsWith('-') && !line.startsWith('---')) kind = 'line-del';
            return [el('span', { class: kind }, line), '\n'];
        }));
    }

    function createPanel(id) {
        const open = new Set();
        const answers = new Map();
        const seen = new Set();
        let entry = null;
        let shared = false;
        let shownState = null;
        let built = false;

        const title = el('h3');
        const badge = el('span', { class: 'state' });
        const actions = el('div', { class: 'actions' });
        const paths = el('dl', { class: 'server-paths' });
        const reason = el('p', { class: 'exit-reason' });
        const input = el('input', { type: 'text', spellcheck: 'false', 'aria-label': 'gitro request', placeholder: 'status --short --branch' });
        const sendButton = el('button', { type: 'submit' }, 'Send');
        const message = el('p', { class: 'send-error', role: 'alert' });
        const send = el('form', { class: 'send', onsubmit: (event) => { event.preventDefault(); sendRequest(input.value); } },
            input, sendButton);
        const suggestions = SUGGESTED.map((text) => el('button', { type: 'button', onclick: () => sendRequest(text) }, text));
        const quick = el('div', { class: 'quick' }, el('span', {}, 'Try'), suggestions);
        const rows = el('tbody');
        const table = el('table', { class: 'requests' },
            el('thead', {}, el('tr', {}, el('th', {}, 'Time'), el('th', {}, 'Request'), el('th', {}, 'Exit'), el('th', { class: 'from' }, 'From'))),
            rows);
        const noRequests = el('p', { class: 'no-requests' });
        const outputSummary = el('summary');
        const outputText = el('pre');
        const output = el('details', { class: 'server-output' }, outputSummary, outputText);
        const root = el('article', { class: 'server', 'aria-labelledby': `server-${id}` },
            el('div', { class: 'server-head' }, title, badge, actions), paths, reason, send, message, quick, table, noRequests, output);
        title.id = `server-${id}`;

        async function sendRequest(text) {
            message.textContent = '';
            let args;
            try { args = splitArgs(text.trim()); }
            catch (error) { message.textContent = error.message; return; }
            if (!args.length) {
                message.textContent = 'Type a gitro request, such as status --short.';
                return;
            }
            try {
                await state.api.request(id, args);
                if (text === input.value) input.value = '';
            }
            catch (error) { message.textContent = error.message; }
        }

        async function act(action) {
            message.textContent = '';
            try { await state.api.act(id, action); }
            catch (error) { message.textContent = error.message; }
        }

        async function toggle(name) {
            if (open.has(name)) open.delete(name);
            else {
                open.add(name);
                if (!answers.has(name)) {
                    answers.set(name, null);
                    state.api.response(id, name)
                        .then((text) => answers.set(name, { text }), (error) => answers.set(name, { error: error.message }))
                        .then(() => update(entry, shared));
                }
            }
            update(entry, shared);
        }

        function row(event) {
            const fresh = built && !seen.has(event.name);
            seen.add(event.name);
            const isOpen = open.has(event.name);
            const line = el('tr', { class: fresh ? 'new' : null },
                el('td', { class: 'time' }, formatTime(event.time)),
                el('td', {}, el('button', { type: 'button', class: 'request', 'aria-expanded': String(isOpen),
                    title: isOpen ? 'Hide the response' : 'Show the response', onclick: () => toggle(event.name) }, event.request)),
                el('td', { class: event.exit ? 'exit failed' : 'exit' }, String(event.exit)),
                el('td', { class: 'from' }, event.own ? 'This page' : 'Caller'));
            if (fresh) setTimeout(() => line.classList.remove('new'), 60);
            if (!isOpen) return [line];
            const answer = answers.get(event.name);
            let body;
            if (!answer) body = el('p', {}, 'Loading the response.');
            else if (answer.error) body = el('p', { class: 'form-error' }, answer.error);
            else body = renderAnswer(answer.text);
            return [line, el('tr', {}, el('td', { class: 'answer', colspan: '4' }, body))];
        }

        /** Shows the server's state. 'shared' says another server answers for the same repository,
         *  so the title names the request folder too. */
        function update(next, sharedRepo) {
            entry = next;
            shared = sharedRepo;
            const view = entry.view;
            const running = view.state === 'running';
            title.replaceChildren(baseName(view.repo),
                ...(shared ? [el('span', { class: 'title-folder' }, `requests in ${baseName(view.dir)}`)] : []));
            root.className = `server ${view.state}`;
            badge.className = `state ${view.state}`;
            badge.textContent = stateLabel(view);
            if (shownState !== view.state) {
                shownState = view.state;
                actions.replaceChildren(...(running
                    ? [el('button', { type: 'button', class: 'stop', onclick: () => act('stop') }, 'Stop'),
                        el('button', { type: 'button', onclick: () => act('restart') }, 'Restart')]
                    : [el('button', { type: 'button', onclick: () => act('restart') }, 'Start'),
                        el('button', { type: 'button', onclick: () => act('remove') }, 'Remove')]));
                input.disabled = !running;
                sendButton.disabled = !running;
                suggestions.forEach((button) => { button.disabled = !running; });
            }
            paths.replaceChildren(
                el('dt', {}, 'Repository'), el('dd', {}, el('code', {}, view.repo)),
                el('dt', {}, 'Request folder'), el('dd', {}, el('code', {}, view.dir)));
            // An exited server's last words are usually why it exited, such as a folder another server answers in.
            reason.hidden = !(view.state === 'exited' && entry.log.length);
            reason.textContent = reason.hidden ? '' : entry.log[entry.log.length - 1];
            rows.replaceChildren(...entry.requests.flatMap(row));
            table.hidden = entry.requests.length === 0;
            noRequests.hidden = entry.requests.length > 0;
            noRequests.textContent = running
                ? 'No requests yet. Send one above, or point a caller at the request folder.'
                : 'No requests.';
            outputSummary.textContent = `Server output (${entry.log.length} ${entry.log.length === 1 ? 'line' : 'lines'})`;
            outputText.textContent = entry.log.join('\n');
            built = true;
        }

        return { root, update };
    }

    function renderServers() {
        const box = document.getElementById('servers');
        for (const [id, panel] of panels) {
            if (!state.servers.has(id)) {
                panel.root.remove();
                panels.delete(id);
            }
        }
        const ids = [...state.servers.keys()].sort((a, b) => a - b);
        const perRepo = new Map();
        for (const entry of state.servers.values()) perRepo.set(entry.view.repo, (perRepo.get(entry.view.repo) || 0) + 1);
        for (const id of ids) {
            let panel = panels.get(id);
            if (!panel) {
                panel = createPanel(id);
                panels.set(id, panel);
            }
            const entry = state.servers.get(id);
            panel.update(entry, perRepo.get(entry.view.repo) > 1);
        }
        // Moving a panel would take focus from a request being typed in it, so panels move only when the order changes.
        const wanted = ids.map((id) => panels.get(id).root);
        const shown = [...box.querySelectorAll(':scope > .server')];
        if (wanted.length !== shown.length || wanted.some((root, index) => root !== shown[index])) box.append(...wanted);
        let empty = box.querySelector('.empty');
        if (ids.length === 0) {
            if (!empty) box.prepend(empty = el('p', { class: 'empty' }));
            if (state.mode === 'live') empty.textContent = 'No servers yet. Start one above for any repository on this machine.';
            else if (state.mode === 'demo') empty.textContent = 'The demo server was removed. Leave the demo and watch it again to bring it back.';
            else if (state.mode === 'lost') empty.textContent = 'No servers.';
            else empty.textContent = 'Servers appear here while gitro ui runs.';
        }
        else if (empty) empty.remove();
    }

    /* RENDER =========================================================================================================== */

    let renderQueued = false;

    function render() {
        if (renderQueued) return;
        renderQueued = true;
        requestAnimationFrame(() => {
            renderQueued = false;
            renderConnection();
            renderStart();
            renderServers();
        });
    }

    /* START ============================================================================================================ */

    window.addEventListener('beforeunload', () => {
        state.leaving = true;
        // A download, or a link that opens elsewhere, leaves the page in place.
        setTimeout(() => { if (state.leaving && document.visibilityState === 'visible') resume(); }, 3000);
    });
    window.addEventListener('pagehide', () => { state.leaving = true; });
    window.addEventListener('pageshow', (event) => { if (event.persisted) resume(); });

    if (FROM_FILE) {
        discover();
        setInterval(discover, DISCOVER_MS);
        document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') discover(); });
    }
    else {
        const session = takeSession();
        if (session) connect(session, false);
    }
    render();

    window.JigsRun = { splitArgs };
})();
