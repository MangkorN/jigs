#!/usr/bin/env python3
"""Browser UI for gitro serve on macOS and Linux: start, watch and stop gitro servers from a web page.

Runs a small HTTP API on 127.0.0.1 for the Run page of the jigs site. The page is a file in this clone,
site/run/index.html, or the hosted copy of the site. Neither depends on this script: without it, the page
shows that gitro ui isn't running, and it connects by itself once it runs.
Windows has the same companion, with the same API, in powershell/gitro-ui.ps1.

'start', the default, starts this script again in the background, in a session of its own, and returns once
it answers, so the terminal can be closed. If one is already running, it's used instead. Either way the page
is opened. With --foreground this script is the companion itself, in this terminal, and Ctrl+C stops it.

The running companion writes its port and token to .gitro-ui/session.js in this clone, which the local page
reads, and marks the file ended when it stops. The hosted page gets them in the link instead.
Every API call must carry the token, and must come from a page opened from a file or from the hosted site.

Each gitro server runs as 'gitro serve -k <repo> <dir>' in its own process group, which ends
with the server, so stopping it also ends any git process it started. A server also stops by itself
when its standard input closes, so it never outlives the companion, even if the companion is killed.

Usually started with 'gitro ui', which translates its options to these. Needs Python 3.8 or newer.
"""

import argparse
import json
import os
import re
import secrets
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Raised when the HTTP API changes, so a page can tell it's talking to an older or newer companion.
API_VERSION = 1
EVENT_LIMIT = 2000
LONG_POLL_SECONDS = 25
MAX_BODY_BYTES = 262144
FOLDER_LIMIT = 500

SCRIPT = os.path.abspath(__file__)
JIGS_ROOT = os.path.dirname(os.path.dirname(SCRIPT))
GITRO_SCRIPT = os.path.join(JIGS_ROOT, 'bash', 'functions', 'gitro.sh')
RUN_PAGE = os.path.join(JIGS_ROOT, 'site', 'run', 'index.html')
STATE_DIR = os.path.join(JIGS_ROOT, '.gitro-ui')
SESSION_FILE = os.path.join(STATE_DIR, 'session.js')
DEFAULT_LOG = os.path.join(STATE_DIR, 'companion.log')
PLATFORM = 'macos' if sys.platform == 'darwin' else 'linux'
SESSION_LINE = re.compile(r'^\s*window\.JIGS_GITRO_UI = (.*);\s*$', re.S)

# gitro serve logs each request as '<time>  <name>: <request> (exit <code>)'.
LOG_LINE = re.compile(r'^(\d\d:\d\d:\d\d)  (.+?): (.*) \(exit (\d+)\)$')
RESPONSE_NAME = re.compile(r'^[^/\\:*?"<>|]+$')

# Runs gitro serve until standard input closes, then ends the whole process group.
# $1 is gitro.sh, $2 the repository and $3 the request folder.
SERVE_WRAPPER = r'''
source "$1" || exit 1
gitro serve -k "$2" "$3" &
server=$!
{ read -r _; kill -TERM -- -$$; } <&0 >/dev/null 2>&1 &
watcher=$!
wait "$server"
status=$?
kill "$watcher" 2>/dev/null
exit "$status"
'''

# Folder dialog for macOS. Arguments: the prompt, then optionally the folder to start in.
CHOOSE_FOLDER = [
    'on run argv',
    'if (count of argv) > 1 then',
    'return POSIX path of (choose folder with prompt (item 1 of argv) default location (POSIX file (item 2 of argv)))',
    'end if',
    'return POSIX path of (choose folder with prompt (item 1 of argv))',
    'end run',
]


