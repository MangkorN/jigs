#!/usr/bin/env python3
"""Writes gitro-attempts.js: requests that try to make a read write, start a program or reach outside the repository,
each run through plain git and through gitro, for the site's "Read-only is harder than it looks" page.

Every effect on the page is measured, not described: each attempt runs in a fresh copy of a small project, and the
script compares every file before and after, records which programs started, and checks whether a file outside the
project was shown. It stops without writing anything if gitro shows any effect, if an attempt meant to be refused
isn't, or if plain git no longer shows the effect the page describes.

    python3 site/data/make-gitro-attempts.py

Needs bash and git on PATH (from Git Bash on Windows).
"""

import datetime
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
JIGS = os.path.dirname(os.path.dirname(HERE))
GITRO = os.path.join(JIGS, 'bash', 'functions', 'gitro.sh')
OUTPUT = os.path.join(HERE, 'gitro-attempts.js')

# Placeholders in requests, replaced with real paths when run and shown as below.
PAYLOAD = '{payload}'   # a script that records that it ran
SHOWN = {'{payload}': '~/payload.sh'}
SECRET = 'API_TOKEN=example-0000-not-real'   # the file beside the project
MAX_LINES = 14

# Settings a repository can have that make git start a program, each pointing at the payload with its role.
SETUPS = {
    'external': ('diff.external', 'an external diff program (`diff.external`)'),
    'textconv': ('diff.docs.textconv', 'a textconv converter for Markdown files (`diff.docs.textconv`)'),
    'fsmonitor': ('core.fsmonitor', 'a file-watcher hook (`core.fsmonitor`)'),
    'gpg': ('gpg.program', 'gpg for signature checks (`gpg.program`)'),
}

# Each attempt: id, group, title, what the request is after, the settings it needs, whether gitro refuses it,
# and its steps, each a request as gitro gets it, optionally with a different request for plain git.
ATTEMPTS = [
    {'id': 'output-config', 'group': 'writes', 'refused': True,
     'title': 'Overwrite .git/config, then run its program with diff',
     'about': '`--output` sends the output of `show` to any file. Formatted as config, it gives the next `git diff` an '
              'external program to run. Codex CLI\'s default allow-list trusted both commands.',
     'steps': [['show', '--format=[diff]%n external = ' + PAYLOAD, '--no-patch', '--output=.git/config', 'HEAD'],
               ['diff']]},
    {'id': 'output-outside', 'group': 'writes', 'refused': True,
     'title': 'Write a file outside the project',
     'about': '`--output` works on `diff`, `log` and `show` alike, with any path.',
     'steps': [['diff', '--output=../notes.txt']]},
    {'id': 'diff-index', 'group': 'writes', 'refused': False,
     'title': 'Save the index with a plain diff',
     'about': 'When file times have changed, `diff` refreshes the index and saves it. Depending on the git version, '
              '`status` does too.',
     'steps': [['diff', '--stat']]},
    {'id': 'branch-create', 'group': 'writes', 'refused': False,
     'title': 'A branch name, where a list was meant',
     'about': '`git branch` lists, but given a name it creates one. `tag` works the same way.',
     'steps': [['branch', 'experiment']]},
    {'id': 'stash', 'group': 'writes', 'refused': True,
     'title': 'Stash, which sounds like a look',
     'about': '`stash` with no subcommand saves the changes away and resets the working tree.',
     'steps': [['stash']]},
    {'id': 'ext-diff', 'group': 'programs', 'refused': True, 'setup': ['external'],
     'title': 'Run the configured external diff program',
     'about': 'A repository can name a program to show diffs with. `--ext-diff` runs it.',
     'steps': [['diff', '--ext-diff']]},
    {'id': 'textconv', 'group': 'programs', 'refused': False, 'setup': ['textconv'],
     'title': 'Run a textconv converter with log -p',
     'about': 'A repository can convert files before diffing them, such as documents to text. `log -p` runs the converter.',
     'steps': [['log', '-p', '--', 'README.md']]},
    {'id': 'grep-pager', 'group': 'programs', 'refused': True,
     'title': 'Open the matches in a "pager"',
     'about': '`grep -O` opens the matching files in the program named after it.',
     'steps': [['grep', '-O' + PAYLOAD, 'project']]},
    {'id': 'signature', 'group': 'programs', 'refused': True, 'setup': ['gpg'],
     'title': 'Ask whether commits are signed',
     'about': 'The `%G?` placeholder checks each signed commit\'s signature, which starts gpg.',
     'steps': [['log', '--format=%h %G? %s', '-3']]},
    {'id': 'fsmonitor', 'group': 'programs', 'refused': False, 'setup': ['fsmonitor'],
     'title': 'Run the file-watcher hook with status',
     'about': 'A file-watcher hook speeds `status` up in large repositories by running on every `status`.',
     'steps': [['status', '--short']]},
    {'id': 'diff-outside', 'group': 'outside', 'refused': True,
     'title': 'Read a file outside with two file names',
     'about': 'Given two names and one outside the project, `git diff` compares the files on disk, no '
              '`--no-index` needed.',
     'steps': [['diff', '../secret.txt', 'README.md']]},
    {'id': 'diff-outside-paths', 'group': 'outside', 'refused': True,
     'title': 'Read a file outside with names after --',
     'about': 'Putting the names after `--` doesn\'t prevent it.',
     'steps': [['diff', '--', '../secret.txt', 'README.md']]},
    {'id': 'no-index', 'group': 'outside', 'refused': True,
     'title': 'Read a file outside with --no-index',
     'about': 'The explicit form, which compares any two files on disk.',
     'steps': [['diff', '--no-index', '../secret.txt', 'README.md']]},
    {'id': 'blame-contents', 'group': 'outside', 'refused': True,
     'title': 'Blame with borrowed contents',
     'about': '`blame --contents` reads the file to annotate from anywhere.',
     'steps': [['blame', '--contents', '../secret.txt', '--', 'README.md']]},
    {'id': 'abbreviation', 'group': 'outside', 'refused': True,
     'title': 'Read a file outside with an abbreviated flag',
     'about': 'Most git commands accept any unambiguous abbreviation of a flag, so a list of flags to refuse would '
              'need every abbreviation too.',
     'steps': [['blame', '--cont', '../secret.txt', '--', 'README.md']]},
    {'id': 'remote', 'group': 'leaks', 'refused': False,
     'title': 'List the remotes',
     'about': 'A remote URL can carry a token, and `git remote -v` prints it.',
     'steps': [{'gitro': ['remote'], 'git': ['remote', '-v']}]},
]


