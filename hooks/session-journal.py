#!/usr/bin/env python3
"""Session-bound journals for coding agents (Claude Code and Codex).

session-journal 2.0.0 - https://github.com/dctmfoo/session-journal (MIT)

One stdlib-only file, two faces:

  hook <Event>        hook entry point; reads the hook JSON on stdin. Events: SessionStart, UserPromptSubmit,
                      PreToolUse, PostToolUse, Stop, SessionEnd
  <command> [args]    agent / operator CLI: candidates, find, reconstruct, list, health, scan, sweep, whoami, bound,
                      bind, release, role, skip, version

A journal belongs to the session(s) that write it. Each session keeps a lease (<state>/leases/<session_id>.json) that
records the journal it is bound to, its worktree, role and liveness. The first journal write binds the lease. Every
question v1 answered with "which journal is newest?" is answered with "which journal is THIS session bound to?":

  - parallel sessions no longer pick up, or get nudged about, each other's journals;
  - a journal another live session is bound to is IN USE: writes into it are denied, and the agent is told to start
    its own journal with a '**Continues:**' line instead;
  - Stop nudges only when this turn landed work (an edit or a commit) and did not touch this session's own journal,
    and at most once per turn.

Paths resolve against the MAIN checkout of the session's project, never a linked worktree, and never the directory
an agent has `cd`-ed into. A project without a journal directory is left alone: the hooks never create it.

Environment (all optional):
  SESSION_JOURNAL_DIR        journal directory, relative to the main checkout (default: sessions)
  SESSION_JOURNAL_STATE_DIR  lease/trace directory (default: <main>/.claude/state/session-journal, self-gitignored)
  SESSION_JOURNAL_SKIP=1     never nudge this session (the secrets check still runs)
  SESSION_JOURNAL_DISABLE=1  every hook does nothing
  JOURNAL_ROLE               lead (default) or worker; a worker is never nudged and its journal writes are denied
  JOURNAL_WORKER_PROMPT      regex; a first prompt that matches makes the session a soft worker (never nudged)
  JOURNAL_LANDING_BASH       regex; extra Bash commands that count as landed work (default: git commit / git push)
  JOURNAL_SECRETS            deny (default), warn, or off
  JOURNAL_LIVE_MIN (45)  JOURNAL_LIVE_MAX_H (24)  JOURNAL_NUDGE_MIN (20)  JOURNAL_MAX_KB (40)
  JOURNAL_PAUSE_ON_END       1 (default) marks an ACTIVE journal PAUSED when its session ends; 0 leaves it
  JOURNAL_TRANSCRIPTS_DIR    where `reconstruct` looks for transcripts (default: ~/.claude/projects)
"""
from __future__ import annotations

import collections
import contextlib
import datetime as dt
import glob
import json
import math
import os
import re
import subprocess
import sys
import time

try:
    import fcntl
except ImportError:            # not POSIX: run without the lock
    fcntl = None

VERSION = '2.0.0'
SKIP_OK = '<!-- journal-secrets-ok -->'
NAME = re.compile(r'^(\d{4}-\d\d-\d\d-(?:\d{4}-)?[A-Za-z0-9._-]+\.md)$')     # HHMM is optional: older journals lack it
CLOSED = {'DONE', 'COMPLETE', 'COMPLETED', 'DELIVERED', 'CLOSED', 'SUPERSEDED', 'ABANDONED', '?'}  # anything else is open
LANDING_TOOLS = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'apply_patch'}
COMMIT_BASH = re.compile(r'\bgit\s+(?:-C\s+\S+\s+)?(?:commit|push)\b')
LEAD_OVERRIDE = re.compile(r'JOURNAL_ROLE=lead|keep (?:your own|a) (?:session )?journal', re.I)
PATCH_PATH = re.compile(r'^\*\*\* (?:Add|Update|Delete) File: (.+?)\s*$|^\*\*\* Move to: (.+?)\s*$', re.M)
STOPWORDS = set('the a an and or to of in on for with this that is are be it we you me my our at by from as do does did '
                'not no yes now then so if please can could would should will just also need want lets let make use '
                'using check look see read write update add fix run new session journal'.split())

# ---------------------------------------------------------------- secrets
# Credential shapes. A rule in VALUE_RULES matched a key NAME; its captured value must also look like a literal
# credential (looks_secret) before it counts, so `password: <redacted>`, `token: $API_TOKEN` and
# `client_secret: stored-in-ci-secrets` -- the redactions this check asks for -- never block their own fix.
SECRET_KEY = (r'[A-Za-z0-9_.-]*(?:password|passwd|passphrase|pwd|secret|secretkey|client_secret|api_?key|access_?key|'
              r'account_?key|private_?key|auth_?token|access_?token|refresh_?token|token)[A-Za-z0-9_.-]*')