class ApiError(Exception):
    """A failed API call, answered with this HTTP status and the message as {error}."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def now_ms():
    return int(time.time() * 1000)


# A companion in the background writes to its log, which gets the time on each line.
LOGGING = False


def say(text):
    if LOGGING:
        text = time.strftime('%H:%M:%S  ') + text
    print(text, flush=True)


def resolve_folder(value, label):
    """Absolute path of a folder named in a request, without a trailing slash."""
    value = os.path.expanduser(str(value or '').strip())
    if not value.startswith('/'):
        raise ApiError(400, '%s must be a full path, such as ~/Repos/MyProject or /home/me/Repos/MyProject.' % label)
    value = os.path.abspath(value)
    return value.rstrip('/') or '/'


def list_folders(path):
    """The subfolders of a folder, for the page's path suggestions: names sorted without regard to case,
    each marked if it's a git repository, and at most FOLDER_LIMIT of them."""
    folder = resolve_folder(path, 'The folder')
    if not os.path.isdir(folder):
        raise ApiError(404, "There's no folder %s." % folder)

    def is_folder(entry):
        try:
            return entry.is_dir()
        except OSError:
            return False

    try:
        with os.scandir(folder) as entries:
            names = [entry.name for entry in entries if is_folder(entry)]
    except OSError as error:
        raise ApiError(409, "%s can't be read (%s)." % (folder, error.strerror or error))
    names.sort(key=str.lower)
    return {'path': folder, 'truncated': len(names) > FOLDER_LIMIT,
            'folders': [{'name': name, 'repo': os.path.exists(os.path.join(folder, name, '.git'))}
                        for name in names[:FOLDER_LIMIT]]}


def find_picker():
    """The folder dialog tool available here, or None."""
    if PLATFORM == 'macos':
        return 'osascript' if shutil.which('osascript') else None
    for tool in ('zenity', 'kdialog'):
        if shutil.which(tool):
            return tool
    return None


def pick_folder(title, start):
    """Shows a folder dialog and waits for it to close. Returns {path} or {cancelled}."""
    tool = find_picker()
    if not tool:
        raise ApiError(409, 'There is no folder dialog here. Install zenity or kdialog, or type the path.')
    start = start if start and os.path.isdir(start) else ''
    if tool == 'osascript':
        command = ['osascript']
        for line in CHOOSE_FOLDER:
            command += ['-e', line]
        command += [title] + ([start] if start else [])
    elif tool == 'zenity':
        command = ['zenity', '--file-selection', '--directory', '--title=' + title]
        if start:
            command.append('--filename=' + start.rstrip('/') + '/')
    else:
        command = ['kdialog', '--getexistingdirectory', start or os.path.expanduser('~'), '--title', title]

    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    path = result.stdout.strip()
    if result.returncode == 0 and path:
        return {'path': path.rstrip('/') or '/'}
    # osascript exits with 1 for errors too, and marks a cancel with -128. zenity and kdialog exit with 1 on cancel.
    cancelled = '-128' in result.stderr if tool == 'osascript' else result.returncode == 1
    if cancelled or result.returncode == 0:
        return {'cancelled': True}
    raise ApiError(500, 'The folder dialog failed: %s' % (result.stderr.strip() or 'exit %d' % result.returncode))


def folder_owner(folder):
    """Who serves in folder, such as 'piquest' (/home/me/Repos/PiQuest, pid 1234), going by its gitro-server.json,
    or None if no running server does. The same test as gitro serve's: a file not refreshed for a minute,
    or written on this machine by a process that's gone, is stale."""
    try:
        with open(os.path.join(folder, 'gitro-server.json'), encoding='utf-8') as presence_file:
            info = json.load(presence_file)
    except (OSError, ValueError):
        return None
    seen, pid = info.get('seen'), info.get('pid')
    if not isinstance(seen, int) or not isinstance(pid, int) or time.time() - seen >= 60:
        return None
    if info.get('host') == socket.gethostname() and info.get('system') == os.uname().sysname:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return None
        except PermissionError:
            pass
    return "'%s' (%s, pid %d)" % (info.get('name'), info.get('repo'), pid)


def default_site_url():
    """GitHub Pages address of this clone's origin remote, such as https://owner.github.io/jigs/, or ''."""
    try:
        remote = subprocess.run(['git', '-C', JIGS_ROOT, 'remote', 'get-url', 'origin'], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, universal_newlines=True).stdout.strip()
    except OSError:
        return ''
    match = re.search(r'github\.com[:/]+([^/]+)/([^/]+?)(\.git)?/?$', remote)
    return 'https://%s.github.io/%s/' % (match.group(1).lower(), match.group(2)) if match else ''


