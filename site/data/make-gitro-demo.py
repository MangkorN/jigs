#!/usr/bin/env python3
"""Writes gitro-demo.js, the recorded session that the Run page and the callers page play back.

The answers are real gitro output, recorded from a small example repository this script builds: a family recipe
collection with a week of history, a change in progress, and a branch. Run it again after changing gitro:

    python3 site/data/make-gitro-demo.py

Needs bash and git on PATH (from Git Bash on Windows).
"""

import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
JIGS = os.path.dirname(os.path.dirname(HERE))
GITRO = os.path.join(JIGS, 'bash', 'functions', 'gitro.sh')
OUTPUT = os.path.join(HERE, 'gitro-demo.js')

# What the demo's outside caller asks, in order: a reviewer finding their way around, then three requests gitro refuses.
CALLER = [
    'status --short --branch',
    'log --oneline -8',
    'show --stat --oneline HEAD',
    'diff --stat',
    'grep -n -i sugar',
    'branch -d main',
    'diff --output=notes.txt',
    'diff ../../.ssh/id_ed25519 README.md',
]

# The Run page's suggested requests, which the demo also answers.
SUGGESTED = ['status --short --branch', 'log --oneline -10', 'diff --stat', 'diff --cached --stat', 'branch -vv']

# Paths shown in the demo instead of the temporary ones.
REPO = '~/Repos/recipes'
DIR = '~/Exchange/recipes'

# The example repository's history: (date, message, {file: contents}), oldest first.
HISTORY = [
    ('2026-11-02T09:12:00', 'Start the recipe collection',
     {'README.md': '# Recipes\n\nFamily recipes, one file each.\n'}),
    ('2026-11-02T09:40:00', 'Add chocolate chip cookies',
     {'cookies.md': '# Chocolate chip cookies\n\n- 225 g butter\n- 200 g sugar\n- 2 eggs\n- 300 g flour\n'
                    '- 200 g chocolate chips\n\nBake at 180 °C for 12 minutes.\n'}),
    ('2026-11-03T18:05:00', 'Add banana bread',
     {'banana-bread.md': '# Banana bread\n\n- 3 ripe bananas\n- 75 g butter\n- 150 g sugar\n- 1 egg\n- 190 g flour\n\n'
                         'Bake at 220 °C for 60 minutes.\n'}),
    ('2026-11-04T19:30:00', "Lower the banana bread's oven temperature, at the smoke alarm's request",
     {'banana-bread.md': '# Banana bread\n\n- 3 ripe bananas\n- 75 g butter\n- 150 g sugar\n- 1 egg\n- 190 g flour\n\n'
                         'Bake at 175 °C for 60 minutes.\n'}),
    ('2026-11-05T08:15:00', 'Halve the sugar in the cookies',
     {'cookies.md': '# Chocolate chip cookies\n\n- 225 g butter\n- 100 g sugar\n- 2 eggs\n- 300 g flour\n'
                    '- 200 g chocolate chips\n\nBake at 180 °C for 12 minutes.\n'}),
    ('2026-11-07T10:00:00', 'Add pancakes',
     {'pancakes.md': '# Pancakes\n\n- 200 g flour\n- 300 ml milk\n- 2 eggs\n- 1 tbsp sugar\n\nCook on a hot pan, '
                     'two minutes a side.\n'}),
    ('2026-11-08T09:20:00', 'Use oat milk in the pancakes',
     {'pancakes.md': '# Pancakes\n\n- 200 g flour\n- 300 ml oat milk\n- 2 eggs\n- 1 tbsp sugar\n\nCook on a hot pan, '
                     'two minutes a side.\n'}),
]
# Committed after the push, so main is one commit ahead of origin/main.
LOCAL = ('2026-11-09T11:45:00', 'Add a weekend shopping list',
         {'shopping-list.md': '# Weekend shopping\n\n- flour\n- oat milk\n- eggs\n- bananas\n'})
# A branch off the oat milk commit, for branch -vv.
BRANCH = ('vegan-pancakes', '2026-11-08T12:00:00', 'Replace the eggs in the pancakes with flax seeds',
          {'pancakes.md': '# Pancakes\n\n- 200 g flour\n- 300 ml oat milk\n- 2 tbsp ground flax seeds\n'
                          '- 1 tbsp sugar\n\nCook on a hot pan, two minutes a side.\n'})