PLACEHOLDER = r'(?!<|\$|\{|%|\*{3}|REDACTED|redacted|xxx|XXX|\.\.\.|…|None\b|null\b|""|\'\')'
SECRETS = [
    ('azure-storage-key', re.compile(r'AccountKey=[A-Za-z0-9+/=]{20,}|\b[A-Za-z0-9+/]{86}==')),
    ('private-key', re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----')),
    ('aws-key', re.compile(r'\bAKIA[0-9A-Z]{16}\b')),
    ('github-token', re.compile(r'\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}')),
    ('api-key', re.compile(r'\b(?:sk|rk)-[A-Za-z0-9_-]{24,}')),
    ('slack-token', re.compile(r'\bxox[baprs]-[A-Za-z0-9-]{10,}')),
    ('jwt', re.compile(r'\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}')),
    ('bearer-token', re.compile(r'\bBearer\s+' + PLACEHOLDER + r'([A-Za-z0-9._~+/-]{20,}=*)')),
    ('sas-token', re.compile(r'[?&]sig=[A-Za-z0-9%+/=]{20,}')),
    ('url-credential', re.compile(r'\b[a-z][a-z0-9+.-]*://[^\s/:@<>{}$]+:' + PLACEHOLDER + r'([^\s/@<>]{6,})@')),
    # The key NAME may embed the secret word (dbPassword:, SERVICE_API_KEY=), not only equal it.
    ('secret-assignment', re.compile(r'(?i)(?<![A-Za-z0-9])(' + SECRET_KEY + r')[`"\']?\s*(?:[:=]|=>)\s*[`"\']?' +
                                     PLACEHOLDER + r'([^\s`"\'|,;)\]}]{6,})')),
    ('password-prose', re.compile(
        r'(?i)\b(?:password|passwd|passphrase|pwd|secret)\b(?:\s+(?:for|of)\s+[\w .@-]{1,40})?\s+(?:is|was|=|:)\s+'
        r'(?:now\s+)?[`"\']?(?!<|\$|\{|\*{3}|REDACTED|xxx|in\b|stored\b|kept\b|available\b|the\b|a\b|an\b|set\b|'
        r'rotated\b|not\b|still\b|also\b|correct\b|wrong\b)([^\s`"\'|]{6,})')),
    ('password-table-cell', re.compile(r'(?i)\|\s*`?[A-Za-z0-9_.-]*(?:password|passwd|pwd|secret)[A-Za-z0-9_.-]*`?\s*\|'
                                       r'\s*`?([^|\n`]{6,}?)`?\s*\|')),
    ('cli-secret-flag', re.compile(r'--(?:password|passwd|client-secret|secret|token)(?:=|\s+)[`"\']?' + PLACEHOLDER +
                                   r'([^\s`"\']{6,})')),
]
VALUE_RULES = {'bearer-token', 'secret-assignment', 'password-prose', 'password-table-cell', 'cli-secret-flag',
               'url-credential'}
NOT_SECRET_WORDS = {'mandatory', 'required', 'optional', 'hardcoded', 'default', 'unchanged', 'invalid', 'expired',
                    'missing', 'rotated', 'redacted', 'placeholder', 'changeme', 'checking', 'enabled', 'disabled',
                    'true', 'false'}


def looks_secret(value):
    """A literal credential, not an identifier, path, URL, variable reference or English word."""
    v = re.sub(r'^[`"\'(*_]+|[`"\'.,;:)(*_]+$', '', value)
    if len(v) < 6 or v.lower() in NOT_SECRET_WORDS or v.endswith(('...', '…')) or re.search(r'\s', v):
        return False
    if re.match(r'(?i)(https?|s3|wasbs?|abfss?|jdbc|ldaps?|file)[:/]|[~.]?/', v) or \
            ('/' in v and not re.search(r'[A-Za-z0-9+/]{16,}={0,2}$', v)):
        return False                                   # URLs, paths, namespace/secret-name references
    if re.fullmatch(r'[a-z0-9]+(?:[-_.][a-z0-9]+)+', v) and len(v) < 24:
        return False                                   # lower-case identifiers: app-secret, stored-in-ci-secrets
    if re.fullmatch(r'[A-Za-z]+', v):
        return False                                   # one word or camelCase identifier
    if re.fullmatch(r'[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+', v):
        return False                                   # ENV_VAR_NAME or a cipher name used as a reference
    if re.fullmatch(r'[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*)+', v):
        return False                                   # dotted property names: spring.datasource.password
    has_digit, has_alpha = bool(re.search(r'\d', v)), bool(re.search(r'[A-Za-z]', v))
    return (has_digit and has_alpha) or bool(re.search(r'[!@#$%^&*+=?~]', v))


def scan_secrets(text):
    """[(line_number, rule)] for credential-shaped content. Values are never returned, so they are never echoed.
    A line carrying <!-- journal-secrets-ok --> is exempt (a human verified it)."""
    hits = []
    for n, line in enumerate((text or '').splitlines(), 1):
        if SKIP_OK in line:
            continue
        for name, rx in SECRETS:
            found = False
            for m in rx.finditer(line):
                if name in VALUE_RULES and not looks_secret(m.group(m.lastindex or 0)):
                    continue
                found = True
                break
            if found:
                hits.append((n, name))
                break
    return hits


def fmt_hits(hits):
    return ', '.join(f'line {n} ({rule})' for n, rule in hits[:5]) + (' ...' if len(hits) > 5 else '')


# ---------------------------------------------------------------- paths / state

def git(*args, cwd=None, timeout=5):
    try:
        r = subprocess.run(['git', *args], cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() if r.returncode == 0 else ''
    except Exception:
        return ''


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


def env_pid():
    try:
        return int(os.environ.get('CLAUDE_PID') or 0) or None
    except ValueError:
        return None


def env_float(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return float(default)


def now_local():
    return dt.datetime.now().astimezone()


def worktree_label(top, main, branch):
    """Name of a linked worktree. Pooled worktrees are often checked out as <pool>/<n>/<repo-name>, so a basename that
    equals the main checkout's says nothing; the branch says what the worktree is for."""
    name = os.path.basename(top.rstrip(os.sep))
    if name == os.path.basename(main.rstrip(os.sep)) and branch and branch != 'HEAD':
        return branch
    return name


class Ctx:
    def __init__(self, cwd=None):
        self.cwd = cwd or os.getcwd()
        # The session root. A hook's cwd follows the agent's `cd`, so it must not decide which project's journals are
        # used: Claude Code keeps $CLAUDE_PROJECT_DIR at the session's project root. Codex reports the session cwd.
        self.root = os.environ.get('CLAUDE_PROJECT_DIR') or self.cwd
        out = git('rev-parse', '--git-common-dir', '--show-toplevel', '--abbrev-ref', 'HEAD', cwd=self.root).splitlines()
        common = out[0] if out else ''
        self.common = os.path.normpath(os.path.join(self.root, common)) if common else ''
        self.top = out[1] if len(out) > 1 else self.root
        self.branch = out[2] if len(out) > 2 else '?'
        self.main = os.path.dirname(self.common) if os.path.basename(self.common) == '.git' else self.top
        self.worktree = 'main' if os.path.realpath(self.top) == os.path.realpath(self.main) else \
            worktree_label(self.top, self.main, self.branch)
        jdir = os.environ.get('SESSION_JOURNAL_DIR') or 'sessions'
        self.jdir = os.path.normpath(jdir if os.path.isabs(jdir) else os.path.join(self.main, jdir))
        self.jrel = os.path.relpath(self.jdir, self.main) if self.jdir.startswith(self.main + os.sep) else self.jdir
        self.tail = os.path.basename(self.jdir)
        sdir = os.environ.get('SESSION_JOURNAL_STATE_DIR') or os.path.join('.claude', 'state', 'session-journal')
        self.sdir = sdir if os.path.isabs(sdir) else os.path.join(self.main, sdir)
        self.enabled = os.path.isdir(self.jdir)          # never create the journal directory
        if self.enabled:
            for d in ('leases', 'pending'):
                os.makedirs(os.path.join(self.sdir, d), exist_ok=True)
            ignore = os.path.join(self.sdir, '.gitignore')
            if not os.path.exists(ignore):               # state is per machine: keep it out of every commit
                with open(ignore, 'w') as fh:
                    fh.write('*\n')
        self.live_min = env_float('JOURNAL_LIVE_MIN', 45)
        self.live_max_h = env_float('JOURNAL_LIVE_MAX_H', 24)
        self.nudge_min = env_float('JOURNAL_NUDGE_MIN', 20)
        self.max_bytes = int(env_float('JOURNAL_MAX_KB', 40) * 1024)
        self.secrets = (os.environ.get('JOURNAL_SECRETS') or 'deny').strip().lower()
        t = re.escape(self.tail) + r'/'
        d = t + r'\d{4}-\d\d-\d\d-'
        self.mention = re.compile(t + r'(\d{4}-\d\d-\d\d-(?:\d{4}-)?[A-Za-z0-9._-]+?\.md)')
        self.path_mention = re.compile(r'((?<![^\s"\'=(:])[^\s"\'|;&<>()=]*?/|(?<![^\s"\'=(:]))' + t +
                                       r'(\d{4}-\d\d-\d\d-(?:\d{4}-)?[A-Za-z0-9._-]+?\.md)')
        # Bash commands that certainly write a journal (these can be denied). Any other command that changes a
        # journal is caught afterwards by the mtime check in PostToolUse.
        self.bash_writes = [
            re.compile(r'>>?\s*["\']?[^\s"\'|;&<>]*' + d),
            re.compile(r'\btee\s+(?:-a\s+)?["\']?[^\s"\'|;&<>]*' + d),
            re.compile(r'\bsed\s+-i[^|;&]*' + d),
            re.compile(r'\b(?:cp|mv|install|rsync)\s[^|;&]*' + d + r'[^\s"\'|;&]*\.md["\']?\s*(?:$|[|;&)])', re.M),
            re.compile(r'open\(\s*[^)]*' + d + r'[^)]*,\s*[rb+]*["\'][wax]|Path\(\s*[^)]*' + d +
                       r'[^)]*\)\s*\.write_(?:text|bytes)|(?:writeFileSync|appendFileSync)\(\s*[^)]*' + d),
        ]
        extra = os.environ.get('JOURNAL_LANDING_BASH')
        try:
            self.landing_bash = re.compile(COMMIT_BASH.pattern + ('|' + extra if extra else ''))
        except re.error:
            self.landing_bash = COMMIT_BASH
        here, main_real = os.path.realpath(__file__), os.path.realpath(self.main)
        self.script = os.path.relpath(here, main_real) if here.startswith(main_real + os.sep) else here

    # locking -----------------------------------------------------------
    @contextlib.contextmanager
    def lock(self, timeout=3.0):
        """Serialise lease read-modify-write across hook processes (parallel tool calls, parallel sessions)."""
        fd, got = None, False
        try:
            fd = os.open(os.path.join(self.sdir, '.lock'), os.O_CREAT | os.O_RDWR, 0o644)
            t0 = time.time()
            while fcntl:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    got = True
                    break
                except OSError:
                    if time.time() - t0 > timeout:
                        break
                    time.sleep(0.01)
        except OSError:
            pass
        try:
            yield got
        finally:
            if fd is not None:
                if got and fcntl:
                    fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    # leases ------------------------------------------------------------
    def lease_path(self, sid):
        return os.path.join(self.sdir, 'leases', re.sub(r'[^A-Za-z0-9_-]', '', sid or 'nosid') + '.json')

    def lease(self, sid):
        try:
            with open(self.lease_path(sid)) as fh:
                return json.load(fh)
        except Exception:
            return None

    def save_lease(self, lease, touch=True):
        if touch:
            lease['heartbeat'] = time.time()
        p = self.lease_path(lease['sid'])
        tmp = f'{p}.{os.getpid()}.tmp'
        with open(tmp, 'w') as fh:
            json.dump(lease, fh, indent=1)
        os.replace(tmp, p)
        return lease

    def leases(self):
        out = []
        for p in glob.glob(os.path.join(self.sdir, 'leases', '*.json')):
            try:
                with open(p) as fh:
                    out.append(json.load(fh))
            except Exception:
                pass
        return out

    def is_live(self, lease, now=None):
        if lease.get('ended'):
            return False
        age = (now or time.time()) - (lease.get('heartbeat') or 0)
        if age < self.live_min * 60:
            return True
        # An idle chat or a long autonomous turn keeps its journal while its agent process lives (capped).
        return bool(lease.get('pid')) and age < self.live_max_h * 3600 and pid_alive(lease['pid'])

    def owners(self, journal, me=None):
        """Live sessions other than `me` bound to journal. If both are bound to it, the earlier binder owns it."""
        mine = me if me and me.get('journal') == journal else None
        out = []
        for l in self.leases():
            if l.get('journal') != journal or (me and l.get('sid') == me.get('sid')) or not self.is_live(l):
                continue
            if mine and (l.get('bound_at') or 0) > (mine.get('bound_at') or 0):
                continue
            out.append(l)
        return out

    def trace(self, **kw):
        kw['t'] = now_local().isoformat(timespec='seconds')
        p = os.path.join(self.sdir, 'events.jsonl')
        try:
            if os.path.exists(p) and os.path.getsize(p) > 2 * 1024 * 1024:
                os.replace(p, p + '.1')
            with open(p, 'a') as f:
                f.write(json.dumps(kw) + '\n')
        except OSError:
            pass

    # journals ----------------------------------------------------------
    def journals(self):
        try:
            return sorted(os.path.join(self.jdir, n) for n in os.listdir(self.jdir) if NAME.match(n))
        except OSError:
            return []

    def jpath(self, name):
        return os.path.join(self.jdir, name)

    def show(self, name):
        return f'{self.jrel}/{name}'

    def journal_name(self, path):
        """The journal name when path is <something>/<journal dir name>/<journal>.md, else None."""
        if not path:
            return None
        path = str(path).replace('\\', '/')
        head, base = os.path.split(path)
        if NAME.match(base) and os.path.basename(head) == self.tail:
            return base
        return None

    def bash_journal_writes(self, cmd, cwd=None):
        """Journal names a shell command certainly writes. With `cwd`, a name whose path visibly points at another
        directory (an absolute or relative path that is not this journal directory), or that sits behind a variable
        and does not exist here, is someone else's: test fixtures and other repositories often mention a
        `sessions/` path inside a heredoc."""
        if not cmd or self.tail + '/' not in cmd:
            return []
        if not any(r.search(cmd) for r in self.bash_writes):
            return []
        names = set()
        for m in self.path_mention.finditer(cmd):
            prefix, name = m.group(1), m.group(2)
            if cwd is None:                            # after the fact: a written journal exists
                if not os.path.exists(self.jpath(name)):
                    continue
            else:
                if prefix.startswith(('$', '~')) or '$(' in prefix or '`' in prefix:
                    if not os.path.exists(self.jpath(name)):
                        continue
                elif os.path.realpath(os.path.join(cwd, prefix, self.tail)) != os.path.realpath(self.jdir):
                    continue
            names.add(name)
        return sorted(names)


def header(text, key):
    m = re.search(r'^\*\*' + re.escape(key) + r':\*\*\s*(.+)$', text, re.M)
    return m.group(1).strip() if m else ''


def section(text, name):
    m = re.search(r'^##\s+' + re.escape(name) + r'[^\n]*\n(.*?)(?=^## |\Z)', text, re.M | re.S | re.I)
    return m.group(1).strip() if m else ''


def read(path):
    try:
        with open(path, errors='replace') as fh:
            return fh.read()
    except OSError:
        return None


def card(ctx, name):
    text = read(ctx.jpath(name))
    if text is None:
        return None
    m = re.search(r'^# (?:Session: )?(.+)$', text, re.M)
    status = header(text, 'Status')
    pointer = section(text, 'Live plan pointer')
    return {
        'journal': name, 'title': (m.group(1) if m else name).strip(),
        'status': status.split()[0].upper().rstrip(':;,.') if status else '?',
        'label': re.sub(r'\s+', ' ', status or '?').strip()[:60], 'updated': header(text, 'Last updated'),
        'pointer': pointer.splitlines()[0].strip() if pointer else 'none',
        'next': re.sub(r'\s+', ' ', section(text, 'Next step for a fresh agent'))[:400],
        'sessions': header(text, 'Sessions'), 'worktree': header(text, 'Worktree'), 'bytes': len(text.encode()),
        'mtime': os.path.getmtime(ctx.jpath(name)),
    }


def is_thin(pointer):
    return (pointer or 'none').strip().lower().strip('`<>- ') not in ('none', '')


# ---------------------------------------------------------------- transcript (Claude Code JSONL)

def read_transcript(path):
    out = []
    if not path or not os.path.exists(path):
        return out
    with open(path, errors='replace') as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except Exception:
                continue
            if isinstance(d, dict):
                out.append(d)
    return out


def is_human(d):
    if d.get('type') != 'user' or d.get('isMeta') or d.get('isSidechain'):
        return False
    origin = d.get('origin') or {}
    if isinstance(origin, dict) and origin.get('kind'):
        return origin.get('kind') == 'human'
    c = (d.get('message') or {}).get('content')
    if isinstance(c, str):
        return not c.startswith('<') and 'Stop hook feedback' not in c
    if isinstance(c, list):
        return any(isinstance(x, dict) and x.get('type') == 'text' and not x.get('text', '').startswith('<') for x in c) \
            and not any(isinstance(x, dict) and x.get('type') == 'tool_result' for x in c)
    return False


def iso_epoch(ts):
    try:
        return dt.datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
    except Exception:
        return 0


def patch_paths(patch, cwd):
    out = []
    for m in PATCH_PATH.finditer(patch or ''):
        p = (m.group(1) or m.group(2) or '').strip()
        if p:
            out.append(p if os.path.isabs(p) else os.path.join(cwd or '', p))
    return out


def patch_added_text(patch):
    return '\n'.join(l[1:] for l in (patch or '').splitlines() if l.startswith('+') and not l.startswith('+++'))


def tool_targets(ctx, name, inp, cwd=None):
    """(journal names written, other files written, bash command) for one tool call."""
    if name in ('Edit', 'Write', 'MultiEdit', 'NotebookEdit'):
        p = inp.get('file_path') or inp.get('notebook_path') or ''
        jn = ctx.journal_name(p)
        return ([jn] if jn else []), ([] if jn else [p] if p else []), None
    if name == 'apply_patch':
        js, files = [], []
        for p in patch_paths(str(inp.get('command') or inp.get('patch') or inp.get('input') or ''), cwd):
            jn = ctx.journal_name(p)
            (js if jn else files).append(jn or p)
        return js, files, None
    if name == 'Bash':
        cmd = str(inp.get('command', ''))
        return ctx.bash_journal_writes(cmd, cwd), [], cmd
    return [], [], None


def turn_facts(ctx, entries, floor=0):
    """Facts about the current turn (since the last human message) and the session so far, from a Claude Code
    transcript. `floor` (epoch) ignores journal writes before it: a fork's transcript carries the parent's history.
    Other transcript formats yield empty facts; the hooks record their own facts for those."""
    start = 0
    failed = set()                 # tool calls a hook denied (or that failed) stay in the transcript but wrote nothing
    for i, d in enumerate(entries):
        if is_human(d):
            start = i
        elif d.get('type') == 'user':
            c = (d.get('message') or {}).get('content')
            for x in c if isinstance(c, list) else []:
                if isinstance(x, dict) and x.get('type') == 'tool_result' and x.get('is_error'):
                    failed.add(x.get('tool_use_id'))
    f = {'landed': False, 'committed': False, 'turn_journal_writes': set(), 'session_journal_writes': [],
         'turn_start_ts': entries[start].get('timestamp') if entries else None, 'first_prompt': None,
         'last_journal_write_ts': None, 'turn_files': [], 'turn_commits': [], 'last_text': ''}
    for i, d in enumerate(entries):
        if f['first_prompt'] is None and is_human(d):
            c = (d.get('message') or {}).get('content')
            f['first_prompt'] = c if isinstance(c, str) else ' '.join(
                x.get('text', '') for x in c or [] if isinstance(x, dict))
        if d.get('type') != 'assistant' or d.get('isSidechain'):
            continue
        for c in (d.get('message') or {}).get('content') or []:
            if isinstance(c, dict) and c.get('type') == 'text' and i >= start:
                f['last_text'] = c.get('text', '')
            if not isinstance(c, dict) or c.get('type') != 'tool_use' or c.get('id') in failed:
                continue
            written, files, cmd = tool_targets(ctx, c.get('name', ''), c.get('input') or {})
            if i >= start:
                if files:
                    f['landed'] = True
                    f['turn_files'] += files
                if cmd and ctx.landing_bash.search(cmd):
                    f['landed'] = True
                    if COMMIT_BASH.search(cmd):
                        f['committed'] = True
                        f['turn_commits'].append(re.sub(r'\s+', ' ', cmd)[:160])
            if written and floor and iso_epoch(d.get('timestamp') or '') < floor:
                continue
            for jn in written:
                if jn not in f['session_journal_writes']:
                    f['session_journal_writes'].append(jn)
                f['last_journal_write_ts'] = d.get('timestamp')
                if i >= start:
                    f['turn_journal_writes'].add(jn)
    return f


def journals_changed_since(ctx, t0):
    out = []
    try:
        for e in os.scandir(ctx.jdir):
            if NAME.match(e.name) and e.stat().st_mtime >= t0 - 1.0:
                out.append(e.name)
    except OSError:
        pass
    return sorted(out)


# ---------------------------------------------------------------- lease helpers

def new_lease(ctx, inp):
    role = (os.environ.get('JOURNAL_ROLE') or '').strip().lower()
    role = role if role in ('worker', 'lead') else ''
    return {'v': 2, 'sid': inp.get('session_id') or 'nosid', 'journal': None, 'bound_at': None,
            'role': role or 'lead', 'role_source': 'env' if role else 'default',
            'root': ctx.root, 'worktree': ctx.worktree, 'branch': ctx.branch, 'started': time.time(), 'pid': env_pid(),
            'transcript': inp.get('transcript_path'),
            'runtime': 'codex' if 'turn_id' in inp or '/.codex/' in str(inp.get('transcript_path') or '')
            else (os.environ.get('CLAUDE_CODE_ENTRYPOINT') or 'claude'),
            'ended': None, 'history': [], 'writes': []}


def get_lease(ctx, inp):
    sid = inp.get('session_id') or 'nosid'
    lease = ctx.lease(sid) or new_lease(ctx, inp)
    lease['transcript'] = inp.get('transcript_path') or lease.get('transcript')
    lease['pid'] = env_pid() or lease.get('pid')
    lease['ended'] = None
    if 'turn_id' in inp:
        lease['runtime'] = 'codex'
    return lease


def hard_worker(lease):
    return lease.get('role') == 'worker' and lease.get('role_source') in ('env', 'cli')


def skipping(lease):
    return (os.environ.get('SESSION_JOURNAL_SKIP') or '').lower() not in ('', '0', 'false', 'no') or lease.get('skip')


def bind(ctx, lease, name, why):
    if name and lease.get('journal') != name:
        if lease.get('journal'):
            lease.setdefault('history', []).append(lease['journal'])
        lease['journal'] = name
        lease['bound_at'] = time.time()
        ctx.trace(ev='bind', sid=lease['sid'], journal=name, why=why)


def turn_key(inp, lease, fallback=None):
    """One key per human prompt: Claude Code's prompt_id, Codex's turn_id, else the UserPromptSubmit counter."""
    k = inp.get('prompt_id') or inp.get('turn_id')
    if k:
        return str(k)
    if lease.get('prompt_seq'):
        return f"seq-{lease['prompt_seq']}"
    return fallback or 'unknown'


def turn_record(lease, key):
    t = lease.get('turn') or {}
    if t.get('key') != key:
        t = {'key': key, 'landed': False, 'committed': False, 'journals': [], 'files': [], 'commits': []}
        lease['turn'] = t
    return t


def tokens(s):
    return [w for w in re.findall(r'[a-z0-9]+', (s or '').lower().replace('_', ' '))
            if len(w) >= 3 and w not in STOPWORDS]


def candidates(ctx, lease, limit=5, first=None):
    """Open journals a starting session might continue, ranked: same worktree, journal dirty in git, ACTIVE, and the
    last write by an agent session (a background job bumping mtime does not count)."""
    dirty = set()
    for line in git('status', '--porcelain', '--', ctx.jdir, cwd=ctx.main).splitlines():
        dirty.add(os.path.basename(line[3:].strip().strip('"')))
    session_writes = {}
    for l in ctx.leases():
        for w in l.get('writes') or []:
            session_writes[w[0]] = max(session_writes.get(w[0], 0), w[1])
    rows = []
    for p in ctx.journals()[-300:]:
        c = card(ctx, os.path.basename(p))
        if not c or c['status'] in CLOSED:
            continue
        owners = ctx.owners(c['journal'], me=lease)
        last = session_writes.get(c['journal']) or c['mtime']
        score = -((time.time() - last) / 3600.0)
        where = c['worktree'] or c['sessions']
        if where and lease.get('worktree') and lease['worktree'] != 'main' and lease['worktree'] in where:
            score += 48
        if c['label'].upper().startswith(('ACTIVE', 'IN PROGRESS')):
            score += 6
        if c['journal'] in dirty:
            score += 72
        if first and c['journal'] == first:
            score += 10 ** 6
        rows.append((score, c, owners))
    rows.sort(key=lambda r: -r[0])
    return rows[:limit]


def fmt_card(ctx, c, owners):
    if owners:
        o = owners[0]
        tag = f"IN USE by live session {o['sid'][:8]} ({o.get('worktree', '?')}) - read only, do not append"
    else:
        tag = c['label'] + (f", {c['bytes'] // 1024} KB - continue it in a new journal with Continues:"
                            if c['bytes'] > ctx.max_bytes else '')
    return f"  - {ctx.show(c['journal'])} [{tag}] {c['title'][:70]} | next: {c['next'][:160]}"


def fmt_candidates(ctx, rows):
    return '\n'.join(fmt_card(ctx, c, owners) for _, c, owners in rows)


def related(ctx, lease, prompt, exclude, limit=2, threshold=4.0):
    """Open journals whose name or title match the first prompt (IDF-weighted) and were not listed at start-up."""
    q = set(tokens(prompt[:2000]))
    if not q:
        return []
    docs = {}
    for p in ctx.journals():
        n = os.path.basename(p)
        try:
            with open(p, errors='replace') as fh:
                head = fh.read(3000)
        except OSError:
            continue
        m = re.search(r'^# (?:Session: )?(.+)$', head, re.M)
        slug = re.sub(r'^\d{4}-\d\d-\d\d-(?:\d{4}-)?|\.md$', '', n).replace('-', ' ')
        docs[n] = set(tokens(slug + ' ' + (m.group(1) if m else '')))
    df = collections.Counter(w for s in docs.values() for w in s)
    n_docs = max(len(docs), 1)
    scored = sorted(((sum(math.log(n_docs / (1 + df[w])) for w in s & q), n) for n, s in docs.items()
                     if n not in exclude), reverse=True)
    out = []
    for sc, n in scored[:limit]:
        if sc <= threshold:
            break
        c = card(ctx, n)
        if c and c['status'] not in CLOSED:
            out.append((c, ctx.owners(n, me=lease)))
    return out


def predecessor_of(ctx, lease):
    """The session this window ran before /clear: it ended with reason 'clear' moments ago in the same process."""
    best = None
    for l in ctx.leases():
        if l.get('sid') == lease['sid'] or l.get('end_reason') != 'clear' or not l.get('ended'):
            continue
        if time.time() - l['ended'] > 600:
            continue
        same = (lease.get('pid') and l.get('pid') == lease.get('pid')) or \
               (not lease.get('pid') and l.get('root') == lease.get('root') and time.time() - l['ended'] < 30)
        if same and (best is None or l['ended'] > best['ended']):
            best = l
    return best


# ---------------------------------------------------------------- hook handlers

def on_session_start(ctx, inp):
    src = inp.get('source') or 'startup'
    msgs = []
    parent_journal = None
    if src == 'fork':
        hist = turn_facts(ctx, read_transcript(inp.get('transcript_path')))['session_journal_writes']
        parent_journal = hist[-1] if hist else None
    with ctx.lock():
        lease = get_lease(ctx, inp)
        if src == 'fork' and not lease.get('bind_floor'):
            lease['bind_floor'] = time.time()          # history before the fork belongs to the parent session
            lease['source'] = 'fork'
        pred = predecessor_of(ctx, lease) if src == 'clear' and not lease.get('journal') else None
        if src == 'clear' and not pred and not lease.get('journal'):
            time.sleep(0.3)                            # the old session's SessionEnd may still be finishing
            pred = predecessor_of(ctx, lease)
        if pred:
            lease['predecessor'] = pred['sid']
        ctx.save_lease(lease)
    readme = f'{ctx.jrel}/README.md'
    if lease['role'] == 'worker':
        msgs.append(f'Journal: this session is a WORKER (JOURNAL_ROLE=worker). Do not create or edit {ctx.jrel}/*.md; '
                    'report results to your lead, whose journal records the dispatch and the outcome.')
    elif lease.get('journal'):
        c = card(ctx, lease['journal']) or {}
        msgs.append(f"Journal: this session ({lease['sid'][:8]}) is bound to {ctx.jpath(lease['journal'])} "
                    f"(source={src}). Continue it; re-read it now if context was compacted. "
                    f"Next step recorded there: {c.get('next', '')[:300]}")
    else:
        msgs.append(
            f"Journal: no journal is bound to this session ({lease['sid'][:8]}) yet. Journals live in {ctx.jdir}"
            + (f" (the main checkout; you are in worktree '{ctx.worktree}', whose own copy of {ctx.jrel}/ is stale: "
               f"give a new journal the header line '**Worktree:** {ctx.worktree} ({ctx.branch})')"
               if ctx.worktree != 'main' else '')
            + ". After the user's first message: if the task continues one of the candidates below, read it and "
            f"append; otherwise create {ctx.jrel}/YYYY-MM-DD-HHMM-<slug>.md (local time) from {ctx.jrel}/TEMPLATE.md, "
            f"following {readme}, and add '**Continues:** {ctx.jrel}/<old>.md' when it picks up earlier work. Your "
            "first journal write binds it to this session. Never append to a journal marked IN USE. A turn that "
            "only reads or answers needs no journal.")
        first = pred.get('journal') if pred else None
        if pred and first:
            msgs.append(f"You ran /clear: the previous session in this window ({pred['sid'][:8]}) was bound to "
                        f"{ctx.show(first)}. If this task continues that work, append to it (it is free now); "
                        "otherwise start a new journal.")
        if parent_journal:
            msgs.append(f"This session is a fork. The journal in its history, {ctx.show(parent_journal)}, belongs to "
                        f"the original session: create your own journal with '**Continues:** "
                        f"{ctx.show(parent_journal)}'.")
        rows = candidates(ctx, lease, first=first)
        if rows:
            msgs.append('Candidates (ranked: same worktree, dirty in git, active, recent):\n' + fmt_candidates(ctx, rows))
            with ctx.lock():
                cur = ctx.lease(lease['sid']) or lease
                cur['shown'] = [c['journal'] for _, c, _ in rows]
                ctx.save_lease(cur)
        msgs.append(f"Older work: `python3 {ctx.script} find <words>`; open journals on a topic: "
                    f"`python3 {ctx.script} candidates <words>`; a journal's history: `... reconstruct <journal>`.")
    ctx.trace(ev='SessionStart', sid=lease['sid'], source=src, bound=lease.get('journal'), role=lease['role'],
              predecessor=(pred or {}).get('sid'))
    return {'hookSpecificOutput': {'hookEventName': 'SessionStart', 'additionalContext': '\n'.join(msgs)}}


def on_user_prompt(ctx, inp):
    prompt = inp.get('prompt', '') or ''
    texts = []
    worker_rx = os.environ.get('JOURNAL_WORKER_PROMPT')
    with ctx.lock():
        lease = get_lease(ctx, inp)
        lease['prompt_seq'] = (lease.get('prompt_seq') or 0) + 1
        first = not lease.get('prompted')
        if first:
            lease['prompted'] = True
            try:
                dispatched = bool(worker_rx) and re.search(worker_rx, prompt, re.I | re.S)
            except re.error:
                dispatched = False
            if lease['role_source'] == 'default' and dispatched and not LEAD_OVERRIDE.search(prompt):
                lease['role'], lease['role_source'] = 'worker', 'dispatch-prompt'
                texts.append('Journal: this prompt is a dispatched task, so this session counts as a WORKER and is '
                             'not nudged about journals. Write a journal only if your task asks for one; otherwise '
                             'your report to the lead is the record.')
                ctx.trace(ev='role', sid=lease['sid'], role='worker', source='dispatch-prompt')
        news = unseen_ledger(ctx, lease) if lease['role'] != 'worker' else []
        ctx.save_lease(lease)
    if first and lease['role'] != 'worker' and not lease.get('journal'):
        rel = related(ctx, lease, prompt, exclude=set(lease.get('shown') or []))
        if rel:
            texts.append('Journals that match this first prompt (in addition to the start-up candidates):\n'
                         + '\n'.join(fmt_card(ctx, c, o) for c, o in rel))
    if news:
        texts.append('Journal: worker results landed since you last looked (record the outcome in YOUR journal, '
                     'one line each, when you act on them):\n' + '\n'.join(news))
    if not texts:
        return None
    return {'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': '\n'.join(texts)}}


def ledger(ctx):
    p = os.path.join(ctx.sdir, 'worker-ledger.jsonl')
    out = []
    for line in (read(p) or '').splitlines():
        try:
            out.append(json.loads(line))
        except Exception:
            pass
    return out


def unseen_ledger(ctx, lease):
    seen = lease.get('ledger_seen') or lease.get('started') or 0
    rows = [e for e in ledger(ctx) if e.get('t', 0) > seen and e.get('sid') != lease['sid']]
    if rows:
        lease['ledger_seen'] = max(e['t'] for e in rows)
    return [f"  - worker {e['sid'][:8]} ({e.get('worktree')}/{e.get('branch')}): {e.get('head') or 'no commit'} | "
            f"{e.get('summary', '')[:180]}" for e in rows[-8:]]


def deny(reason):
    return {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny',
                                   'permissionDecisionReason': reason}}


def tool_text(name, ti):
    """The new text a tool call puts into a file."""
    if name == 'apply_patch':
        return patch_added_text(str(ti.get('command') or ti.get('patch') or ti.get('input') or ''))
    if name == 'Bash':
        return str(ti.get('command', ''))
    return ti.get('content') or ti.get('new_string') or ti.get('new_source') or \
        '\n'.join(e.get('new_string', '') for e in ti.get('edits') or [] if isinstance(e, dict))


def tool_may_matter(event, inp):
    """Fast path: decide without git or file I/O whether this tool call can matter to the journal hooks."""
    tool, ti = inp.get('tool_name', ''), inp.get('tool_input') or {}
    tail = os.path.basename(os.path.normpath(os.environ.get('SESSION_JOURNAL_DIR') or 'sessions')) + '/'
    blob = json.dumps(ti) if isinstance(ti, dict) else str(ti)
    if tail in blob.replace('\\\\', '/').replace('\\/', '/'):
        return True
    if event == 'PostToolUse':                         # landed work is recorded for runtimes without a usable transcript
        if tool in LANDING_TOOLS:
            return True
        if tool == 'Bash':
            cmd = str((ti or {}).get('command', ''))
            extra = os.environ.get('JOURNAL_LANDING_BASH')
            return bool(COMMIT_BASH.search(cmd) or (extra and re.search(extra, cmd)))
    return False


def same_repo_worktree_journal_dir(ctx, path):
    """True when path is <linked worktree of THIS repository>/<journal dir>/<journal>; other repositories are not ours."""
    d = os.path.dirname(os.path.abspath(path))
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    common = git('rev-parse', '--git-common-dir', cwd=d)
    return bool(common) and bool(ctx.common) and \
        os.path.realpath(os.path.join(d, common)) == os.path.realpath(ctx.common)


def pending_path(ctx, inp):
    key = re.sub(r'[^A-Za-z0-9_-]', '', (inp.get('session_id') or 'nosid') + '-' + (inp.get('tool_use_id') or 'x'))
    return os.path.join(ctx.sdir, 'pending', key)


def in_jdir(ctx, path):
    return os.path.realpath(os.path.dirname(os.path.join(ctx.cwd, path))) == os.path.realpath(ctx.jdir)


def on_pre_tool(ctx, inp):
    tool, ti = inp.get('tool_name', ''), inp.get('tool_input') or {}
    names, paths = [], []
    if tool in LANDING_TOOLS:
        if tool == 'apply_patch':
            paths = [p for p in patch_paths(str(ti.get('command') or ''), ctx.cwd) if ctx.journal_name(p)]
        else:
            p = ti.get('file_path') or ti.get('notebook_path') or ''
            paths = [p] if ctx.journal_name(p) else []
        names = [ctx.journal_name(p) for p in paths]
    elif tool == 'Bash':
        names = ctx.bash_journal_writes(str(ti.get('command', '')), cwd=ctx.cwd)
        try:                       # PostToolUse compares journal mtimes against this to catch variable-path writes
            with open(pending_path(ctx, inp), 'w') as fh:
                fh.write(str(time.time()))
        except OSError:
            pass
    if not names:
        return None
    for p in paths:
        if not in_jdir(ctx, p):
            if same_repo_worktree_journal_dir(ctx, p):
                return deny(f'Journals live only in the main checkout: write {ctx.jpath(ctx.journal_name(p))} instead '
                            f'of {p} (a linked worktree has its own stale copy of {ctx.jrel}/).')
            return None            # another repository's file that happens to look like a journal
    lease = ctx.lease(inp.get('session_id') or 'nosid') or new_lease(ctx, inp)
    if hard_worker(lease):
        ctx.trace(ev='deny', sid=lease['sid'], why='worker', journal=names[0])
        return deny(f'This session is a worker (JOURNAL_ROLE=worker): do not write session journals. Put results in '
                    f'your report to the lead. If this session should keep a journal, run '
                    f'`python3 {ctx.script} role lead` and retry.')
    for jn in names:
        owners = ctx.owners(jn, me=lease)
        if owners:
            o = owners[0]
            ctx.trace(ev='deny', sid=lease['sid'], why='in-use', journal=jn, owner=o['sid'])
            return deny(f"{ctx.show(jn)} is in use by live session {o['sid'][:8]} (worktree {o.get('worktree')}, "
                        f"branch {o.get('branch')}). Create your own journal and add '**Continues:** {ctx.show(jn)}' "
                        f"to link it. (If that session is gone, run `python3 {ctx.script} release {o['sid'][:8]}`.)")
    if ctx.secrets == 'deny':
        hits = scan_secrets(tool_text(tool, ti))
        if hits:
            ctx.trace(ev='deny', sid=lease['sid'], why='secret', journal=names[0], kinds=[h[1] for h in hits])
            return deny(f'The text for {ctx.show(names[0])} looks like it contains a credential ({fmt_hits(hits)} of '
                        'the new text; values are not shown). Journals are committed and long-lived: write where the '
                        'secret lives instead (a vault or secret name, an env-var reference, or <redacted>). If a '
                        f'human has verified a line carries no credential, append {SKIP_OK} to that line.')
    return None


def on_post_tool(ctx, inp):
    tool, ti = inp.get('tool_name', ''), inp.get('tool_input') or {}
    notes = []
    names, files, cmd = tool_targets(ctx, tool, ti, cwd=ctx.cwd)
    if tool in LANDING_TOOLS:
        paths = patch_paths(str(ti.get('command') or ''), ctx.cwd) if tool == 'apply_patch' else \
            [ti.get('file_path') or ti.get('notebook_path') or '']
        names = [ctx.journal_name(p) for p in paths if ctx.journal_name(p) and in_jdir(ctx, p)]
    elif cmd is not None:
        t0 = None
        try:
            p = pending_path(ctx, inp)
            with open(p) as fh:
                t0 = float(fh.read().strip() or 0)
            os.remove(p)
        except (OSError, ValueError):
            pass
        if t0:
            extra = [n for n in journals_changed_since(ctx, t0) if n not in names]
            if len(extra) > 2:                          # a bulk rewrite of many journals binds nothing
                ctx.trace(ev='bulk-journal-change', sid=inp.get('session_id'), n=len(extra))
                extra = []
            names = names + extra
    names = [n for n in dict.fromkeys(names) if n]
    landed = bool(files) or bool(cmd and ctx.landing_bash.search(cmd))
    if not names and not landed:
        return None
    with ctx.lock():
        lease = get_lease(ctx, inp)
        key = turn_key(inp, lease)
        turn = turn_record(lease, key)
        if landed:
            turn['landed'] = True
            turn['files'] = (turn['files'] + [f for f in files if f])[-20:]
            if cmd and COMMIT_BASH.search(cmd):
                turn['committed'] = True
                turn['commits'] = (turn['commits'] + [re.sub(r'\s+', ' ', cmd)[:160]])[-5:]
        if names and hard_worker(lease):
            ctx.save_lease(lease)
            return {'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext':
                    f"You are a worker (JOURNAL_ROLE=worker) and just changed {ctx.show(names[-1])}. Revert that "
                    "change; report to your lead instead."}}
        for jn in names:
            owners = ctx.owners(jn, me=lease)
            if owners:
                notes.append(f"{ctx.show(jn)} is in use by live session {owners[0]['sid'][:8]}; move what you just "
                             f"wrote into your own journal (with '**Continues:** {ctx.show(jn)}') and revert it there.")
        free = [jn for jn in names if not ctx.owners(jn, me=lease)]
        if free:
            bind(ctx, lease, free[-1], 'write')
            lease['last_write'] = time.time()
            lease['writes'] = (lease.get('writes') or [])[-50:] + [[free[-1], time.time(), key]]
            lease['unjournaled_turns'] = 0
            turn['journals'] = sorted(set(turn['journals']) | set(free))
            c = card(ctx, free[-1])
            if c and c['bytes'] > ctx.max_bytes and lease.get('size_warned') != free[-1]:
                lease['size_warned'] = free[-1]
                notes.append(f"{ctx.show(free[-1])} is {c['bytes'] // 1024} KB. Finish this update, then continue the "
                             f"work in a new journal whose header says '**Continues:** {ctx.show(free[-1])}'.")
        ctx.save_lease(lease)
    if names and ctx.secrets == 'warn':
        hits = scan_secrets(tool_text(tool, ti))
        if hits:
            ctx.trace(ev='secret-warning', sid=lease['sid'], journal=names[-1], kinds=[h[1] for h in hits])
            notes.append(f"The text you just wrote to {ctx.show(names[-1])} looks like it contains a credential "
                         f"({fmt_hits(hits)}). Replace the value with where the secret lives.")
    if notes:
        return {'hookSpecificOutput': {'hookEventName': 'PostToolUse', 'additionalContext': '\n'.join(notes)}}
    return None