class Server:
    """One gitro serve process and what the page knows about it."""

    def __init__(self, server_id, repo, folder):
        self.id = server_id
        self.repo = repo
        self.dir = folder
        self.state = 'stopped'
        self.exit_code = None
        self.started_at = None
        self.process = None
        self.reader = None
        self.stopping = False
        # Names of the requests this script sent, whose responses it removes as their caller.
        self.own_requests = set()

    def view(self):
        return {'id': self.id, 'repo': self.repo, 'dir': self.dir, 'state': self.state,
                'exitCode': self.exit_code, 'startedAt': self.started_at}


class Hub:
    """The servers and the numbered event list that pages follow. One condition guards both,
    and wakes pages waiting for events."""

    def __init__(self, bash):
        self.bash = bash
        self.changed = threading.Condition()
        self.events = []
        self.seq = 0
        self.servers = []
        self.next_id = 1
        self.picking = False

    # Events. Call with self.changed held.

    def _add_event(self, entry):
        self.seq += 1
        entry['seq'] = self.seq
        entry['time'] = now_ms()
        self.events.append(entry)
        del self.events[:-EVENT_LIMIT]
        self.changed.notify_all()

    def _set_state(self, server, state, exit_code=None):
        server.state = state
        server.exit_code = exit_code
        say('#%d  %s' % (server.id, state if exit_code is None else '%s (exit %d)' % (state, exit_code)))
        self._add_event({'kind': 'state', 'server': server.id, 'state': state, 'exitCode': exit_code})

    def events_after(self, after):
        """Events numbered after 'after', waiting up to LONG_POLL_SECONDS for one.
        'missed' tells a page that fell further behind than the events kept here to reload the status instead."""
        with self.changed:
            self.changed.wait_for(lambda: self.seq > after, timeout=LONG_POLL_SECONDS)
            oldest = self.events[0]['seq'] if self.events else self.seq + 1
            batch = [entry for entry in self.events if entry['seq'] > after]
            return {'events': batch, 'last': self.seq, 'missed': after + 1 < oldest}

    def status(self, config):
        with self.changed:
            return {'api': API_VERSION, 'platform': PLATFORM, 'picker': find_picker() is not None,
                    'port': config.port, 'site': config.site_url, 'jigs': JIGS_ROOT, 'bash': self.bash,
                    'pid': os.getpid(), 'started': config.started, 'background': LOGGING,
                    'seq': self.seq, 'servers': [server.view() for server in self.servers]}

    # Servers.

    def get(self, server_id):
        try:
            number = int(server_id)
        except (TypeError, ValueError):
            number = None
        with self.changed:
            for server in self.servers:
                if server.id == number:
                    return server
        raise ApiError(404, "There's no server #%s." % server_id)

    def _assert_folder_free(self, folder, allowed):
        # Two servers answering in one folder would take each other's requests.
        for other in self.servers:
            if other is not allowed and other.state == 'running' and other.dir == folder:
                raise ApiError(409, 'Server #%d already answers requests in %s.' % (other.id, folder))

    @staticmethod
    def _assert_unclaimed(folder):
        # A gitro serve started elsewhere, such as in a terminal, may already answer in the folder,
        # and a new one would refuse to start. This says so before starting.
        owner = folder_owner(folder)
        if owner:
            raise ApiError(409, '%s is already served by %s. Stop that server first, or use another folder.'
                           % (folder, owner))

    def add(self, repo, folder):
        repo = resolve_folder(repo, 'The repository')
        folder = resolve_folder(folder, 'The request folder')
        if not os.path.isdir(repo):
            raise ApiError(400, "The repository folder %s doesn't exist." % repo)
        with self.changed:
            self._assert_folder_free(folder, None)
            self._assert_unclaimed(folder)
            server = Server(self.next_id, repo, folder)
            self.next_id += 1
            self.servers.append(server)
            say('#%d  added: %s -> %s' % (server.id, repo, folder))
            self._add_event({'kind': 'added', 'server': server.id, 'view': server.view()})
        self.start(server)
        return server

    def start(self, server):
        with self.changed:
            if server.process:
                return
            self._assert_folder_free(server.dir, server)
            self._assert_unclaimed(server.dir)
            env = dict(os.environ)
            env.pop('BASH_ENV', None)
            process = subprocess.Popen(
                [self.bash, '-c', SERVE_WRAPPER, 'gitro-ui', GITRO_SCRIPT, server.repo, server.dir],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                env=env, start_new_session=True)
            server.process = process
            server.stopping = False
            server.started_at = now_ms()
            self._set_state(server, 'running')
            server.reader = threading.Thread(target=self._read, args=(server, process), daemon=True)
            server.reader.start()

    def _read(self, server, process):
        for raw in iter(process.stdout.readline, b''):
            self._receive_line(server, raw.decode('utf-8', 'replace').rstrip('\r\n'))
        code = process.wait()
        with self.changed:
            if server.process is not process:
                return
            server.process = None
            try:
                process.stdin.close()
            except OSError:
                pass
            if server.stopping:
                self._set_state(server, 'stopped')
            else:
                self._set_state(server, 'exited', code)
            server.stopping = False

    def _receive_line(self, server, line):
        say('#%d  %s' % (server.id, line))
        match = LOG_LINE.match(line)
        with self.changed:
            if not match:
                self._add_event({'kind': 'log', 'server': server.id, 'text': line})
                return
            name = match.group(2)
            own = name in server.own_requests
            server.own_requests.discard(name)
            if own:
                try:
                    os.remove(os.path.join(server.dir, name + '.out'))
                except OSError:
                    pass
            self._add_event({'kind': 'request', 'server': server.id, 'clock': match.group(1), 'name': name,
                             'request': match.group(3), 'exit': int(match.group(4)), 'own': own})

    def stop(self, server):
        """Ends the server's process group, and returns once its exit has been recorded."""
        with self.changed:
            process = server.process
            if not process:
                return
            server.stopping = True
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                process.wait(3)
                break
            except subprocess.TimeoutExpired:
                pass
        if server.reader:
            server.reader.join(3)

    def restart(self, server):
        self.stop(server)
        self.start(server)

    def remove(self, server):
        self.stop(server)
        with self.changed:
            if server in self.servers:
                self.servers.remove(server)
            say('#%d  removed' % server.id)
            self._add_event({'kind': 'removed', 'server': server.id})

    def stop_all(self):
        with self.changed:
            servers = list(self.servers)
        for server in servers:
            self.stop(server)

    # Requests sent from the page, dropped into the folder the way any caller would.

    def send_request(self, server, args):
        with self.changed:
            if server.state != 'running':
                raise ApiError(409, "Server #%d isn't running." % server.id)
        if isinstance(args, str):
            args = [args]
        lines = [str(arg) for arg in (args or []) if arg is not None]
        if not lines or not lines[0]:
            raise ApiError(400, 'The request needs a command.')
        if any('\n' in line or '\r' in line for line in lines):
            raise ApiError(400, 'Each argument must be a single line.')

        name = 'ui-%d-%d' % (now_ms(), secrets.randbelow(100000))
        temporary = os.path.join(server.dir, name + '.tmp')
        with open(temporary, 'w', encoding='utf-8', newline='\n') as request_file:
            request_file.write('\n'.join(lines) + '\n')
        with self.changed:
            server.own_requests.add(name)
        os.replace(temporary, os.path.join(server.dir, name + '.req'))
        return name

    def kept_response(self, server, name):
        name = str(name or '')
        if not RESPONSE_NAME.match(name) or not name.strip('.'):
            raise ApiError(400, "That isn't a response name.")
        path = os.path.join(server.dir, 'kept', name + '.out')
        if not os.path.isfile(path):
            raise ApiError(404, 'No kept response is named %s. Kept responses are removed after an hour.' % name)
        with open(path, encoding='utf-8', errors='replace') as response_file:
            return response_file.read()

    def pick(self, title, start):
        with self.changed:
            if self.picking:
                raise ApiError(409, 'A folder dialog is already open.')
            self.picking = True
        try:
            return pick_folder(title, start)
        finally:
            with self.changed:
                self.picking = False


