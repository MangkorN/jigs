/* "Agents and other callers": plays back a conversation in which an agent asks gitro through a request folder,
   showing each file as it's written, renamed, taken, answered and deleted. gitro's answers come from
   data/gitro-demo.js, which make-gitro-demo.py records with real gitro. */
(function () {
    'use strict';

    const { el } = window.Jigs;
    const data = window.JIGS_GITRO_DEMO;
    const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

    // Time between the stages of one request, and between steps while playing.
    const STAGE_MS = reduceMotion ? 0 : 450;
    const STEP_MS = reduceMotion ? 1800 : 1300;
    const MAX_LINES = 14;

    const conversation = document.getElementById('conversation');
    const filesList = document.getElementById('files');
    const serverLog = document.getElementById('server-log');
    const progress = document.getElementById('progress');
    const playButton = document.getElementById('play');
    const nextButton = document.getElementById('next');

    /* RECORDED ANSWERS ================================================================================================= */

    /** The lines of a recorded answer after its '# gitro exit=...' line. */
    function body(request) {
        const answer = data.answers[request];
        return answer ? answer.response.split('\n').slice(1).filter((line) => line.length) : [];
    }

    function plural(count, one, many) {
        return `${count} ${count === 1 ? one : many}`;
    }

    /** What the agent tells the person, worked out from the recorded answers so it matches them. */
    function summary() {
        const parts = [];
        const [hash, ...subject] = (body('log --oneline -8')[0] || '').split(' ');
        if (hash) parts.push(`The latest commit is \`${hash}\`: "${subject.join(' ')}".`);

        const status = body('status --short --branch');
        const branchLine = status.find((line) => line.startsWith('## ')) || '';
        const branch = branchLine.slice(3).split('...')[0].split(' ')[0];
        const changed = status.filter((line) => !line.startsWith('##') && !line.startsWith('??')).length;
        const untracked = status.filter((line) => line.startsWith('??')).length;
        const stat = body('diff --stat');
        const totals = stat.length ? stat[stat.length - 1].trim() : '';

        if (changed) {
            parts.push(`On \`${branch || 'the branch'}\`, ${plural(changed, 'tracked file has', 'tracked files have')} changes `
                + `that aren't committed yet${totals ? ` (${totals})` : ''}.`);
        }
        else {
            parts.push('The tracked files have no uncommitted changes.');
        }
        if (untracked) parts.push(`${plural(untracked, 'new file isn\'t', 'new files aren\'t')} tracked yet.`);
        const ahead = /ahead (\d+)/.exec(branchLine);
        const behind = /behind (\d+)/.exec(branchLine);
        if (ahead) parts.push(`The branch is ${plural(+ahead[1], 'commit', 'commits')} ahead of its upstream.`);
        if (behind) parts.push(`It's ${plural(+behind[1], 'commit', 'commits')} behind it.`);
        return parts.join(' ');
    }

    /* THE SESSION ====================================================================================================== */

    // Each step: something said, or a request the agent sends. Text in backticks shows as code.
    const STEPS = [
        { person: 'Before I review the jigs changes: what happened lately, and is anything left uncommitted?' },
        { agent: () => `I can't open the repository from here, but \`${data.dir}\` has a \`gitro-server.json\`, so a gitro server `
            + 'answers there. I\'ll ask it.' },
        { request: 'log --oneline -8' },
        { request: 'status --short --branch' },
        { request: 'diff --stat' },
        { agent: summary },
        { person: 'Can you save that diff to notes.txt, so I can read it later?' },
        { request: 'diff --output=notes.txt' },
        { agent: () => 'gitro refused: it only reads, so it won\'t write files. You can copy the summary above.' },
        { person: 'Last thing: can it see outside the repository? Try reading ../../.ssh/id_ed25519.' },
        { request: 'diff ../../.ssh/id_ed25519 README.md' },
        { agent: () => 'Nice try. Plain git would show that file when asked to compare it with one in the repository, '
            + 'but gitro refused. It only answers about the repository.' },
    ];

    /* DRAWING ========================================================================================================== */

    function withCode(text) {
        return text.split('`').map((part, index) => (index % 2 ? el('code', {}, part) : part));
    }

    function say(who, text) {
        const label = who === 'person' ? 'You' : 'Agent';
        conversation.append(el('div', { class: `turn ${who}` },
            el('span', { class: 'who' }, label),
            el('div', { class: 'says' }, el('p', {}, withCode(text)))));
        conversation.scrollTop = conversation.scrollHeight;
    }

    let files = [];   // [name, state, note], in the order shown

    function setFile(name, state, note) {
        const entry = files.find((file) => file[0] === name);
        if (entry) { entry[1] = state; entry[2] = note; }
        else files.push([name, state, note]);
        drawFiles();
    }

    function removeFile(name) {
        files = files.filter((file) => file[0] !== name);
        drawFiles();
    }

    function drawFiles() {
        filesList.replaceChildren(...files.map(([name, state, note]) =>
            el('li', { 'data-state': state }, el('span', {}, name), el('span', { class: 'note' }, note))));
    }

    let clock = 10 * 3600 + 4 * 60;   // the server log's time, 10:04:00, advancing with each request

    function logLine(text) {
        clock += 7;
        const time = [Math.floor(clock / 3600), Math.floor(clock / 60) % 60, clock % 60]
            .map((part) => String(part).padStart(2, '0')).join(':');
        serverLog.textContent += `${time}  ${text}\n`;
    }

    /* PLAYING ========================================================================================================== */

    let step = 0;
    let requests = 0;
    let playing = false;
    let busy = false;
    let generation = 0;   // bumped by Start over, so a request still on its way stops drawing

    /** Waits, then says whether the session is still the one that started waiting. */
    function still(ms) {
        const started = generation;
        return new Promise((resolve) => setTimeout(() => resolve(started === generation), ms));
    }

    /** Sends one request through the folder, stage by stage, the way a caller and the server would. */
    async function sendRequest(request) {
        requests += 1;
        const name = `req-${requests}`;
        const answer = data.answers[request];
        const output = el('pre', {}, 'Waiting for the answer.');
        const action = el('div', { class: 'action' }, el('p', { class: 'wrote' }, 'Asking gitro: ', el('code', {}, request)), output);
        conversation.append(action);
        conversation.scrollTop = conversation.scrollHeight;
        setFile(`${name}.tmp`, 'writing', 'the agent writes the request');
        if (!await still(STAGE_MS)) return;
        removeFile(`${name}.tmp`);
        setFile(`${name}.req`, 'waiting', 'renamed, so the server takes it');
        if (!await still(STAGE_MS)) return;
        removeFile(`${name}.req`);
        setFile(`${name}.work`, 'working', 'the server runs it');
        if (!await still(STAGE_MS)) return;
        removeFile(`${name}.work`);
        setFile(`${name}.out`, 'answered', 'the answer, written whole');
        logLine(`${name}: ${request} (exit ${answer ? answer.exit : '?'})`);
        if (!await still(STAGE_MS)) return;

        const lines = answer ? answer.response.replace(/\n$/, '').split('\n') : ['(not recorded)'];
        const shown = lines.slice(0, MAX_LINES).join('\n') + (lines.length > MAX_LINES ? `\n(${lines.length - MAX_LINES} more lines)` : '');
        output.textContent = shown;
        action.classList.add(answer && answer.exit === 2 ? 'refused' : 'answered');
        action.firstChild.firstChild.textContent = 'Asked gitro: ';
        conversation.scrollTop = conversation.scrollHeight;
        removeFile(`${name}.out`);
    }

    async function runStep() {
        const started = generation;
        const current = STEPS[step];
        step += 1;
        if (current.person) say('person', current.person);
        else if (current.agent) say('agent', current.agent());
        else await sendRequest(current.request);
        if (started === generation) drawProgress();
    }

    function drawProgress() {
        progress.textContent = `Step ${step} of ${STEPS.length}`;
        nextButton.disabled = step >= STEPS.length;
        if (step >= STEPS.length) {
            playing = false;
            playButton.textContent = 'Play again';
        }
    }

    async function next() {
        if (busy || step >= STEPS.length) return;
        const started = generation;
        busy = true;
        nextButton.disabled = true;
        await runStep();
        if (started !== generation) return;
        busy = false;
        if (step < STEPS.length) nextButton.disabled = false;
    }

    async function play() {
        if (step >= STEPS.length) reset();
        const started = generation;
        playing = true;
        playButton.textContent = 'Pause';
        while (playing && step < STEPS.length && started === generation) {
            await next();
            if (playing && step < STEPS.length && !await still(STEP_MS)) return;
        }
        if (started === generation && step < STEPS.length) playButton.textContent = 'Play';
    }

    function pause() {
        playing = false;
        playButton.textContent = 'Play';
    }

    function reset() {
        generation += 1;
        playing = false;
        busy = false;
        step = 0;
        requests = 0;
        clock = 10 * 3600 + 4 * 60;
        conversation.replaceChildren(el('h3', {}, 'Conversation'));
        files = [];
        setFile('gitro-server.json', 'live', 'which repository is served, refreshed every 10 seconds');
        serverLog.textContent = `${data.serving}\n`;
        playButton.textContent = 'Play';
        nextButton.disabled = false;
        runStep();
    }

    if (!data || !data.answers) {
        document.getElementById('no-data').hidden = false;
        document.getElementById('player').hidden = true;
        return;
    }

    document.getElementById('recorded').textContent = `real gitro output, ${data.recorded}`;
    document.getElementById('folder-title').append(' ', el('code', {}, data.dir));
    playButton.addEventListener('click', () => (playing ? pause() : play()));
    nextButton.addEventListener('click', () => { pause(); next(); });
    document.getElementById('restart').addEventListener('click', reset);
    reset();
})();