def on_stop(ctx, inp):
    sid = inp.get('session_id') or 'nosid'
    pre = ctx.lease(sid) or {}
    f = turn_facts(ctx, read_transcript(inp.get('transcript_path')), floor=pre.get('bind_floor') or 0)
    nudge = None
    with ctx.lock():
        lease = get_lease(ctx, inp)
        key = turn_key(inp, lease, fallback=f['turn_start_ts'])
        t0 = iso_epoch(f['turn_start_ts'] or '') - 2
        turn = turn_record(lease, key)
        # bind from the transcript too (Bash/python writes), never onto a live owner's journal
        if f['session_journal_writes'] and not hard_worker(lease):
            jn = f['session_journal_writes'][-1]
            if not ctx.owners(jn, me=lease):
                bind(ctx, lease, jn, 'transcript')
            if f['last_journal_write_ts']:
                lease['last_write'] = max(lease.get('last_write') or 0, iso_epoch(f['last_journal_write_ts']))
        hook_writes = [w[0] for w in lease.get('writes') or []
                       if (len(w) > 2 and w[2] == key) or (key == f['turn_start_ts'] and t0 > 0 and w[1] >= t0)]
        touched = set(f['turn_journal_writes']) | set(hook_writes) | set(turn['journals'])
        landed = f['landed'] or turn['landed']
        committed = f['committed'] or turn['committed']
        if touched:
            lease['unjournaled_turns'] = 0
        elif landed and lease.get('counted') != key:
            lease['unjournaled_turns'] = lease.get('unjournaled_turns', 0) + 1     # once per turn, not per Stop round
            lease['counted'] = key
        if lease['role'] == 'worker' and landed and not inp.get('stop_hook_active') and lease.get('ledgered') != key:
            entry = {'t': time.time(), 'sid': lease['sid'], 'worktree': lease.get('worktree'),
                     'branch': lease.get('branch'), 'task': (f['first_prompt'] or '')[:200],
                     'head': git('log', '-1', '--format=%h %s', cwd=ctx.root) if committed else None,
                     'commits': (f['turn_commits'] or turn['commits'])[-5:],
                     'files': sorted({os.path.relpath(x, ctx.main) if x.startswith(ctx.main) else x
                                      for x in f['turn_files'] + turn['files'] if x})[:20],
                     'summary': re.sub(r'\s+', ' ', inp.get('last_assistant_message') or f['last_text'])[:400]}
            with open(os.path.join(ctx.sdir, 'worker-ledger.jsonl'), 'a') as fh:
                fh.write(json.dumps(entry) + '\n')
            lease['ledgered'] = key
        why = None
        if not landed:
            result = 'readonly'
        elif touched:
            result = 'fresh'
        elif lease['role'] == 'worker':
            result, why = 'skip', 'worker'
        elif skipping(lease):
            result, why = 'skip', 'skip'
        elif inp.get('stop_hook_active') or lease.get('nudged') == key:
            result, why = 'skip', 'already-nudged'
        else:
            since = (time.time() - (lease.get('last_write') or lease.get('started') or time.time())) / 60
            due = committed or not lease.get('journal') or lease.get('unjournaled_turns', 0) >= 2 or \
                since >= ctx.nudge_min
            if not due:
                result = 'debounced'
            else:
                result = 'nudge'
                lease['nudged'] = key
                nudge = (lease.get('journal'), committed, lease.get('unjournaled_turns', 0), since)
        ctx.save_lease(lease)
    ctx.trace(ev='stop', sid=sid, result=result, why=why, journal=lease.get('journal'),
              unjournaled=lease.get('unjournaled_turns'))
    if not nudge:
        return None
    journal, committed, unjournaled, since = nudge
    if not journal:
        rows = candidates(ctx, lease, 3)
        msg = (f"SESSION-JOURNAL: this turn landed work but this session has no journal yet. Create "
               f"{ctx.jdir}/YYYY-MM-DD-HHMM-<slug>.md (local time) from {ctx.jrel}/TEMPLATE.md, or append to a "
               f"candidate it truly continues (never one marked IN USE). If this session needs no journal, say so "
               f"and stop."
               + (f"\n{fmt_candidates(ctx, rows)}" if rows else ''))
    else:
        c = card(ctx, journal) or {}
        pointer = c.get('pointer', 'none')
        why = 'a commit or push landed' if committed else \
            f"{unjournaled} landed turns / {since:.0f} min since its last update"
        if is_thin(pointer):
            msg = (f"SESSION-JOURNAL (THIN): add one milestone line to YOUR journal {ctx.jpath(journal)} ({why}) that "
                   f"points at {pointer.strip('`- ')} (section, version or commit), and bump 'Last updated'; change "
                   "'Where we are now' or 'Next step' only if they moved. Do not re-narrate the plan.")
        else:
            msg = (f"SESSION-JOURNAL: update YOUR journal {ctx.jpath(journal)} ({why}). DETAILED mode: milestones, "
                   "evidence, commits, files touched. Refresh 'Last updated', 'Where we are now' and 'Next step for "
                   "a fresh agent'.")
    return {'decision': 'block', 'reason': msg}