# The change in progress: blueberries staged on the list, added to the pancakes but not staged, and a new recipe.
STAGED = {'shopping-list.md': '# Weekend shopping\n\n- flour\n- oat milk\n- eggs\n- bananas\n- blueberries\n'}
UNSTAGED = {'pancakes.md': '# Pancakes\n\n- 200 g flour\n- 300 ml oat milk\n- 2 eggs\n- 1 tbsp sugar\n'
                           '- 1 handful of blueberries\n\nCook on a hot pan, two minutes a side.\n'}
UNTRACKED = {'lasagna.md': '# Lasagna\n\nTo do: ask for the recipe.\n'}


def write(folder, files):
    for name, text in files.items():
        with open(os.path.join(folder, name), 'w', encoding='utf-8', newline='\n') as file:
            file.write(text)


def build(root):
    """Builds the example repository under root, with a bare origin, and returns its path."""
    env = dict(os.environ, HOME=root, GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Sam', GIT_AUTHOR_EMAIL='sam@example.com',
               GIT_COMMITTER_NAME='Sam', GIT_COMMITTER_EMAIL='sam@example.com')
    repo = os.path.join(root, 'recipes')
    origin = os.path.join(root, 'origin.git')

    def git(*args, date=None):
        extra = {'GIT_AUTHOR_DATE': date + 'Z', 'GIT_COMMITTER_DATE': date + 'Z'} if date else {}
        subprocess.run(['git'] + list(args), cwd=repo, env=dict(env, **extra), check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    os.makedirs(repo)
    subprocess.run(['git', 'init', '-q', '--bare', origin], env=env, check=True)
    git('init', '-q', '-b', 'main')
    git('config', 'commit.gpgSign', 'false')
    for date, message, files in HISTORY:
        write(repo, files)
        git('add', '.')
        git('commit', '-q', '-m', message, date=date)
    git('remote', 'add', 'origin', origin)
    git('push', '-q', '-u', 'origin', 'main')
    git('remote', 'set-url', 'origin', 'https://git.example.com/sam/recipes.git')

    name, date, message, files = BRANCH
    git('switch', '-q', '-c', name)
    write(repo, files)
    git('commit', '-q', '-am', message, date=date)
    git('switch', '-q', 'main')

    date, message, files = LOCAL
    write(repo, files)
    git('add', '.')
    git('commit', '-q', '-m', message, date=date)

    write(repo, STAGED)
    git('add', '.')
    write(repo, UNSTAGED)
    write(repo, UNTRACKED)
    return repo


def main():
    # On Windows, a bare 'bash' can start WSL's bash from System32, so bash is looked up on PATH.
    bash = shutil.which('bash')
    if not bash:
        sys.exit('bash is not on PATH.')

    root = tempfile.mkdtemp(prefix='gitro-demo.')
    try:
        repo = build(root)

        def gitro(request):
            result = subprocess.run([bash, GITRO, '-C', repo] + request.split(' '), cwd=repo,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            output = result.stdout.decode('utf-8', 'replace').replace('\r\n', '\n')
            for form in {repo, repo.replace('\\', '/')}:
                output = output.replace(form, REPO)
            return {'exit': result.returncode, 'response': '# gitro exit=%d: %s\n%s' % (result.returncode, request, output)}

        answers = {request: gitro(request) for request in dict.fromkeys(CALLER + SUGGESTED)}
        version = subprocess.run(['git', '--version'], stdout=subprocess.PIPE).stdout.decode().strip()
    finally:
        shutil.rmtree(root, ignore_errors=True)

    data = {
        'recorded': '%s with %s' % (datetime.date.today().isoformat(), version),
        'repo': REPO,
        'dir': DIR,
        'serving': "gitro: serving 'recipes' (%s) from %s, keeping responses in %s/kept (Ctrl+C stops)" % (REPO, DIR, DIR),
        'caller': CALLER,
        'answers': answers,
    }
    with open(OUTPUT, 'w', encoding='utf-8', newline='\n') as script:
        script.write('/* Generated by make-gitro-demo.py: real gitro answers, recorded from an example repository, for the\n'
                     '   Run page\'s demo and the callers page. Run that script again rather than editing this file. */\n')
        script.write('window.JIGS_GITRO_DEMO = %s;\n' % json.dumps(data, indent=1, ensure_ascii=False))
    print('wrote %s (%d answers, recorded %s)' % (OUTPUT, len(answers), data['recorded']))


if __name__ == '__main__':
    main()
