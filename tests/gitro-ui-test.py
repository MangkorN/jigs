#!/usr/bin/env python3
"""End-to-end test of a gitro ui companion (powershell/gitro-ui.ps1 or python/gitro-ui.py) through its HTTP API.

Creates a throwaway git repository and request folders, then checks the companion's security checks,
servers, requests (its own and an outside caller's), kept responses, events, and how it treats a folder
that a gitro serve outside it already answers in. Cleans up after itself.

    python3 tests/gitro-ui-test.py                         test the companion that gitro ui started,
                                                           found through .gitro-ui/session.js
    python3 tests/gitro-ui-test.py --token <t> [--port <p>]  test a companion on that port
    python3 tests/gitro-ui-test.py --launch                start python/gitro-ui.py with 'start', test it,
                                                           stop it with 'stop', then check that its servers
                                                           die with it even when it's killed (macOS, Linux)

Exits with the number of failed checks. The folder dialog needs a person, so it isn't tested here.
"""

import argparse
import http.client
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import quote

JIGS_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GITRO_SCRIPT = os.path.join(JIGS_ROOT, 'bash', 'functions', 'gitro.sh')
COMPANION = os.path.join(JIGS_ROOT, 'python', 'gitro-ui.py')
SESSION_FILE = os.path.join(JIGS_ROOT, '.gitro-ui', 'session.js')


class Companion:
    """HTTP client for one companion, which also collects its events."""

    def __init__(self, port, token):
        self.port = port
        self.token = token
        self.events = []
        self.last = 0

    def call(self, method, path, body=None, token=True, host=None, origin=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=40)
        connection.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        connection.putheader('Host', host or '127.0.0.1:%d' % self.port)
        if token:
            connection.putheader('X-Gitro-Token', self.token)
        if origin:
            connection.putheader('Origin', origin)
        data = json.dumps(body).encode('utf-8') if body is not None else b''
        if method == 'POST':
            connection.putheader('Content-Type', 'application/json')
            connection.putheader('Content-Length', str(len(data)))
        connection.endheaders(data if method == 'POST' else None)
        response = connection.getresponse()
        raw = response.read()
        connection.close()
        headers = {key.lower(): value for key, value in response.getheaders()}
        text = raw.decode('utf-8', 'replace')
        value = None
        if headers.get('content-type', '').startswith('application/json'):
            value = json.loads(text)
        return response.status, value, text, headers

    def wait_for(self, predicate, timeout=10):
        """Collects events until one matches, and returns it, or None after the timeout."""
        deadline = time.time() + timeout
        while True:
            for event in self.events:
                if predicate(event):
                    return event
            if time.time() > deadline:
                return None
            status, value, _, _ = self.call('GET', '/api/events?after=%d' % self.last)
            if status == 200:
                self.events.extend(value['events'])
                self.last = value['last']


class Checks:
    def __init__(self):
        self.failed = 0
        self.passed = 0

    def check(self, name, ok, detail=''):
        if ok:
            self.passed += 1
            print('  ok    ' + name)
        else:
            self.failed += 1
            print('  FAIL  %s%s' % (name, ': ' + str(detail) if detail else ''))
        return ok