def stamp_session_line(ctx, name, lease, status=None):
    """Hook-managed header lines, written only when no live session is editing the journal."""
    p = ctx.jpath(name)
    text = read(p)
    if text is None:
        return
    tag = f"{lease['sid'][:8]} ({lease.get('worktree', '?')}/{lease.get('branch', '?')}, {lease.get('runtime') or 'agent'})"
    new = text
    sessions = header(new, 'Sessions')
    if lease['sid'][:8] not in sessions:
        if sessions:
            new = re.sub(r'^(\*\*Sessions:\*\*\s*)(.+)$', lambda m: m.group(1) + m.group(2) + ', ' + tag, new, count=1,
                         flags=re.M)
        else:
            new = re.sub(r'^(\*\*Status:\*\*.*)$', lambda m: m.group(1) + '\n**Sessions:** ' + tag, new, count=1,
                         flags=re.M)
    if status and header(new, 'Status').upper().startswith('ACTIVE'):
        new = re.sub(r'^(\*\*Status:\*\*\s*)ACTIVE\b.*$', lambda m: m.group(1) + status, new, count=1,
                     flags=re.M | re.I)
    if new != text:
        tmp = f'{p}.{os.getpid()}.tmp'
        with open(tmp, 'w') as fh:
            fh.write(new)
        os.replace(tmp, p)