class Config:
    def __init__(self, port, site_url, token):
        self.port = port
        self.site_url = site_url
        self.token = token
        self.started = now_ms()
        self.allowed_hosts = {'127.0.0.1:%d' % port, 'localhost:%d' % port}
        # A page opened from a file sends the origin 'null', which is allowed back as 'null'.
        self.allowed_origins = {'null'}
        if site_url:
            parts = urllib.parse.urlsplit(site_url)
            self.allowed_origins.add('%s://%s' % (parts.scheme, parts.netloc))


class Handler(BaseHTTPRequestHandler):
    """Checks where a request comes from, then routes it to the hub."""

    server_version = 'gitro-ui'

    def log_message(self, format, *args):
        pass

    def do_OPTIONS(self):
        self._handle('OPTIONS')

    def do_GET(self):
        self._handle('GET')

    def do_POST(self):
        self._handle('POST')

    def _handle(self, method):
        config = self.server.config
        # A Host check stops DNS rebinding, where a hostile domain resolves to 127.0.0.1 to look same-origin.
        if self.headers.get('Host', '').lower() not in config.allowed_hosts:
            return self._send_text(403, 'Unexpected Host header.')
        origin = self.headers.get('Origin')
        if origin and origin not in config.allowed_origins:
            return self._send_text(403, "Origin %s isn't allowed." % origin)

        url = urllib.parse.urlsplit(self.path)
        if method == 'OPTIONS':
            return self._send(204, None, b'', preflight=True)
        if not url.path.startswith('/api/'):
            return self._send_text(404, "gitro ui answers only its API. Open the Run page from this clone's "
                                        "site/run/index.html.")
        # Every project site on one github.io account shares an origin, so the origin check alone isn't enough.
        token = self.headers.get('X-Gitro-Token', '').encode('utf-8', 'replace')
        if not secrets.compare_digest(token, config.token.encode('ascii')):
            return self._send_json(401, {'error': 'Missing or wrong token. gitro ui was probably restarted, '
                                                  'which gives it a new one.'})

        try:
            body = self._read_json() if method == 'POST' else None
            self._route(method, url.path, urllib.parse.parse_qs(url.query), body)
        except ApiError as error:
            self._send_json(error.status, {'error': str(error)})
        except Exception as error:
            self._send_json(500, {'error': str(error) or type(error).__name__})

    def _read_json(self):
        try:
            length = int(self.headers.get('Content-Length') or 0)
        except ValueError:
            raise ApiError(400, 'Bad Content-Length.')
        if length < 0 or length > MAX_BODY_BYTES:
            raise ApiError(400, 'The request body is too large.')
        raw = self.rfile.read(length) if length else b''
        if not raw.strip():
            return None
        try:
            return json.loads(raw.decode('utf-8'))
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, "The request body isn't valid JSON.")

    # API calls, all JSON unless noted:
    #   GET  /api/status                         versions, platform, paths and servers, with the current event number
    #   GET  /api/events?after=<n>               events after n, waiting up to 25 seconds for one
    #   POST /api/pick-folder {title, start}     {path} or {cancelled}, once the folder dialog closes
    #   GET  /api/folders?path=<folder>          {path, folders: [{name, repo}], truncated}: its subfolders
    #   POST /api/servers {repo, dir}            adds and starts a server
    #   POST /api/servers/<id>/stop|restart|remove
    #   POST /api/request {server, args}         drops a request into the server's folder, returns {name}
    #   GET  /api/response?server=<id>&name=<n>  a kept response, as text
    #   POST /api/quit                           stops every server and this script
    def _route(self, method, path, query, body):
        hub = self.server.hub
        fields = body if isinstance(body, dict) else {}

        def query_value(key):
            values = query.get(key)
            return values[0] if values else ''

        if method == 'GET' and path == '/api/status':
            return self._send_json(200, hub.status(self.server.config))
        if method == 'GET' and path == '/api/events':
            after = query_value('after')
            return self._send_json(200, hub.events_after(int(after) if after.isdigit() else 0))
        if method == 'POST' and path == '/api/pick-folder':
            title = str(fields.get('title') or 'Choose a folder')
            return self._send_json(200, hub.pick(title, str(fields.get('start') or '')))
        if method == 'GET' and path == '/api/folders':
            return self._send_json(200, list_folders(query_value('path')))
        if method == 'POST' and path == '/api/servers':
            server = hub.add(fields.get('repo'), fields.get('dir'))
            return self._send_json(200, server.view())
        match = re.match(r'^/api/servers/(\d+)/(stop|restart|remove)$', path)
        if method == 'POST' and match:
            server = hub.get(match.group(1))
            getattr(hub, match.group(2))(server)
            return self._send_json(200, server.view())
        if method == 'POST' and path == '/api/request':
            server = hub.get(fields.get('server'))
            return self._send_json(200, {'name': hub.send_request(server, fields.get('args'))})
        if method == 'GET' and path == '/api/response':
            server = hub.get(query_value('server'))
            return self._send_text(200, hub.kept_response(server, query_value('name')))
        if method == 'POST' and path == '/api/quit':
            self._send_json(200, {'ok': True})
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return None
        raise ApiError(404, "There's no API call '%s %s'." % (method, path))

    # Responses.

    def _send(self, status, content_type, body, headers=None, preflight=False):
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.send_header('X-Content-Type-Options', 'nosniff')
        if content_type:
            self.send_header('Content-Type', content_type)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header('Cache-Control', 'no-store')
        # CORS headers only for an allowed origin; responses to other origins carry none, so browsers withhold them.
        origin = self.headers.get('Origin')
        if origin and origin in self.server.config.allowed_origins:
            self.send_header('Access-Control-Allow-Origin', origin)
            self.send_header('Vary', 'Origin')
            if preflight:
                self.send_header('Access-Control-Allow-Methods', 'GET, POST')
                self.send_header('Access-Control-Allow-Headers', 'Content-Type, X-Gitro-Token')
                self.send_header('Access-Control-Allow-Private-Network', 'true')
                self.send_header('Access-Control-Max-Age', '600')
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_json(self, status, value):
        self._send(status, 'application/json; charset=utf-8', json.dumps(value).encode('utf-8'))

    def _send_text(self, status, text):
        self._send(status, 'text/plain; charset=utf-8', text.encode('utf-8'))

