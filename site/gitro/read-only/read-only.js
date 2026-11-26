/* "Read-only is harder than it looks": draws the recorded attempts from data/gitro-attempts.js as a ledger,
   each with what plain git did and what gitro did instead, and filters it by kind. */
(function () {
    'use strict';

    const { el } = window.Jigs;
    const data = window.JIGS_GITRO_ATTEMPTS;

    const KINDS = [
        ['writes', 'Writes'],
        ['programs', 'Starts programs'],
        ['outside', 'Reads outside'],
        ['leaks', 'Leaks'],
    ];
    const KIND_LABEL = Object.fromEntries(KINDS);

    /** Text with `code` in backticks, as elements. */
    function withCode(text) {
        return text.split('`').map((part, index) => (index % 2 ? el('code', {}, part) : part));
    }

    /** One line of the request per step, numbered when there's more than one. */
    function requestList(steps) {
        return el('ol', { class: 'request', 'aria-label': 'Request' }, steps.map((step, index) => el('li', {},
            steps.length > 1 ? el('span', { class: 'step' }, String(index + 1)) : null, step.request)));
    }

    function stepLabel(steps, index) {
        return steps.length > 1 ? el('span', { class: 'step' }, `${index + 1}`) : null;
    }

    /** What plain git did, step by step: each measured effect, or that the step did nothing. */
    function gitOutcome(steps) {
        const items = [];
        steps.forEach((step, index) => {
            const effects = step.effects.length ? step.effects : ['nothing beyond its output'];
            for (const effect of effects) items.push(el('li', {}, stepLabel(steps, index), el('span', {}, withCode(effect))));
        });
        return el('div', { class: 'outcome git' }, el('h4', {}, 'git'), el('ul', {}, items));
    }

    /** What gitro did: refused with its message, or answered with nothing else happening. Where the request was after
     *  a secret in the output, the answer's first line shows it isn't there; the generator checks that it isn't. */
    function gitroOutcome(attempt) {
        const steps = attempt.gitro;
        const items = steps.map((step, index) => {
            const firstLine = step.output.split('\n')[0];
            let said = ['Answered. Nothing was written and no program started.'];
            if (step.exit === 2) said = ['Refused: ', el('code', {}, firstLine.replace(/^gitro( [\w-]+)?: /, ''))];
            else if (attempt.group === 'leaks') said = ['Answered without the token: ', el('code', {}, firstLine)];
            return el('li', {}, stepLabel(steps, index), el('span', {}, said));
        });
        return el('div', { class: 'outcome gitro' }, el('h4', {}, 'gitro'), el('ul', {}, items));
    }

    function outputs(attempt) {
        const block = (title, step) => [
            el('h5', {}, `${title}, exit ${step.exit}`),
            el('pre', {}, step.output || '(no output)'),
        ];
        const column = (kind, title) => el('div', {}, attempt[kind].map((step, index) =>
            block(attempt[kind].length > 1 ? `${title}, step ${index + 1}` : title, step)));
        return el('details', {},
            el('summary', {}, 'Both outputs'),
            el('div', { class: 'outputs' }, column('git', 'git'), column('gitro', 'gitro')));
    }

    function attemptCard(attempt) {
        const setup = attempt.setup.length
            ? el('p', { class: 'setup' }, withCode(`In a project whose config sets ${attempt.setup.join(' and ')}.`))
            : null;
        return el('article', { class: 'attempt', id: attempt.id, 'data-kind': attempt.group },
            el('header', {},
                el('h3', {}, el('a', { href: `#${attempt.id}` }, attempt.title)),
                el('span', { class: 'kind' }, KIND_LABEL[attempt.group])),
            el('p', { class: 'about' }, withCode(attempt.about)),
            setup,
            requestList(attempt.gitro),
            el('div', { class: 'outcomes' }, gitOutcome(attempt.git), gitroOutcome(attempt)),
            outputs(attempt));
    }

    function filterButtons(attempts, ledger) {
        const group = document.querySelector('.filters');
        const counts = {};
        for (const attempt of attempts) counts[attempt.group] = (counts[attempt.group] || 0) + 1;
        const choices = [['all', 'All', attempts.length], ...KINDS.filter(([kind]) => counts[kind]).map(([kind, label]) =>
            [kind, label, counts[kind]])];
        const buttons = choices.map(([kind, label, count]) => el('button', {
            type: 'button',
            'aria-pressed': kind === 'all' ? 'true' : 'false',
            onclick: (event) => {
                for (const button of buttons) button.setAttribute('aria-pressed', button === event.currentTarget ? 'true' : 'false');
                for (const card of ledger.children) card.hidden = kind !== 'all' && card.dataset.kind !== kind;
            },
        }, label, el('span', { class: 'count' }, String(count))));
        group.append(...buttons);
    }

    if (!data || !Array.isArray(data.attempts)) {
        document.getElementById('no-data').hidden = false;
        document.getElementById('recorded').textContent = 'not available';
        return;
    }

    document.getElementById('recorded').textContent = data.recorded;
    const ledger = document.getElementById('ledger');
    ledger.append(...data.attempts.map(attemptCard));
    filterButtons(data.attempts, ledger);
})();