def on_session_end(ctx, inp):
    reason = inp.get('reason') or 'other'
    with ctx.lock():
        lease = ctx.lease(inp.get('session_id') or 'nosid')
        if not lease:
            return None
        lease['ended'] = time.time()
        lease['end_reason'] = reason
        ctx.save_lease(lease)
    if lease.get('journal') and lease['role'] != 'worker' and not ctx.owners(lease['journal']):
        # /clear starts a new session in the same window, which usually carries on: record it, keep the status.
        pause = reason != 'clear' and os.environ.get('JOURNAL_PAUSE_ON_END', '1') not in ('0', 'false', 'no')
        stamp_session_line(ctx, lease['journal'], lease,
                           status='PAUSED (auto: session ended without DONE)' if pause else None)
    ctx.trace(ev='SessionEnd', sid=lease['sid'], journal=lease.get('journal'), reason=reason)
    return None


HANDLERS = {'SessionStart': on_session_start, 'UserPromptSubmit': on_user_prompt, 'PreToolUse': on_pre_tool,
            'PostToolUse': on_post_tool, 'Stop': on_stop, 'SessionEnd': on_session_end}


def run_hook(event):
    out = None
    try:
        if os.environ.get('SESSION_JOURNAL_DISABLE') not in (None, '', '0') or event not in HANDLERS:
            return 0
        raw = sys.stdin.read() if not sys.stdin.isatty() else ''
        try:
            inp = json.loads(raw) if raw.strip() else {}
        except Exception:
            inp = {}
        if not isinstance(inp, dict):
            inp = {}
        if event in ('PreToolUse', 'PostToolUse') and not tool_may_matter(event, inp):
            return 0                    # most tool calls: no git, no file I/O
        ctx = None
        try:
            ctx = Ctx(inp.get('cwd'))
            if not ctx.enabled:
                return 0
            out = HANDLERS[event](ctx, inp)
        except Exception as e:          # a journal hook must never break the session
            if ctx is not None and ctx.enabled:
                ctx.trace(ev='error', event=event, err=repr(e)[:300])
            out = None
        return 0
    finally:
        if out:
            print(json.dumps(out))
        elif event == 'Stop':
            print('{}')                 # Codex requires JSON on stdout from a Stop hook that exits 0