# SESSION: .gitro-ui/session.js holds the running companion's port and token, as a script the local page loads:
#   window.JIGS_GITRO_UI = {"api": 1, "port": 47210, "token": "...", "pid": 1234, ...};
# When the companion stops, the value becomes null. The folder ignores itself, so git never sees it.

def make_state_dir():
    os.makedirs(STATE_DIR, exist_ok=True)
    ignore = os.path.join(STATE_DIR, '.gitignore')
    if not os.path.isfile(ignore):
        with open(ignore, 'w', encoding='utf-8') as ignore_file:
            ignore_file.write("# gitro ui's session and log, never committed.\n*\n")


def write_session_file(value):
    make_state_dir()
    temporary = SESSION_FILE + '.tmp'
    with open(temporary, 'w', encoding='utf-8') as session_file:
        session_file.write('window.JIGS_GITRO_UI = %s;\n' % json.dumps(value))
    os.replace(temporary, SESSION_FILE)


def read_session():
    """The session in the file, or None if there's none or it has ended. Says nothing about whether it still runs."""
    try:
        with open(SESSION_FILE, encoding='utf-8') as session_file:
            match = SESSION_LINE.match(session_file.read())
        session = json.loads(match.group(1)) if match else None
    except (OSError, ValueError):
        return None
    if not isinstance(session, dict) or not all(isinstance(session.get(key), int) for key in ('port', 'pid')):
        return None
    return session if session.get('token') else None