def git(repo, *args):
    subprocess.run(['git', '-C', repo] + list(args), check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_repo(root):
    repo = os.path.join(root, 'repo')
    os.makedirs(repo)
    subprocess.run(['git', 'init', '-q', repo], check=True)
    git(repo, 'config', 'user.email', 'test@example.com')
    git(repo, 'config', 'user.name', 'gitro-ui test')
    git(repo, 'config', 'core.autocrlf', 'false')
    with open(os.path.join(repo, 'a.txt'), 'w', newline='\n') as f:
        f.write('hello\n')
    git(repo, 'add', 'a.txt')
    git(repo, 'commit', '-q', '-m', 'First commit')
    with open(os.path.join(repo, 'a.txt'), 'a', newline='\n') as f:
        f.write('changed\n')
    return repo


def write_request(folder, name, args):
    """Drops a request the way an outside caller would: write under another name, then rename."""
    temporary = os.path.join(folder, name + '.tmp')
    with open(temporary, 'w', newline='\n') as f:
        f.write('\n'.join(args) + '\n')
    os.replace(temporary, os.path.join(folder, name + '.req'))


def wait_file(path, timeout=10, present=True):
    """Waits for a file to appear, or with present=False to go away."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path) == present:
            return True
        time.sleep(0.1)
    return os.path.exists(path) == present


def read_session():
    """The session in .gitro-ui/session.js: a dict, None once it has ended, or False if there's no file."""
    try:
        with open(SESSION_FILE, encoding='utf-8') as f:
            match = re.match(r'^\s*window\.JIGS_GITRO_UI = (.*);\s*$', f.read(), re.S)
    except OSError:
        return False
    return json.loads(match.group(1)) if match else False


def read_presence(folder):
    try:
        with open(os.path.join(folder, 'gitro-server.json'), encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def outside_server(bash, repo, folder):
    """Starts gitro serve the way a terminal would, outside the companion, and waits until it has claimed the folder."""
    env = dict(os.environ)
    env.pop('BASH_ENV', None)
    env['PATH'] = os.path.dirname(bash) + os.pathsep + env.get('PATH', '')
    process = subprocess.Popen([bash, GITRO_SCRIPT, 'serve', repo, folder], stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    wait_file(os.path.join(folder, 'gitro-server.json'))
    return process


def run_checks(c, root):
    t = Checks()
    repo = make_repo(root)
    folder = os.path.join(root, 'exchange')
    plain = os.path.join(root, 'not-a-repo')
    os.makedirs(plain)

    print('security')
    status, _, _, _ = c.call('GET', '/api/status', token=False)
    t.check('no token is refused (401)', status == 401, status)
    status, _, _, _ = c.call('GET', '/api/status', host='evil.test:%d' % c.port)
    t.check('a foreign Host header is refused (403)', status == 403, status)
    status, _, _, headers = c.call('GET', '/api/status', origin='https://evil.test')
    t.check('a foreign origin is refused (403)', status == 403 and 'access-control-allow-origin' not in headers, status)
    status, _, _, headers = c.call('GET', '/api/status', origin='http://127.0.0.1:%d' % c.port)
    t.check('its own address as an origin is refused, since it serves no pages (403)', status == 403, status)
    status, _, _, headers = c.call('OPTIONS', '/api/servers', token=False, origin='null')
    t.check("a preflight from a page opened from a file (origin 'null') is allowed (204)",
            status == 204 and headers.get('access-control-allow-origin') == 'null', (status, headers))
    status, _, _, headers = c.call('GET', '/api/status', origin='null')
    t.check("a call from a page opened from a file is answered, for 'null'",
            status == 200 and headers.get('access-control-allow-origin') == 'null', (status, headers))
    for path in ('/', '/run/', '/..%2f..%2fREADME.md'):
        status, _, _, _ = c.call('GET', path, token=False)
        t.check('no files are served: %s (404)' % path, status == 404, status)

    print('status')
    status, info, _, _ = c.call('GET', '/api/status')
    t.check('status answers', status == 200, status)
    if status != 200:
        return t
    t.check('api version 1', info.get('api') == 1, info.get('api'))
    t.check('platform is named', info.get('platform') in ('windows', 'macos', 'linux'), info.get('platform'))
    t.check('picker is a boolean', isinstance(info.get('picker'), bool), info.get('picker'))
    t.check('pid and start time are given', isinstance(info.get('pid'), int) and isinstance(info.get('started'), int),
            (info.get('pid'), info.get('started')))
    c.last = info['seq']

    print('folders')
    os.makedirs(os.path.join(root, '.dotted'))
    with open(os.path.join(root, 'file.txt'), 'w') as f:
        f.write('not a folder\n')
    status, value, _, _ = c.call('GET', '/api/folders?path=' + quote(root))
    folders = value.get('folders', []) if status == 200 and isinstance(value, dict) else []
    names = [folder['name'] for folder in folders]
    t.check('a folder lists its subfolders, sorted without regard to case',
            status == 200 and {'repo', 'not-a-repo'} <= set(names) and names == sorted(names, key=str.lower), (status, value))
    t.check('repositories are marked', any(f['name'] == 'repo' and f['repo'] for f in folders)
            and any(f['name'] == 'not-a-repo' and not f['repo'] for f in folders), folders)
    t.check('folders starting with a dot are listed, files are not', '.dotted' in names and 'file.txt' not in names, names)
    status, again, _, _ = c.call('GET', '/api/folders?path=' + quote(root + os.sep))
    t.check('a trailing separator lists the same folder', status == 200 and again.get('path') == value.get('path'), (status, again))
    status, value, _, _ = c.call('GET', '/api/folders?path=relative')
    t.check('a relative path is refused (400)', status == 400, (status, value))
    status, value, _, _ = c.call('GET', '/api/folders?path=' + quote(os.path.join(root, 'missing')))
    t.check('a missing folder is 404', status == 404, (status, value))

    print('servers')
    status, value, _, _ = c.call('POST', '/api/servers', {'repo': 'relative/path', 'dir': folder})
    t.check('a relative path is refused (400)', status == 400, (status, value))
    status, value, _, _ = c.call('POST', '/api/servers', {'repo': os.path.join(root, 'missing'), 'dir': folder})
    t.check('a missing repository is refused (400)', status == 400, (status, value))
    status, server, _, _ = c.call('POST', '/api/servers', {'repo': repo, 'dir': folder})
    if not t.check('a server starts', status == 200 and server.get('state') == 'running', (status, server)):
        return t
    sid = server['id']
    serving = c.wait_for(lambda e: e.get('server') == sid and e['kind'] == 'log' and 'serving' in e['text'])
    t.check('gitro reports serving, keeping responses', serving is not None and 'keeping responses' in serving['text'],
            serving)
    presence = read_presence(folder)
    t.check('the server claims its folder in gitro-server.json', presence is not None and presence.get('name') == 'repo'
            and isinstance(presence.get('seen'), int), presence)
    status, value, _, _ = c.call('POST', '/api/servers', {'repo': repo, 'dir': folder})
    t.check('a second server on the same folder is refused (409)', status == 409, (status, value))

    print('a gitro serve outside the companion')
    claimed = os.path.join(root, 'exchange-claimed')
    outside = outside_server(info['bash'], repo, claimed)
    try:
        status, value, _, _ = c.call('POST', '/api/servers', {'repo': repo, 'dir': claimed})
        t.check("its folder is refused, naming it (409)", status == 409 and 'already served by' in (value or {}).get('error', '')
                and 'repo' in value['error'], (status, value))
        _, now, _, _ = c.call('GET', '/api/status')
        t.check('and no server is added for it', all(s['dir'] != claimed for s in now['servers']), now['servers'])
    finally:
        outside.terminate()
        outside.wait()
    if os.name == 'posix':
        t.check('it removes its gitro-server.json when stopped', wait_file(os.path.join(claimed, 'gitro-server.json'),
                                                                         timeout=3, present=False))
        status, value, _, _ = c.call('POST', '/api/servers', {'repo': repo, 'dir': claimed})
        t.check('then the folder is free', status == 200, (status, value))
        if status == 200:
            c.call('POST', '/api/servers/%d/remove' % value['id'], {})

    print('requests from the page')
    status, value, _, _ = c.call('POST', '/api/request', {'server': sid, 'args': ['status', '--short', '--branch']})
    if t.check('a request is accepted', status == 200 and value.get('name'), (status, value)):
        name = value['name']
        event = c.wait_for(lambda e: e['kind'] == 'request' and e['name'] == name)
        t.check('its request event arrives, marked as its own', event is not None and event['own'] and event['exit'] == 0,
                event)
        status, _, text, _ = c.call('GET', '/api/response?server=%d&name=%s' % (sid, name))
        t.check('its kept response reads back', status == 200 and text.startswith('# gitro exit=0: status --short --branch')
                and 'a.txt' in text, (status, text[:200]))
        t.check('the companion removed its .out as the caller', not os.path.exists(os.path.join(folder, name + '.out')))
    status, value, _, _ = c.call('POST', '/api/request', {'server': sid, 'args': ['diff', '--output=x']})
    if status == 200:
        event = c.wait_for(lambda e: e['kind'] == 'request' and e['name'] == value['name'])
        t.check('a disallowed flag is refused by gitro (exit 2)', event is not None and event['exit'] == 2, event)
    status, value, _, _ = c.call('POST', '/api/request', {'server': sid, 'args': ['log', 'two\nlines']})
    t.check('an argument with a newline is refused (400)', status == 400, (status, value))
    status, value, _, _ = c.call('GET', '/api/response?server=%d&name=..%%2fx' % sid)
    t.check('a response name with a slash is refused (400)', status == 400, (status, value))

    print('an outside caller')
    write_request(folder, 'outside-1', ['log', '--oneline', '-1'])
    out = os.path.join(folder, 'outside-1.out')
    if t.check('gitro answers it', wait_file(out), out):
        with open(out) as f:
            answer = f.read()
        os.remove(out)
        t.check('the answer is the log', answer.startswith('# gitro exit=0: log --oneline -1') and 'First commit' in answer,
                answer[:200])
        event = c.wait_for(lambda e: e['kind'] == 'request' and e['name'] == 'outside-1')
        t.check('the page sees it, not marked as its own', event is not None and not event['own'], event)
        status, _, text, _ = c.call('GET', '/api/response?server=%d&name=outside-1' % sid)
        t.check('its kept copy outlives the removed .out', status == 200 and 'First commit' in text, status)

    print('waiting for events')
    timer = threading.Timer(1.0, lambda: c.call('POST', '/api/servers/%d/restart' % sid, {}))
    timer.start()
    started = time.time()
    status, value, _, _ = c.call('GET', '/api/events?after=%d' % c.last)
    took = time.time() - started
    timer.join()
    t.check('an events call waits, then returns once something happens', status == 200 and value['events'] and 0.5 < took < 10,
            (status, round(took, 2)))
    if status == 200:
        c.events.extend(value['events'])
        c.last = value['last']

    print('stop, restart, remove')
    running = c.wait_for(lambda e: e.get('server') == sid and e['kind'] == 'state' and e['state'] == 'running'
                         and e['seq'] > (serving['seq'] if serving else 0))
    t.check('restart stops, then runs again', running is not None and any(
        e.get('server') == sid and e['kind'] == 'state' and e['state'] == 'stopped' for e in c.events), running)
    status, value, _, _ = c.call('POST', '/api/servers/%d/stop' % sid, {})
    t.check('stop answers with the stopped server', status == 200 and value.get('state') == 'stopped', (status, value))
    t.check("a stopped server's gitro-server.json is gone", wait_file(os.path.join(folder, 'gitro-server.json'),
                                                                      timeout=3, present=False))
    status, value, _, _ = c.call('POST', '/api/request', {'server': sid, 'args': ['status']})
    t.check('a request to a stopped server is refused (409)', status == 409, (status, value))
    status, bad, _, _ = c.call('POST', '/api/servers', {'repo': plain, 'dir': os.path.join(root, 'exchange-2')})
    if status == 200:
        bid = bad['id']
        exited = c.wait_for(lambda e: e.get('server') == bid and e['kind'] == 'state' and e['state'] == 'exited')
        t.check('a server on a non-repository exits with code 2', exited is not None and exited['exitCode'] == 2, exited)
        said = c.wait_for(lambda e: e.get('server') == bid and e['kind'] == 'log' and 'not inside a git working tree' in e['text'],
                          timeout=2)
        t.check("gitro's reason is passed on", said is not None)
        c.call('POST', '/api/servers/%d/remove' % bid, {})
    else:
        t.check('a server on a non-repository is accepted, to fail visibly', False, (status, bad))
    status, value, _, _ = c.call('POST', '/api/servers/%d/remove' % sid, {})
    t.check('remove answers', status == 200, (status, value))
    _, info, _, _ = c.call('GET', '/api/status')
    t.check('removed servers are gone from the status', all(s['id'] != sid for s in info['servers']), info['servers'])
    status, value, _, _ = c.call('POST', '/api/servers/%d/stop' % sid, {})
    t.check('an unknown server is 404', status == 404, (status, value))
    status, value, _, _ = c.call('GET', '/api/nothing')
    t.check('an unknown call is 404', status == 404, (status, value))
    return t


def remove_tree(path):
    # git marks its object files read-only, which stops a plain rmtree on Windows.
    def make_writable(function, target, _):
        os.chmod(target, 0o700)
        function(target)
    shutil.rmtree(path, onerror=make_writable)


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def companion(*args):
    """Runs python/gitro-ui.py with these arguments and returns its exit code and output."""
    result = subprocess.run([sys.executable, COMPANION] + list(args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            universal_newlines=True, timeout=60)
    return result.returncode, result.stdout


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_dead(pid, timeout=10):
    deadline = time.time() + timeout
    while alive(pid) and time.time() < deadline:
        time.sleep(0.1)
    return not alive(pid)


def check_lifecycle_start(t, port):
    """'start' twice: the first starts a companion in the background, the second finds it. Returns its session."""
    print('start')
    started = time.time()
    code, output = companion('start', '--open', 'none', '--port', str(port), '--site-url', '')
    t.check("'start' returns once the companion answers", code == 0 and 'running in the background' in output
            and time.time() - started < 20, output)
    session = read_session()
    if not t.check('it wrote its session file', isinstance(session, dict) and session.get('port') == port
                   and session.get('token') and session.get('api') == 1, session):
        return None
    t.check('the companion runs in a session of its own', os.getsid(session['pid']) == session['pid'],
            (session['pid'], os.getsid(session['pid'])))
    code, output = companion('start', '--open', 'none', '--port', str(port + 1))
    t.check("a second 'start' finds it instead of starting another", code == 0 and 'already running' in output
            and read_session().get('pid') == session['pid'], output)
    code, output = companion('status')
    t.check("'status' says it runs", code == 0 and 'is running on 127.0.0.1:%d' % port in output, output)
    return session


def check_lifecycle_stop(t, session, root):
    """'stop' ends the companion and its servers, and marks the session ended."""
    print('stop')
    c = Companion(session['port'], session['token'])
    folder = os.path.join(root, 'exchange-stop')
    status, server, _, _ = c.call('POST', '/api/servers', {'repo': os.path.join(root, 'repo'), 'dir': folder})
    t.check('a server starts before stopping', status == 200, (status, server))
    wait_file(os.path.join(folder, 'gitro-server.json'))
    code, output = companion('status')
    t.check("'status' lists the server", code == 0 and folder in output, output)
    code, output = companion('stop')
    t.check("'stop' stops it", code == 0 and 'stopped, with every server' in output, output)
    t.check('the companion process is gone', wait_dead(session['pid']))
    t.check('its session file now says it has ended', read_session() is None, read_session())
    t.check("its server's gitro-server.json is gone", not os.path.exists(os.path.join(folder, 'gitro-server.json')))
    write_request(folder, 'after-stop', ['status'])
    t.check('its server no longer answers', not wait_file(os.path.join(folder, 'after-stop.out'), timeout=2))
    code, output = companion('status')
    t.check("'status' says it isn't running, with exit code 1", code == 1 and "isn't running" in output, (code, output))
    code, output = companion('stop')
    t.check("'stop' again says it isn't running", code == 0 and "isn't running" in output, output)


def check_dies_with_companion(t, port, root):
    """Kills a companion outright, then checks its server stopped answering by itself,
    and that 'stop' clears the session it left behind."""
    print('killed')
    process = subprocess.Popen([sys.executable, COMPANION, 'start', '--foreground', '--open', 'none', '--port', str(port),
                                '--site-url', ''], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 10
    session = None
    while time.time() < deadline and not (isinstance(session, dict) and session.get('pid') == process.pid):
        time.sleep(0.1)
        session = read_session()
    if not t.check('a companion runs in the foreground', isinstance(session, dict) and session.get('pid') == process.pid,
                   session):
        process.kill()
        return
    c = Companion(session['port'], session['token'])
    folder = os.path.join(root, 'exchange-killed')
    status, server, _, _ = c.call('POST', '/api/servers', {'repo': os.path.join(root, 'repo'), 'dir': folder})
    if not t.check('a server starts for the lifetime check', status == 200, (status, server)):
        process.kill()
        return
    c.wait_for(lambda e: e['kind'] == 'log' and 'serving' in e['text'] and e.get('server') == server['id'])
    process.send_signal(signal.SIGKILL)
    process.wait()
    time.sleep(1.5)
    write_request(folder, 'after-death', ['status'])
    answered = wait_file(os.path.join(folder, 'after-death.out'), timeout=3)
    t.check('its server stops by itself when the companion is killed', not answered)
    t.check('and removes its gitro-server.json', not os.path.exists(os.path.join(folder, 'gitro-server.json')))
    code, output = companion('status')
    t.check("'status' sees the session left behind isn't running", code == 1, (code, output))
    code, output = companion('stop')
    t.check("'stop' clears it", code == 0 and 'without saying so' in output and read_session() is None, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--port', type=int, default=47210)
    parser.add_argument('--token')
    parser.add_argument('--launch', action='store_true',
                        help="start python/gitro-ui.py with 'start' on a free port, test it, and stop it")
    args = parser.parse_args()

    if args.launch:
        if os.name != 'posix':
            parser.error("--launch tests python/gitro-ui.py, for macOS and Linux. On Windows, run 'gitro ui', then this "
                         "test without options.")
        code, output = companion('status')
        if code == 0:
            parser.error('gitro ui is already running here. Stop it with gitro ui stop, or test it without --launch.')
    elif not args.token:
        session = read_session()
        if not isinstance(session, dict):
            parser.error("there's no running gitro ui in %s. Start it with gitro ui, or pass --token or --launch."
                         % SESSION_FILE)
        args.port, args.token = session['port'], session['token']

    root = tempfile.mkdtemp(prefix='gitro-ui-test-')
    t = Checks()
    try:
        if args.launch:
            make_repo(root)
            port = free_port()
            session = check_lifecycle_start(t, port)
            if session:
                checks = run_checks(Companion(port, session['token']), os.path.join(root, 'api'))
                t.passed += checks.passed
                t.failed += checks.failed
                check_lifecycle_stop(t, session, root)
            check_dies_with_companion(t, free_port(), root)
        else:
            t = run_checks(Companion(args.port, args.token), root)
    finally:
        if args.launch:
            companion('stop')
        try:
            remove_tree(root)
        except OSError as error:
            print('could not remove %s: %s' % (root, error))
    print('%d passed, %d failed' % (t.passed, t.failed))
    sys.exit(t.failed)


if __name__ == '__main__':
    main()