# ---------------------------------------------------------------- CLI

def transcripts_for(ctx, sid_prefix):
    for l in ctx.leases():
        if l['sid'].startswith(sid_prefix) and l.get('transcript') and os.path.exists(l['transcript']):
            return l['transcript']
    root = os.environ.get('JOURNAL_TRANSCRIPTS_DIR') or os.path.expanduser('~/.claude/projects')
    hits = glob.glob(os.path.join(root, '*', sid_prefix + '*.jsonl'))
    return hits[0] if hits else None


def session_brief(ctx, path, max_prompts=6):
    entries = read_transcript(path)
    prompts, files, commits, last = [], [], [], ''
    for d in entries:
        if is_human(d):
            c = (d.get('message') or {}).get('content')
            t = c if isinstance(c, str) else ' '.join(x.get('text', '') for x in c or [] if isinstance(x, dict))
            prompts.append((d.get('timestamp', '')[:16], re.sub(r'\s+', ' ', t)[:200]))
        if d.get('type') == 'assistant' and not d.get('isSidechain'):
            for c in (d.get('message') or {}).get('content') or []:
                if isinstance(c, dict) and c.get('type') == 'tool_use':
                    _, fs, cmd = tool_targets(ctx, c.get('name', ''), c.get('input') or {})
                    files += fs
                    if cmd and COMMIT_BASH.search(cmd):
                        commits.append(re.sub(r'\s+', ' ', cmd)[:160])
                elif isinstance(c, dict) and c.get('type') == 'text' and c.get('text'):
                    last = c['text']
    return {'first': entries[0].get('timestamp', '') if entries else '',
            'last': entries[-1].get('timestamp', '') if entries else '', 'prompts': prompts[:max_prompts],
            'n_prompts': len(prompts), 'files': sorted(set(files)), 'commits': commits[-8:],
            'last_text': re.sub(r'\s+', ' ', last)[:600]}