def clear_session(force=False):
    """Marks the session ended, if it's this process's, or whoever's with force."""
    session = read_session()
    if session and (force or session['pid'] == os.getpid()):
        try:
            write_session_file(None)
        except OSError:
            pass


def call_companion(session, method, path):
    """Calls a running companion's API, the way the page does, and returns the answer."""
    request = urllib.request.Request('http://127.0.0.1:%d%s' % (session['port'], path), method=method,
                                     headers={'X-Gitro-Token': session['token']}, data=b'' if method == 'POST' else None)
    # No proxy: some systems send even 127.0.0.1 through one.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=3) as response:
        return json.loads(response.read().decode('utf-8'))


def test_session(session):
    """The session's status if its companion answers, or None."""
    if not session:
        return None
    try:
        return call_companion(session, 'GET', '/api/status')
    except (OSError, ValueError):
        return None


def companion_alive(pid):
    """Whether pid is a running gitro-ui.py. A process that reused the id is something else."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return False
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, universal_newlines=True)
    return 'gitro-ui.py' in result.stdout and '<defunct>' not in result.stdout


def wait_gone(pid, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if not companion_alive(pid):
            return True
        time.sleep(0.1)
    return not companion_alive(pid)


# ACTIONS

def can_open_browser():
    # Without a display, webbrowser would fall back to a text browser in this terminal and wait for it.
    return PLATFORM == 'macos' or bool(os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY'))


def open_page(choice, session):
    url = None
    if choice == 'local':
        if not os.path.isfile(RUN_PAGE):
            return say("  This clone has no site/run/index.html, so no page was opened.")
        # The page reads the session file, so its address needs no token.
        url = pathlib.Path(RUN_PAGE).as_uri()
        say('  page: ' + url)
    elif choice == 'hosted':
        if not session.get('site'):
            return say('  There is no hosted site to open. Pass --site-url.')
        # The token travels in the fragment, which browsers never send to a server, and the page removes it.
        say("  page: %srun/ (opened with this session's token)" % session['site'])
        url = '%srun/#port=%d&token=%s' % (session['site'], session['port'], session['token'])
    if url and can_open_browser():
        webbrowser.open(url)
    elif url:
        say('  There is no display to open a browser on. Open the page yourself.')


def start_background(args):
    """'start': finds the running companion, or starts one in the background and waits until it answers."""
    session = read_session()
    if test_session(session):
        say('gitro ui is already running, on 127.0.0.1:%d (pid %d).' % (session['port'], session['pid']))
        open_page(args.open, session)
        return 0

    make_state_dir()
    command = [sys.executable, SCRIPT, 'start', '--foreground', '--open', 'none', '--port', str(args.port),
               '--log-file', DEFAULT_LOG]
    if args.site_url is not None:
        command += ['--site-url', args.site_url]
    if args.bash:
        command += ['--bash', args.bash]
    # A session of its own, so closing the terminal, or Ctrl+C in it, doesn't reach the companion.
    with open(DEFAULT_LOG, 'w', encoding='utf-8') as log:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                 cwd=JIGS_ROOT, start_new_session=True)

    deadline = time.time() + 20
    while time.time() < deadline:
        time.sleep(0.2)
        session = read_session()
        if session and session['pid'] == child.pid and test_session(session):
            say('gitro ui is running in the background, on 127.0.0.1:%d (pid %d).' % (session['port'], child.pid))
            say("  Stop it with 'gitro ui stop', or with Stop gitro ui on the page. Its servers stop with it.")
            say('  log:  ' + DEFAULT_LOG)
            open_page(args.open, session)
            return 0
        if child.poll() is not None:
            say('gitro ui stopped while starting:')
            try:
                with open(DEFAULT_LOG, encoding='utf-8', errors='replace') as log:
                    lines = [line.rstrip('\n') for line in log if line.strip()]
            except OSError:
                lines = []
            for line in lines[-15:]:
                say('  ' + line)
            say("Run 'gitro ui -f' to start it in this terminal and see every message.")
            return 1
    say("gitro ui didn't answer within 20 seconds. Its log is %s." % DEFAULT_LOG)
    return 1


def stop_companion():
    """'stop': asks the running companion to stop, and ends it if it doesn't."""
    session = read_session()
    if not session:
        say("gitro ui isn't running.")
        return 0
    pid = session['pid']
    if not companion_alive(pid):
        clear_session(force=True)
        say("gitro ui isn't running. Its last session ended without saying so, which is now cleared.")
        return 0
    try:
        call_companion(session, 'POST', '/api/quit')
        answered = True
    except (OSError, ValueError):
        answered = False
    if answered and wait_gone(pid, 15):
        say('gitro ui stopped, with every server it started.')
        return 0
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            break
        if wait_gone(pid, 5):
            break
    clear_session(force=True)
    say("gitro ui didn't stop when asked, so it was ended. Its servers ended with it.")
    return 0