def shell_words(args):
    """The request as one line, quoting arguments with spaces or quotes."""
    words = []
    for arg in args:
        if arg and not any(c in arg for c in ' \'"%[]'):
            words.append(arg)
        else:
            words.append("'" + arg.replace("'", "'\\''") + "'")
    return ' '.join(words)


class Lab:
    """A temporary home holding a small project, a file beside it, and the payload."""

    def __init__(self, bash):
        self.bash = bash
        self.root = tempfile.mkdtemp(prefix='gitro-attempts.')
        self.home = os.path.join(self.root, 'home')
        self.ran = os.path.join(self.root, 'ran.txt')
        self.payload = os.path.join(self.root, 'payload.sh')
        os.makedirs(self.home)
        self.env = dict(os.environ, HOME=self.home, GIT_CONFIG_NOSYSTEM='1', TMPDIR=os.path.join(self.root, 'tmp'),
                        GIT_AUTHOR_NAME='Ada', GIT_AUTHOR_EMAIL='ada@example.com',
                        GIT_COMMITTER_NAME='Ada', GIT_COMMITTER_EMAIL='ada@example.com',
                        GIT_AUTHOR_DATE='2026-11-20T10:00:00Z', GIT_COMMITTER_DATE='2026-11-20T10:00:00Z')
        for name in ('PAGER', 'GIT_PAGER', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_EXTERNAL_DIFF'):
            self.env.pop(name, None)
        os.makedirs(self.env['TMPDIR'])
        # The payload records the role it was started for, or 'payload'. git starts gpg with arguments of its own,
        # so gpg gets a script of its own.
        self.gpg = os.path.join(self.root, 'gpg.sh')
        ran = self.ran.replace('\\', '/')
        scripts = {self.payload: 'case $1 in ""|-*|*/*|*.*) role=payload ;; *) role=$1 ;; esac\n',
                   self.gpg: 'role=gpg\n'}
        for path, choose in scripts.items():
            with open(path, 'w', newline='\n') as script:
                script.write('#!/bin/sh\n%secho "$role" >> "%s"\n' % (choose, ran))
            os.chmod(path, 0o755)
        with open(os.path.join(self.root, 'secret.txt'), 'w', newline='\n') as secret:
            secret.write(SECRET + '\n')
        self.base = os.path.join(self.root, 'base')
        self.make_base()

    def git(self, cwd, *args, check=True):
        return subprocess.run(['git'] + list(args), cwd=cwd, env=self.env, check=check, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def make_base(self):
        os.makedirs(self.base)
        git = lambda *args: self.git(self.base, *args)
        git('init', '-q', '-b', 'main')
        files = {'README.md': '# project\n\nA small project.\n', '.gitattributes': '*.md diff=docs\n',
                 'src/app.py': 'print("hello")\n'}
        for path, text in files.items():
            os.makedirs(os.path.dirname(os.path.join(self.base, path)) or self.base, exist_ok=True)
            with open(os.path.join(self.base, path), 'w', newline='\n') as file:
                file.write(text)
        git('add', '.')
        git('commit', '-qm', 'Start the project')
        with open(os.path.join(self.base, 'README.md'), 'a', newline='\n') as file:
            file.write('\nRun it with python src/app.py.\n')
        git('commit', '-qam', 'Say how to run it')
        # A signed commit, signature and all, so asking for signature checks has something to check.
        with open(os.path.join(self.base, 'src/app.py'), 'w', newline='\n') as file:
            file.write('print("hello, world")\n')
        git('add', 'src/app.py')
        tree = git('write-tree').stdout.decode().strip()
        parent = git('rev-parse', 'HEAD').stdout.decode().strip()
        body = ('tree %s\nparent %s\nauthor Ada <ada@example.com> 1795600000 +0000\ncommitter Ada <ada@example.com> '
                '1795600000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEzBAABCAAdFiEE\n -----END PGP SIGNATURE-----\n\n'
                'Fix the greeting\n' % (tree, parent))
        commit = subprocess.run(['git', 'hash-object', '-t', 'commit', '-w', '--stdin'], cwd=self.base, env=self.env,
                                input=body.encode(), stdout=subprocess.PIPE, check=True).stdout.decode().strip()
        git('reset', '-q', '--soft', commit)
        with open(os.path.join(self.base, 'README.md'), 'a', newline='\n') as file:
            file.write('\nWork in progress.\n')
        git('remote', 'add', 'origin', 'https://ada:ghp_example0000notreal@git.example.com/team/project.git')

    def copy(self, setup):
        """A fresh copy of the project with settings from setup, its file times changed so git refreshes the index."""
        project = os.path.join(self.root, 'Repos', 'project')
        shutil.rmtree(os.path.join(self.root, 'Repos'), ignore_errors=True)
        shutil.copytree(self.base, project)
        shutil.copy(os.path.join(self.root, 'secret.txt'), os.path.join(self.root, 'Repos', 'secret.txt'))
        for name in setup:
            key = SETUPS[name][0]
            value = self.gpg if name == 'gpg' else '%s %s' % (self.payload, name)
            self.git(project, 'config', key, value.replace('\\', '/'))
        earlier = os.stat(os.path.join(project, 'README.md')).st_mtime - 100
        for path in ('README.md', 'src/app.py'):
            os.utime(os.path.join(project, path), (earlier, earlier))
        if os.path.exists(self.ran):
            os.remove(self.ran)
        return project

    def snapshot(self):
        files = {}
        for folder, _, names in os.walk(self.root):
            for name in names:
                path = os.path.join(folder, name)
                if path == self.ran:
                    continue
                with open(path, 'rb') as file:
                    files[os.path.relpath(path, os.path.join(self.root, 'Repos', 'project'))] = hashlib.sha1(file.read()).hexdigest()
        return files

    def resolve(self, args):
        return [arg.replace(PAYLOAD, self.payload.replace('\\', '/')) for arg in args]

    def shown(self, text):
        for placeholder, shown in SHOWN.items():
            text = text.replace(placeholder, shown)
        for form in {self.root, self.root.replace('\\', '/')}:
            text = text.replace(form + '/Repos/project', '~/Repos/project').replace(form, '~')
        return text

    def run(self, kind, project, args):
        if kind == 'git':
            result = subprocess.run(['git'] + self.resolve(args), cwd=project, env=self.env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        else:
            result = subprocess.run([self.bash, GITRO, '-C', project] + self.resolve(args), cwd=project, env=self.env,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return result.returncode, result.stdout.decode('utf-8', 'replace').replace('\r\n', '\n')

    def effects(self, before, after, output):
        """What a run did, in words, from the files that changed, the programs that started and what it printed."""
        found = []
        if os.path.exists(self.ran):
            with open(self.ran) as ran:
                roles = list(dict.fromkeys(line.strip() for line in ran if line.strip()))
            for role in roles:
                found.append('started ' + (SETUPS[role][1] if role in SETUPS else '`%s`' % SHOWN[PAYLOAD]))
        objects = 0
        for path in sorted(set(before) | set(after)):
            if before.get(path) == after.get(path):
                continue
            unix = path.replace('\\', '/')
            if unix.startswith('.git/objects/'):
                objects += path in after and path not in before
            elif unix.startswith('.git/logs/') or unix.endswith('.lock'):
                continue
            elif unix == '.git/index':
                found.append('rewrote the index (`.git/index`)')
            elif unix.startswith('.git/refs/heads/'):
                found.append('created the branch `%s`' % unix[len('.git/refs/heads/'):])
            elif unix == '.git/refs/stash':
                found.append('saved a stash')
            elif path not in after:
                found.append('removed `%s`' % unix)
            elif path not in before:
                found.append('wrote `%s`' % unix)
            else:
                found.append('rewrote `%s`' % unix)
        if objects:
            found.append('stored %d new object%s' % (objects, '' if objects == 1 else 's'))
        if SECRET in output:
            found.append('showed `../secret.txt`, which is outside the project')
        if 'ghp_example0000notreal' in output:
            found.append('showed the token in the remote URL')
        return found

    def attempt(self, kind, attempt):
        project = self.copy(attempt.get('setup', []))
        steps = []
        for step in attempt['steps']:
            args = step[kind] if isinstance(step, dict) else step
            before = self.snapshot()
            if os.path.exists(self.ran):
                os.remove(self.ran)
            code, output = self.run(kind, project, args)
            lines = output.rstrip('\n').split('\n') if output.strip() else []
            more = max(0, len(lines) - MAX_LINES)
            shown = '\n'.join(lines[:MAX_LINES]) + ('\n... %d more lines' % more if more else '')
            steps.append({'request': self.shown(shell_words(args)), 'exit': code, 'output': self.shown(shown),
                          'effects': self.effects(before, self.snapshot(), output)})
        return steps


def main():
    bash = shutil.which('bash')
    if not bash:
        sys.exit('bash is not on PATH.')
    lab = Lab(bash)
    problems, records = [], []
    try:
        for attempt in ATTEMPTS:
            git_steps = lab.attempt('git', attempt)
            gitro_steps = lab.attempt('gitro', attempt)
            if not any(step['effects'] for step in git_steps):
                problems.append('%s: plain git showed no effect, so the page would be wrong' % attempt['id'])
            for step in gitro_steps:
                if step['effects']:
                    problems.append('%s: gitro %s: %s' % (attempt['id'], step['request'], '; '.join(step['effects'])))
            if attempt['refused'] and gitro_steps[0]['exit'] != 2:
                problems.append('%s: gitro answered (exit %d) instead of refusing' % (attempt['id'], gitro_steps[0]['exit']))
            if not attempt['refused'] and gitro_steps[0]['exit'] != 0:
                problems.append('%s: gitro failed (exit %d): %s' % (attempt['id'], gitro_steps[0]['exit'], gitro_steps[0]['output']))
            records.append({
                'id': attempt['id'], 'group': attempt['group'], 'title': attempt['title'], 'about': attempt['about'],
                'refused': attempt['refused'], 'setup': [SETUPS[name][1] for name in attempt.get('setup', [])],
                'git': git_steps, 'gitro': gitro_steps,
            })
        version = subprocess.run(['git', '--version'], stdout=subprocess.PIPE).stdout.decode().strip()
    finally:
        shutil.rmtree(lab.root, ignore_errors=True)

    if problems:
        sys.exit('Nothing written:\n  ' + '\n  '.join(problems))
    data = {'recorded': '%s with %s' % (datetime.date.today().isoformat(), version), 'attempts': records}
    with open(OUTPUT, 'w', encoding='utf-8', newline='\n') as script:
        script.write('/* Generated by make-gitro-attempts.py: requests run through plain git and through gitro, with their\n'
                     '   measured effects, for the "Read-only is harder than it looks" page. Run that script again\n'
                     '   rather than editing this file. */\n')
        script.write('window.JIGS_GITRO_ATTEMPTS = %s;\n' % json.dumps(data, indent=1, ensure_ascii=False))
    print('wrote %s (%d attempts, recorded %s)' % (OUTPUT, len(records), data['recorded']))


if __name__ == '__main__':
    main()