def norm_name(ctx, name):
    base = os.path.basename(name.rstrip('/'))
    return base if NAME.match(base) else None


def cmd_reconstruct(ctx, name):
    name = norm_name(ctx, name) or name
    c = card(ctx, name)
    if not c:
        print(f'no such journal: {name}')
        return 1
    text = read(ctx.jpath(name)) or ''
    sids = set(re.findall(r'\b([0-9a-f]{8})\b', c['sessions']))
    sids |= {l['sid'][:8] for l in ctx.leases() if l.get('journal') == name or name in (l.get('history') or [])}
    print(f"# Reconstruct {name}\n{c['title']} | status {c['status']} | updated {c['updated']} | {c['bytes']} bytes")
    print(f"Plan pointer: {c['pointer']}\nContinues: {header(text, 'Continues') or '-'}\n\n## Next step (journal)\n"
          f"{section(text, 'Next step for a fresh agent')}\n")
    print('## Where we are now (journal)\n' + section(text, 'Where we are now') + '\n')
    for s in sorted(sids):
        tp = transcripts_for(ctx, s)
        if not tp:
            print(f'## Session {s}: transcript not found')
            continue
        b = session_brief(ctx, tp)
        print(f"## Session {s} ({b['first'][:16]} -> {b['last'][:16]}, {b['n_prompts']} prompts)\nTranscript: {tp}")
        for ts, p in b['prompts']:
            print(f'  - [{ts}] {p}')
        if b['commits']:
            print('  commits: ' + ' | '.join(b['commits']))
        if b['files']:
            print('  files: ' + ', '.join(os.path.relpath(f, ctx.main) if f.startswith(ctx.main) else f
                                          for f in b['files'][:25]))
        print(f"  last reply: {b['last_text']}\n")
    later = [os.path.basename(p) for p in ctx.journals() if name in header(read(p) or '', 'Continues')]
    if later:
        print('## Continued by\n' + '\n'.join('  - ' + ctx.show(x) for x in later))
    return 0


def cmd_find(ctx, words):
    q = [w.lower() for w in words]
    if not q:
        print('usage: find <words..>')
        return 1
    rows = []
    for p in ctx.journals():
        low = (read(p) or '').lower()
        score = sum(low.count(w) for w in q) + 5 * sum(w in os.path.basename(p).lower() for w in q)
        if score and all(w in low for w in q):
            rows.append((score, card(ctx, os.path.basename(p))))
    rows.sort(key=lambda r: (-r[0], -r[1]['mtime']))
    for s, c in rows[:15]:
        print(f"{s:4d}  {ctx.show(c['journal'])}  [{c['label']}] {c['title'][:60]}\n      next: {c['next'][:150]}")
    wl = [e for e in ledger(ctx) if all(w in json.dumps(e).lower() for w in q)]
    if wl:
        print('\nWorker ledger (dispatched work that has no journal of its own):')
        for e in wl[-10:]:
            print(f"  {dt.datetime.fromtimestamp(e['t']):%Y-%m-%d %H:%M} worker {e['sid'][:8]} "
                  f"{e.get('worktree')}/{e.get('branch')}: {e.get('head') or '-'} | {e.get('summary', '')[:150]}")
    if not rows and not wl:
        print('no journal matches')
    return 0


def caller_sid():
    return os.environ.get('SESSION_JOURNAL_SESSION_ID') or os.environ.get('CLAUDE_CODE_SESSION_ID') or \
        os.environ.get('CODEX_THREAD_ID') or ''


def cmd_candidates(ctx, words):
    """The SessionStart view on demand: this session's bound journal, then open candidates (IN USE marked), optionally
    only those whose text contains every word. Use it instead of picking the newest file by name or mtime."""
    sid = caller_sid()
    lease = next((x for x in ctx.leases() if sid and x['sid'] == sid), None) or \
        {'sid': sid or 'cli', 'worktree': ctx.worktree, 'branch': ctx.branch}
    if lease.get('journal') and lease.get('role') != 'worker':
        print(f"bound: {ctx.show(lease['journal'])}")
    q = [w.lower() for w in words]
    rows = candidates(ctx, lease, limit=500 if q else 5)
    if q:
        rows = [r for r in rows if all(w in (read(ctx.jpath(r[1]['journal'])) or '').lower() for w in q)][:5]
    print(fmt_candidates(ctx, rows) if rows else 'no open candidates' + (' match' if q else ''))
    return 0


def cmd_list(ctx, args):
    now = time.time()
    for l in sorted(ctx.leases(), key=lambda x: -(x.get('heartbeat') or 0)):
        if '--all' not in args and not ctx.is_live(l):
            continue
        print(f"{l['sid'][:8]} {'LIVE' if ctx.is_live(l) else 'ended'} {l.get('role', '?'):6} "
              f"{str(l.get('worktree')):>18}/{str(l.get('branch')):<22} hb {int((now - (l.get('heartbeat') or 0)) / 60)}m"
              f"  journal={l.get('journal') or '-'}")
    return 0


def health(ctx):
    """Drift indicators: run it on a schedule, or before trusting the hooks."""
    leases = ctx.leases()
    by_j = {}
    for l in leases:
        if l.get('journal'):
            by_j.setdefault(l['journal'], set()).add(l['sid'])
    cards = [c for c in (card(ctx, os.path.basename(p)) for p in ctx.journals()) if c]
    stale_active = [c['journal'] for c in cards if c['status'] == 'ACTIVE' and time.time() - c['mtime'] > 7 * 86400
                    and not ctx.owners(c['journal'])]
    secrets = []
    for c in cards:
        h = scan_secrets(read(ctx.jpath(c['journal'])))
        if h:
            secrets.append((c['journal'], sorted({x[1] for x in h})))
    ev = []
    for x in (read(os.path.join(ctx.sdir, 'events.jsonl')) or '').splitlines():
        try:
            ev.append(json.loads(x))
        except Exception:
            pass

    def cnt(**kw):
        return sum(all(e.get(k) == v for k, v in kw.items()) for e in ev)

    landed = {e.get('sid') for e in ev if e.get('ev') == 'stop' and e.get('result') in ('nudge', 'debounced', 'fresh', 'skip')}
    return {
        'version': VERSION, 'journal_dir': ctx.jdir, 'journals': len(cards),
        'open': sum(c['status'] not in CLOSED for c in cards), 'stale_active_7d': len(stale_active),
        'oversized': sum(c['bytes'] > ctx.max_bytes for c in cards),
        'multi_session_journals': sum(len(v) > 1 for v in by_j.values()),
        'secret_journals': len(secrets), 'secret_examples': secrets[:10],
        'leases': len(leases), 'live_sessions': sum(ctx.is_live(l) for l in leases),
        'workers': sum(l.get('role') == 'worker' for l in leases),
        'nudges': cnt(ev='stop', result='nudge'), 'debounced': cnt(ev='stop', result='debounced'),
        'fresh_turns': cnt(ev='stop', result='fresh'),
        'nudges_per_landed_session': round(cnt(ev='stop', result='nudge') / max(len(landed), 1), 2),
        'deny_in_use': cnt(ev='deny', why='in-use'), 'deny_worker': cnt(ev='deny', why='worker'),
        'deny_secret': cnt(ev='deny', why='secret'), 'secret_warnings': cnt(ev='secret-warning'),
        'clear_handoffs': sum(1 for e in ev if e.get('ev') == 'SessionStart' and e.get('predecessor')),
        'hook_errors': cnt(ev='error'),
    }