def show_companion():
    """'status': whether the companion runs, and its servers. Returns 1 if it isn't running."""
    session = read_session()
    status = test_session(session)
    if not status:
        say("gitro ui isn't running.")
        return 1
    since = time.strftime('%Y-%m-%d %H:%M', time.localtime(session.get('started', 0) / 1000))
    say('gitro ui is running on 127.0.0.1:%d (pid %d), since %s.' % (session['port'], session['pid'], since))
    if session.get('log'):
        say('  log:  ' + session['log'])
    if not status['servers']:
        say('  No servers.')
    for server in status['servers']:
        state = server['state'] if server['state'] != 'exited' else 'exited (%s)' % server['exitCode']
        say('  #%d  %-12s %s -> %s' % (server['id'], state, server['repo'], server['dir']))
    return 0


def run_companion(args):
    """--foreground: this process is the companion."""
    global LOGGING
    LOGGING = bool(args.log_file)
    if not os.path.isfile(GITRO_SCRIPT):
        sys.exit("gitro.sh isn't at %s." % GITRO_SCRIPT)
    running = read_session()
    if running and running['pid'] != os.getpid() and test_session(running):
        sys.exit("gitro ui is already running, on 127.0.0.1:%d (pid %d). Stop it first with 'gitro ui stop'."
                 % (running['port'], running['pid']))
    bash = args.bash or shutil.which('bash')
    if not bash:
        sys.exit("There's no bash on PATH. Pass --bash.")
    site_url = default_site_url() if args.site_url is None else args.site_url
    if site_url and not site_url.endswith('/'):
        site_url += '/'

    config = Config(args.port, site_url, secrets.token_hex(24))
    try:
        httpd = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    except OSError as error:
        sys.exit("Can't listen on 127.0.0.1:%d, which another program uses. Pass another port with -p. (%s)"
                 % (args.port, error))
    httpd.config = config
    httpd.hub = Hub(bash)
    session = {'api': API_VERSION, 'port': args.port, 'token': config.token, 'pid': os.getpid(),
               'started': config.started, 'platform': PLATFORM, 'site': site_url, 'log': args.log_file or ''}
    write_session_file(session)

    stop_hint = "Stop it with 'gitro ui stop'" if LOGGING else 'Ctrl+C stops it'
    say('gitro ui is listening on http://127.0.0.1:%d, pid %d. %s, and every server it started.'
        % (args.port, os.getpid(), stop_hint))
    say('  session: ' + SESSION_FILE)
    if site_url:
        say('  hosted:  %srun/#port=%d&token=%s' % (site_url, args.port, config.token))
    say('  bash:    ' + bash)
    open_page(args.open, session)

    def stop(signum, frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    try:
        httpd.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.hub.stop_all()
        httpd.server_close()
        clear_session()
        say('gitro ui stopped.')
    return 0


def main():
    parser = argparse.ArgumentParser(description='Browser UI for gitro serve. Usually started with gitro ui.')
    parser.add_argument('action', nargs='?', choices=['start', 'stop', 'status'], default='start',
                        help='start (the default): start the companion in the background, or find the running one, '
                             'and open the page; stop: stop it and its servers; status: show it and its servers')
    parser.add_argument('-f', '--foreground', action='store_true', help='run the companion in this terminal')
    parser.add_argument('--port', type=int, default=47210, help='port to listen on, on 127.0.0.1 only (default 47210)')
    parser.add_argument('--open', choices=['local', 'hosted', 'none'], default='local',
                        help="page to open: local (this clone's site/run/index.html, the default), hosted, or none")
    parser.add_argument('--site-url', help="hosted site allowed to use the companion (default: the GitHub Pages "
                                           "address of this clone's origin remote; '' allows none)")
    parser.add_argument('--bash', help='bash to run gitro with (default: bash on PATH)')
    parser.add_argument('--log-file', help=argparse.SUPPRESS)
    args = parser.parse_args()

    if not 1024 <= args.port <= 65535:
        parser.error('--port must be between 1024 and 65535')
    if args.action == 'stop':
        return stop_companion()
    if args.action == 'status':
        return show_companion()
    if args.foreground:
        return run_companion(args)
    return start_background(args)


if __name__ == '__main__':
    sys.exit(main())