def cmd_scan(ctx, paths):
    """Secret scan of the given files, or of every journal. Prints line numbers and rule names, never values."""
    files = paths or ctx.journals()
    bad = 0
    for p in files:
        hits = scan_secrets(read(p) or '')
        if hits:
            bad += 1
            print(f'{p}: {fmt_hits(hits)}')
    print(f'scan: {bad} of {len(files)} file(s) carry credential-shaped content')
    return 1 if bad else 0


def last_commit_dates(ctx):
    """Latest commit time per journal in one git log pass (checkouts and clones reset mtimes)."""
    out, cur = {}, None
    for line in git('log', '--format=@%ct', '--name-only', '--', ctx.jdir, cwd=ctx.main, timeout=120).splitlines():
        if line.startswith('@'):
            cur = int(line[1:])
        elif line.strip() and cur:
            out.setdefault(os.path.basename(line.strip()), cur)
    return out


def header_epoch(value):
    m = re.search(r'(\d{4}-\d\d-\d\d)[ T](\d\d):(\d\d)', value or '')
    if not m:
        return 0
    try:
        return time.mktime(time.strptime(f'{m.group(1)} {m.group(2)}:{m.group(3)}', '%Y-%m-%d %H:%M'))
    except (ValueError, OverflowError):
        return 0


def cmd_sweep(ctx, args):
    """End dead leases, drop ended leases older than 30 days, and PAUSE ACTIVE journals nobody live owns that went
    quiet (default 24 h). --dry-run prints what would change. --by-git dates activity by last commit and the
    'Last updated' header (plus mtime when the journal is dirty) instead of checkout mtimes."""
    dry, by_git = '--dry-run' in args, '--by-git' in args
    nums = [a for a in args if not a.startswith('--')]
    try:
        hours = float(nums[0]) if nums else 24
    except ValueError:
        print('usage: sweep [hours] [--dry-run] [--by-git]')
        return 1
    now, changes = time.time(), []
    for l in ctx.leases():
        if l.get('ended') and now - l['ended'] > 30 * 86400:
            changes.append(f"drop lease {l['sid'][:8]} (ended {int((now - l['ended']) / 86400)}d ago)")
            if not dry:
                with contextlib.suppress(OSError):
                    os.remove(ctx.lease_path(l['sid']))
        elif not l.get('ended') and not ctx.is_live(l) and now - (l.get('heartbeat') or 0) > 6 * 3600:
            changes.append(f"end lease {l['sid'][:8]} (journal {l.get('journal') or '-'})")
            if not dry:
                with ctx.lock():
                    l['ended'], l['end_reason'] = now, 'sweep-timeout'
                    ctx.save_lease(l, touch=False)
                if l.get('journal') and not ctx.owners(l['journal']):
                    stamp_session_line(ctx, l['journal'], l)
    gdates = last_commit_dates(ctx) if by_git else {}
    if by_git and not gdates and git('ls-files', '--', ctx.jdir, cwd=ctx.main):
        print('sweep --by-git: git log over the journal directory returned nothing (timeout or error); refusing to '
              'judge idleness by checkout mtimes. Re-run, or run without --by-git.')
        return 2
    dirty = {os.path.basename(x[3:].strip()) for x in git('status', '--porcelain', '--', ctx.jdir,
                                                          cwd=ctx.main).splitlines()} if by_git else set()
    agent = {}
    for l in ctx.leases():
        for w in l.get('writes') or []:
            agent[w[0]] = max(agent.get(w[0], 0), w[1])
    for p in ctx.journals():
        c = card(ctx, os.path.basename(p))
        if not c or c['status'] != 'ACTIVE' or ctx.owners(c['journal']):
            continue
        n = c['journal']
        base = gdates.get(n, 0) if by_git else c['mtime']
        if by_git and (n in dirty or not gdates.get(n)):
            base = max(base, c['mtime'])
        act = max(base, header_epoch(c['updated']), agent.get(n, 0))
        if now - act > hours * 3600:
            changes.append(f'pause {ctx.show(n)} (idle {int((now - act) / 86400)}d)')
            if not dry:
                text = read(p) or ''
                text = re.sub(r'^(\*\*Status:\*\*\s*)ACTIVE\b.*$',
                              lambda m: m.group(1) + f'PAUSED (auto: idle >{hours:.0f}h)', text, count=1, flags=re.M)
                tmp = f'{p}.{os.getpid()}.tmp'
                with open(tmp, 'w') as fh:
                    fh.write(text)
                os.replace(tmp, p)
    for ch in changes:
        print(('  would ' if dry else '  ') + ch)
    print(f"sweep{' (dry run)' if dry else ''}: {len(changes)} changes")
    return 0


USAGE = ('commands: candidates [words..] | find <words..> | reconstruct <journal> | list [--all] | health | '
         'scan [files..] | sweep [hours] [--dry-run] [--by-git] | whoami [sid] | bound [sid] | '
         'bind [sid] <journal> [--force] | release <sid> | role lead|worker [sid] | skip [sid] | version\n'
         '(sid defaults to $CLAUDE_CODE_SESSION_ID or $CODEX_THREAD_ID; set SESSION_JOURNAL_SESSION_ID to override)')


def main(argv):
    if len(argv) >= 2 and argv[0] == 'hook':
        return run_hook(argv[1])
    cmd, args = (argv[0] if argv else 'help'), argv[1:]
    if cmd in ('version', '--version'):
        print(VERSION)
        return 0
    if cmd in ('help', '-h', '--help'):
        print(__doc__)
        print(USAGE)
        return 0
    ctx = Ctx()
    if not ctx.enabled:            # run from elsewhere: use the project this script is installed in
        ctx = Ctx(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    if not ctx.enabled:
        print(f'no journal directory at {ctx.jdir}')
        return 1
    sid_arg = lambda a: (a[0] if a else '') or caller_sid()
    find_lease = lambda sid: next((x for x in ctx.leases() if sid and x['sid'].startswith(sid)), None)
    if cmd == 'list':
        return cmd_list(ctx, args)
    if cmd == 'whoami':
        l = find_lease(sid_arg(args))
        print(json.dumps(l, indent=1) if l else 'unknown session (no lease; pass a session id prefix)')
        return 0
    if cmd == 'bound':
        l = find_lease(sid_arg(args))
        if l and l.get('journal') and l.get('role') != 'worker':
            print(ctx.jpath(l['journal']))
        return 0
    if cmd == 'find':
        return cmd_find(ctx, args)
    if cmd == 'candidates':
        return cmd_candidates(ctx, args)
    if cmd == 'reconstruct' and args:
        return cmd_reconstruct(ctx, args[0])
    if cmd == 'health':
        print(json.dumps(health(ctx), indent=1))
        return 0
    if cmd == 'scan':
        return cmd_scan(ctx, args)
    if cmd == 'sweep':
        return cmd_sweep(ctx, args)
    if cmd == 'release' and args:
        with ctx.lock():
            for l in ctx.leases():
                if l['sid'].startswith(args[0]):
                    l['ended'], l['end_reason'] = time.time(), 'released'
                    ctx.save_lease(l, touch=False)
                    print('released', l['sid'])
        return 0
    if cmd in ('role', 'skip'):
        if cmd == 'role' and not (args and args[0] in ('lead', 'worker')):
            print('usage: role lead|worker [sid]')
            return 1
        rest = args[1:] if cmd == 'role' else args
        with ctx.lock():
            l = find_lease(sid_arg(rest))
            if not l:
                print('unknown session (pass a session id prefix)')
                return 1
            if cmd == 'role':
                l['role'], l['role_source'] = args[0], 'cli'
            else:
                l['skip'] = True
            ctx.save_lease(l)
        print(f"{l['sid'][:8]} " + (f'role={args[0]}' if cmd == 'role' else 'skip: no journal nudges this session'))
        return 0
    if cmd == 'bind' and args:
        plain = [a for a in args if not a.startswith('--')]
        sid, jn = (caller_sid(), plain[0]) if len(plain) == 1 else (plain[0], plain[1])
        jn = norm_name(ctx, jn)
        if not sid or not jn:
            print('usage: bind [<sid>] <journal>  (sid defaults to the caller session id)')
            return 1
        with ctx.lock():
            l = find_lease(sid) or {'sid': sid, 'role': 'lead', 'role_source': 'default', 'worktree': ctx.worktree,
                                    'branch': ctx.branch, 'history': [], 'writes': [], 'started': time.time()}
            owners = ctx.owners(jn, me=l)
            if owners and '--force' not in args:
                print(f"{ctx.show(jn)} is in use by live session {owners[0]['sid'][:8]}; use --force to bind anyway")
                return 1
            bind(ctx, l, jn, 'manual')
            ctx.save_lease(l)
        return 0
    print(USAGE)
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
