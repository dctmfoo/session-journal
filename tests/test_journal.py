"""Scenario tests for hooks/session-journal.py: parallel sessions, worktrees, workers, /clear, fork, cwd anchoring,
nudges, secrets, Codex-style input, reconstruct, sweep.

Run from the repository root:  python3 -m unittest discover -s tests -p 'test_*.py'
Every scenario builds a throwaway git repository with a linked worktree; nothing outside the temp dir is touched."""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
J = os.path.join(ROOT, 'hooks', 'session-journal.py')


def sh(*a, cwd, env=None):
    return subprocess.run(a, cwd=cwd, capture_output=True, text=True, check=True, env=env).stdout


class Transcript:
    """Minimal Claude Code JSONL writer. Each human prompt gets a prompt_id that Lab.hook passes to Pre/PostToolUse and
    Stop, the way Claude Code does."""
    by_path = {}

    def __init__(self, path, t0=None):
        self.path = path
        open(path, 'w').close()
        self.n = 0
        self.t0 = t0 or time.time()
        self.prompt_id = None
        Transcript.by_path[path] = self

    def _w(self, d):
        self.n += 1
        d.setdefault('timestamp', time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(self.t0 + self.n)) + '.000Z')
        with open(self.path, 'a') as f:
            f.write(json.dumps(d) + '\n')

    def human(self, text):
        self.prompt_id = f'prompt-{self.n + 1}'
        self._w({'type': 'user', 'message': {'role': 'user', 'content': text}, 'origin': {'kind': 'human'}})

    def tool(self, name, **inp):
        self._w({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
            {'type': 'tool_use', 'id': f't{self.n}', 'name': name, 'input': inp}]}})

    def error(self, reason):
        """The tool_result recorded for the last tool_use when a hook denied it."""
        self._w({'type': 'user', 'message': {'role': 'user', 'content': [
            {'type': 'tool_result', 'tool_use_id': f't{self.n - 1}', 'is_error': True, 'content': reason}]}})

    def say(self, text):
        self._w({'type': 'assistant', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': text}]}})


JOURNAL = """# Session: {title}

**Started:** 2026-01-08 10:00 UTC
**Last updated:** 2026-01-08 10:00 UTC
**Status:** ACTIVE

## User intent
{title}

## Live plan pointer
{pointer}

## Milestones
- 10:00 - opened

## Where we are now
- working

## Next step for a fresh agent
Continue {title}.
"""


class Lab(unittest.TestCase):
    jrel = 'sessions'

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='jlab-')
        self.repo = os.path.join(self.tmp, 'repo')
        os.makedirs(self.repo)
        sh('git', 'init', '-q', '-b', 'main', cwd=self.repo)
        sh('git', 'config', 'user.email', 't@t.invalid', cwd=self.repo)
        sh('git', 'config', 'user.name', 't', cwd=self.repo)
        self.jdir = os.path.join(self.repo, self.jrel)
        os.makedirs(self.jdir)
        open(os.path.join(self.repo, 'README.md'), 'w').write('x')
        sh('git', 'add', '.', cwd=self.repo)
        sh('git', 'commit', '-qm', 'init', cwd=self.repo)
        self.wt = os.path.join(self.tmp, 'wt-feature')
        sh('git', 'worktree', 'add', '-q', '-b', 'feature', self.wt, cwd=self.repo)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('JOURNAL', 'SESSION_JOURNAL', 'CLAUDE', 'CODEX'))}
        if self.jrel != 'sessions':
            self.env['SESSION_JOURNAL_DIR'] = self.jrel
        self.state = os.path.join(self.repo, '.claude/state/session-journal')

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def hook(self, event, sid, cwd=None, env=None, **inp):
        tr = Transcript.by_path.get(inp.get('transcript_path'))
        if event in ('PreToolUse', 'PostToolUse', 'Stop') and 'prompt_id' not in inp and 'turn_id' not in inp \
                and tr and tr.prompt_id:
            inp['prompt_id'] = tr.prompt_id
        payload = dict(session_id=sid, cwd=cwd or self.repo, hook_event_name=event, **inp)
        e = dict(self.env, **(env or {}))
        r = subprocess.run([sys.executable, J, 'hook', event], input=json.dumps(payload), capture_output=True,
                           text=True, env=e, cwd=cwd or self.repo)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, '')
        if event == 'Stop':
            self.assertTrue(r.stdout.strip(), 'a Stop hook must always print JSON (Codex rejects empty output)')
        out = json.loads(r.stdout) if r.stdout.strip() else None
        return out or None

    def ctx_of(self, out):
        return out['hookSpecificOutput']['additionalContext'] if out else ''

    def cli(self, *args, env=None):
        e = dict(self.env, **(env or {}))
        return subprocess.run([sys.executable, J, *args], capture_output=True, text=True, env=e, cwd=self.repo).stdout

    def jfile(self, name, title='x', pointer='none'):
        p = os.path.join(self.jdir, name)
        open(p, 'w').write(JOURNAL.format(title=title, pointer=pointer))
        return p

    def lease(self, sid):
        return json.load(open(os.path.join(self.state, 'leases', sid + '.json')))

    def write_journal(self, sid, tr, name, cwd=None, text=None, env=None, post=False):
        """Agent writes a journal: PreToolUse (may deny) -> write -> PostToolUse. Returns the deny reason (or the
        PostToolUse context when post=True)."""
        path = os.path.join(cwd or self.repo, self.jrel, name)
        ti = {'file_path': path, 'content': text or JOURNAL.format(title=name, pointer='none')}
        d = self.hook('PreToolUse', sid, cwd=cwd, env=env, tool_name='Write', tool_input=ti, transcript_path=tr.path)
        if d and d['hookSpecificOutput']['permissionDecision'] == 'deny':
            tr.tool('Write', **ti)
            tr.error(d['hookSpecificOutput']['permissionDecisionReason'])
            return d['hookSpecificOutput']['permissionDecisionReason']
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, 'w').write(ti['content'])
        tr.tool('Write', **ti)
        out = self.hook('PostToolUse', sid, cwd=cwd, env=env, tool_name='Write', tool_input=ti, transcript_path=tr.path)
        return self.ctx_of(out) if post else None

    def stop(self, sid, tr, **kw):
        return self.hook('Stop', sid, transcript_path=tr.path, stop_hook_active=kw.pop('active', False), **kw)

    def edit(self, tr, name='x.py'):
        tr.tool('Edit', file_path=os.path.join(self.repo, name), old_string='a', new_string='b')


class SessionBinding(Lab):
    def test_parallel_sessions_get_their_own_journal_not_newest(self):
        """v1 named the newest journal: a parallel session's fresh journal silenced this session's nudge."""
        ta, tb = Transcript(os.path.join(self.tmp, 'a.jsonl')), Transcript(os.path.join(self.tmp, 'b.jsonl'))
        self.hook('SessionStart', 'aaaaaaaa-1', source='startup', transcript_path=ta.path)
        self.hook('SessionStart', 'bbbbbbbb-1', source='startup', transcript_path=tb.path)
        ta.human('fix parser bug')
        self.assertIsNone(self.write_journal('aaaaaaaa-1', ta, '2026-01-08-1000-parser-bug.md'))
        tb.human('write the user guide')
        self.assertIsNone(self.write_journal('bbbbbbbb-1', tb, '2026-01-08-1005-user-guide.md'))
        ta.human('now patch it')
        self.edit(ta)
        ta.tool('Bash', command='git commit -am fix')
        d = self.stop('aaaaaaaa-1', ta)
        self.assertEqual(d['decision'], 'block')
        self.assertIn('2026-01-08-1000-parser-bug.md', d['reason'])
        self.assertNotIn('user-guide', d['reason'])

    def test_append_to_journal_owned_by_live_session_is_denied(self):
        ta, tb = Transcript(os.path.join(self.tmp, 'a.jsonl')), Transcript(os.path.join(self.tmp, 'b.jsonl'))
        self.hook('SessionStart', 'aaaaaaaa-2', source='startup', transcript_path=ta.path)
        ta.human('x')
        self.write_journal('aaaaaaaa-2', ta, '2026-01-08-1100-search-survey.md')
        ctx = self.ctx_of(self.hook('SessionStart', 'bbbbbbbb-2', source='startup', transcript_path=tb.path))
        self.assertIn('IN USE by live session aaaaaaaa', ctx)
        tb.human('unrelated question')
        reason = self.write_journal('bbbbbbbb-2', tb, '2026-01-08-1100-search-survey.md')
        self.assertIn('in use by live session aaaaaaaa', reason)
        self.assertIn('Continues', reason)
        self.hook('SessionEnd', 'aaaaaaaa-2', reason='prompt_input_exit')
        self.assertIsNone(self.write_journal('bbbbbbbb-2', tb, '2026-01-08-1100-search-survey.md'))

    def test_resume_and_compact_rebind_same_journal(self):
        t = Transcript(os.path.join(self.tmp, 'c.jsonl'))
        self.hook('SessionStart', '44444444-9', source='startup', transcript_path=t.path)
        t.human('go')
        self.write_journal('44444444-9', t, '2026-01-08-1800-long.md')
        for src in ('compact', 'resume'):
            ctx = self.ctx_of(self.hook('SessionStart', '44444444-9', source=src, transcript_path=t.path))
            self.assertIn('bound to', ctx)
            self.assertIn('2026-01-08-1800-long.md', ctx)

    def test_bash_journal_write_counts_and_binds(self):
        t = Transcript(os.path.join(self.tmp, 'b.jsonl'))
        self.hook('SessionStart', '33333333-8', source='startup', transcript_path=t.path)
        self.jfile('2026-01-08-1700-bash.md')
        t.human('go')
        self.edit(t, 'a.py')
        t.tool('Bash', command=f"cat >> {self.jdir}/2026-01-08-1700-bash.md <<'EOF'\n- 17:05 - patched a.py\nEOF")
        t.tool('Bash', command='git commit -am z')
        self.assertIsNone(self.stop('33333333-8', t))
        self.assertEqual(self.lease('33333333-8')['journal'], '2026-01-08-1700-bash.md')

    def test_variable_path_bash_write_is_detected(self):
        t = Transcript(os.path.join(self.tmp, 'v.jsonl'))
        self.hook('SessionStart', '77777777-c', source='startup', transcript_path=t.path)
        t.human('implement mul')
        self.edit(t, 'm.py')
        t.tool('Bash', command='git commit -am mul')
        cmd = f'F=$M/{self.jrel}/$(date +%Y)-mul.md; cat > $F <<EOF ... EOF'
        self.hook('PreToolUse', '77777777-c', tool_name='Bash', tool_input={'command': cmd}, tool_use_id='tu1',
                  transcript_path=t.path)
        self.jfile('2026-01-08-2000-mul.md', title='mul')
        t.tool('Bash', command=cmd)
        self.hook('PostToolUse', '77777777-c', tool_name='Bash', tool_input={'command': cmd}, tool_use_id='tu1',
                  transcript_path=t.path)
        self.assertIsNone(self.stop('77777777-c', t))
        self.assertIn('2026-01-08-2000-mul.md', self.cli('list'))

    def test_journal_name_without_hhmm_binds(self):
        t = Transcript(os.path.join(self.tmp, 'h.jsonl'))
        self.hook('SessionStart', 'bbbb1111-x', source='startup', transcript_path=t.path)
        t.human('mine usage examples')
        self.assertIsNone(self.write_journal('bbbb1111-x', t, '2026-01-04-usage-examples.md'))
        self.assertIn('2026-01-04-usage-examples.md', self.cli('list'))

    def test_python_reading_an_in_use_journal_is_not_denied(self):
        ta = Transcript(os.path.join(self.tmp, 'pa.jsonl'))
        self.hook('SessionStart', '7c7c7c7c-a', source='startup', transcript_path=ta.path)
        ta.human('x')
        self.write_journal('7c7c7c7c-a', ta, '2026-01-08-1200-live.md')
        cmd = f"python3 - <<'EOF'\nt = open('{self.jrel}/2026-01-08-1200-live.md').read()\nopen('/tmp/r.txt', 'w').write(t)\nEOF"
        self.assertIsNone(self.hook('PreToolUse', '7c7c7c7c-b', tool_name='Bash', tool_input={'command': cmd},
                                    tool_use_id='u1'))
        w = f"python3 -c \"open('{self.jrel}/2026-01-08-1200-live.md', 'a').write('x')\""
        d = self.hook('PreToolUse', '7c7c7c7c-b', tool_name='Bash', tool_input={'command': w}, tool_use_id='u2')
        self.assertEqual(d['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_a_journal_path_inside_someone_elses_command_is_not_ours(self):
        """Seen live: editing a test fixture whose heredoc mentions `> "$TARGET/sessions/<date>-x.md"` was denied to
        a worker. A path that visibly points elsewhere, or a variable path to a journal that does not exist here, is
        not a write into this journal directory."""
        env = {'JOURNAL_ROLE': 'worker'}
        for cmd in (f"python3 - <<'EOF'\ns = 'printf x > \"$TARGET/{self.jrel}/2026-01-02-0304-leak.md\"'\nEOF",
                    f"cat > /elsewhere/{self.jrel}/2026-01-02-0304-x.md <<'EOF'\nx\nEOF",
                    f"cd /tmp && echo x > other/{self.jrel}/2026-01-02-0304-x.md"):
            self.assertIsNone(self.hook('PreToolUse', 'f9f9f9f9-1', env=env, tool_name='Bash',
                                        tool_input={'command': cmd}, tool_use_id='u'), cmd)
        self.jfile('2026-01-02-0304-real.md')
        for cmd in (f'echo x >> "$ROOT/{self.jrel}/2026-01-02-0304-real.md"',
                    f'echo x >> {self.jrel}/2026-01-02-0304-new.md',
                    f'echo x >> {self.jdir}/2026-01-02-0304-new.md'):
            d = self.hook('PreToolUse', 'f9f9f9f9-1', env=env, tool_name='Bash', tool_input={'command': cmd},
                          tool_use_id='u')
            self.assertEqual(d['hookSpecificOutput']['permissionDecision'], 'deny', cmd)

    def test_live_agent_process_keeps_an_idle_journal_in_use(self):
        t = Transcript(os.path.join(self.tmp, 'i.jsonl'))
        self.hook('SessionStart', '8d8d8d8d-a', env={'CLAUDE_PID': str(os.getpid())}, source='startup',
                  transcript_path=t.path)
        t.human('x')
        self.write_journal('8d8d8d8d-a', t, '2026-01-08-1300-idle.md')
        p = os.path.join(self.state, 'leases', '8d8d8d8d-a.json')
        l = json.load(open(p))
        l['heartbeat'] = time.time() - 3 * 3600
        json.dump(l, open(p, 'w'))
        tb = Transcript(os.path.join(self.tmp, 'ib.jsonl'))
        self.assertIn('in use', self.write_journal('8d8d8d8d-b', tb, '2026-01-08-1300-idle.md'))
        l['pid'] = 999999
        json.dump(l, open(p, 'w'))
        self.assertIsNone(self.write_journal('8d8d8d8d-b', tb, '2026-01-08-1300-idle.md'))

    def test_whoami_and_bound_use_the_callers_session_id(self):
        t = Transcript(os.path.join(self.tmp, 'q.jsonl'))
        self.hook('SessionStart', '1234abcd-ffff', source='startup', transcript_path=t.path)
        t.human('x')
        self.write_journal('1234abcd-ffff', t, '2026-01-08-2300-q.md')
        env = {'CLAUDE_CODE_SESSION_ID': '1234abcd-ffff'}
        self.assertIn('2026-01-08-2300-q.md', self.cli('whoami', env=env))
        self.assertTrue(self.cli('bound', env=env).strip().endswith(f'{self.jrel}/2026-01-08-2300-q.md'))

    def test_bind_cli_resolves_prefix(self):
        self.hook('SessionStart', '88888888-dddd', source='startup')
        self.jfile('2026-01-08-2100-p.md')
        self.cli('bind', '88888888', '2026-01-08-2100-p.md')
        leases = sorted(x for x in os.listdir(os.path.join(self.state, 'leases')) if x.endswith('.json'))
        self.assertEqual(leases, ['88888888-dddd.json'])
        self.assertEqual(self.lease('88888888-dddd')['journal'], '2026-01-08-2100-p.md')

    def test_state_directory_ignores_itself(self):
        self.hook('SessionStart', 'abcd0000-1', source='startup')
        self.assertEqual(open(os.path.join(self.state, '.gitignore')).read(), '*\n')
        self.assertNotIn('.claude', sh('git', 'status', '--porcelain', '--untracked-files=all', cwd=self.repo))


class Nudges(Lab):
    def test_readonly_turn_never_nudged_and_marker_does_not_leak(self):
        """v1: the loop marker survived the stop_hook_active exit and silenced the NEXT turn."""
        t = Transcript(os.path.join(self.tmp, 'r.jsonl'))
        self.hook('SessionStart', '11111111-6', source='startup', transcript_path=t.path)
        t.human('hello')
        t.say('hi')
        self.assertIsNone(self.stop('11111111-6', t))
        t.human('do work')
        self.write_journal('11111111-6', t, '2026-01-08-1500-work.md')
        t.human('commit it')
        t.tool('Bash', command='git commit -am x')
        self.assertEqual(self.stop('11111111-6', t)['decision'], 'block')
        self.assertIsNone(self.stop('11111111-6', t, active=True))
        t.human('commit more')
        t.tool('Bash', command='git commit -am y')
        d = self.stop('11111111-6', t)
        self.assertIsNotNone(d, 'the previous turn must not suppress this one')
        self.assertEqual(d['decision'], 'block')

    def test_debounce_reduces_nudge_loops(self):
        env = {'JOURNAL_LANDING_BASH': r'\bdispatch-tool send\b'}
        t = Transcript(os.path.join(self.tmp, 'd.jsonl'))
        self.hook('SessionStart', '22222222-7', env=env, source='startup', transcript_path=t.path)
        t.human('start')
        self.write_journal('22222222-7', t, '2026-01-08-1600-coord.md', env=env)
        t.human('dispatch worker 1')
        t.tool('Bash', command='dispatch-tool send w1 "go"')
        self.assertIsNone(self.hook('Stop', '22222222-7', env=env, transcript_path=t.path, stop_hook_active=False),
                          'one unjournaled landed turn within 20 min is debounced')
        t.human('dispatch worker 2')
        t.tool('Bash', command='dispatch-tool send w2 "go"')
        d = self.hook('Stop', '22222222-7', env=env, transcript_path=t.path, stop_hook_active=False)
        self.assertEqual(d['decision'], 'block', 'the second unjournaled landed turn nudges')

    def test_counter_counts_a_turn_once_across_stop_rounds(self):
        t = Transcript(os.path.join(self.tmp, 'n.jsonl'))
        self.hook('SessionStart', '5a5a5a5a-1', source='startup', transcript_path=t.path)
        t.human('start')
        self.write_journal('5a5a5a5a-1', t, '2026-01-08-0800-n.md')
        t.human('edit')
        self.edit(t, 'n.py')
        self.assertIsNone(self.stop('5a5a5a5a-1', t, prompt_id='p-1'))
        self.assertIsNone(self.stop('5a5a5a5a-1', t, prompt_id='p-1', active=True), 'another hook blocked; same turn')
        self.assertEqual(self.lease('5a5a5a5a-1')['unjournaled_turns'], 1)

    def test_journal_written_in_a_readonly_turn_resets_the_counter(self):
        t = Transcript(os.path.join(self.tmp, 'z.jsonl'))
        self.hook('SessionStart', '6b6b6b6b-1', source='startup', transcript_path=t.path)
        t.human('start')
        self.write_journal('6b6b6b6b-1', t, '2026-01-08-0810-z.md')
        t.human('edit')
        self.edit(t, 'z.py')
        self.assertIsNone(self.stop('6b6b6b6b-1', t))
        t.human('note it')
        self.write_journal('6b6b6b6b-1', t, '2026-01-08-0810-z.md')
        self.assertIsNone(self.stop('6b6b6b6b-1', t))
        t.human('edit again')
        self.edit(t, 'z.py')
        self.assertIsNone(self.stop('6b6b6b6b-1', t))

    def test_blocking_stop_hook_rounds_nudge_at_most_once_per_prompt(self):
        """Another Stop hook that blocks creates more Stop rounds in the same prompt."""
        t = Transcript(os.path.join(self.tmp, 'g.jsonl'))
        sid = '7c7c7c7c-1'
        self.hook('SessionStart', sid, source='startup', transcript_path=t.path)
        t.human('start')
        self.write_journal(sid, t, '2026-01-10-1100-gate.md')
        t.human('ship the fix')
        self.edit(t, 'fix.py')
        t.tool('Bash', command='git commit -am fix')
        rounds = [self.stop(sid, t, prompt_id='p-9')]
        self.edit(t, 'board.md')
        rounds.append(self.stop(sid, t, prompt_id='p-9', active=True))
        rounds.append(self.stop(sid, t, prompt_id='p-9', active=True))
        rounds.append(self.stop(sid, t, prompt_id='p-9'))       # a client that does not set stop_hook_active
        self.assertEqual(sum(1 for r in rounds if r and r.get('decision') == 'block'), 1, rounds)
        self.assertEqual(self.lease(sid)['unjournaled_turns'], 1)
        t.human('next')
        self.edit(t, 'fix.py')
        t.tool('Bash', command='git commit -am fix2')
        self.assertEqual(self.stop(sid, t, prompt_id='p-10')['decision'], 'block', 'a new prompt can be nudged')

    def test_thin_journal_gets_a_one_line_nudge_naming_the_plan(self):
        plan = 'docs/plans/release.md'
        t = Transcript(os.path.join(self.tmp, 'um.jsonl'))
        sid = '8d8d8d8d-1'
        self.hook('SessionStart', sid, source='startup', transcript_path=t.path)
        t.human('release work')
        self.write_journal(sid, t, '2026-01-10-1200-release.md', text=JOURNAL.format(title='release', pointer=plan))
        t.human('update the plan')
        self.edit(t, plan)
        t.tool('Bash', command=f'git commit -m "release plan v2" -- {plan}')
        d = self.stop(sid, t, prompt_id='um-1')
        self.assertEqual(d['decision'], 'block')
        self.assertNotIn('\n', d['reason'])
        self.assertIn('THIN', d['reason'])
        self.assertIn(plan, d['reason'])
        self.assertIn('one milestone line', d['reason'])
        t2 = Transcript(os.path.join(self.tmp, 'um2.jsonl'))
        sid2 = '8d8d8d8d-2'
        self.hook('SessionStart', sid2, source='startup', transcript_path=t2.path)
        t2.human('start')
        self.write_journal(sid2, t2, '2026-01-10-1210-detail.md')
        t2.human('edit')
        self.edit(t2)
        t2.tool('Bash', command='git commit -am x')
        self.assertIn('DETAILED', self.stop(sid2, t2, prompt_id='um-2')['reason'])

    def test_denied_journal_write_does_not_count_as_a_journal_update(self):
        ta, tb = Transcript(os.path.join(self.tmp, 'da.jsonl')), Transcript(os.path.join(self.tmp, 'db.jsonl'))
        self.hook('SessionStart', '9e9e0000-a', source='startup', transcript_path=ta.path)
        self.hook('SessionStart', '9e9e0000-b', source='startup', transcript_path=tb.path)
        ta.human('own it')
        self.write_journal('9e9e0000-a', ta, '2026-01-10-1300-owned.md')
        tb.human('continue owned work')
        self.assertIn('in use', self.write_journal('9e9e0000-b', tb, '2026-01-10-1300-owned.md'))
        self.edit(tb, 'y.py')
        tb.tool('Bash', command='git commit -am y')
        d = self.stop('9e9e0000-b', tb, prompt_id='b-1')
        self.assertIsNotNone(d)
        self.assertIn('no journal yet', d['reason'])
        self.assertIsNone(self.lease('9e9e0000-b').get('journal'))

    def test_skip_env_and_skip_cli_silence_nudges(self):
        t = Transcript(os.path.join(self.tmp, 's.jsonl'))
        self.hook('SessionStart', 'abab1111-1', source='startup', transcript_path=t.path)
        t.human('bump a dependency')
        self.edit(t, 'deps.txt')
        t.tool('Bash', command='git commit -am bump')
        self.assertIsNone(self.hook('Stop', 'abab1111-1', env={'SESSION_JOURNAL_SKIP': '1'},
                                    transcript_path=t.path, stop_hook_active=False))
        self.cli('skip', 'abab1111')
        t.human('again')
        self.edit(t, 'deps.txt')
        t.tool('Bash', command='git commit -am bump2')
        self.assertIsNone(self.stop('abab1111-1', t))

    def test_oversized_journal_is_flagged_once(self):
        t = Transcript(os.path.join(self.tmp, 'big.jsonl'))
        self.hook('SessionStart', 'b1b1b1b1-1', source='startup', transcript_path=t.path)
        t.human('long work')
        big = JOURNAL.format(title='big', pointer='none') + ('- milestone line\n' * 3000)
        note = self.write_journal('b1b1b1b1-1', t, '2026-01-11-0900-big.md', text=big, post=True)
        self.assertIn('Continues', note)
        self.assertEqual(self.write_journal('b1b1b1b1-1', t, '2026-01-11-0900-big.md', text=big, post=True), '')
        ctx = self.ctx_of(self.hook('SessionStart', 'b2b2b2b2-1', source='startup'))
        self.assertIn('IN USE', ctx)
        self.hook('SessionEnd', 'b1b1b1b1-1', reason='other', env={'JOURNAL_PAUSE_ON_END': '0'})
        out = self.cli('candidates')
        self.assertIn('continue it in a new journal with Continues:', out)


class SpinePromotion(Lab):
    """Ported from the 1.x shell extra, which judged the newest journal and blocked on every Stop."""

    def detailed(self, name, milestones, pointer='none'):
        body = JOURNAL.format(title=name, pointer=pointer).replace(
            '- 10:00 - opened\n', ''.join(f'- milestone {i}\n' for i in range(milestones)))
        return body

    def turn(self, sid, t, name, milestones, env, pointer='none', prompt='p'):
        t.human('work')
        self.write_journal(sid, t, name, env=env, text=self.detailed(name, milestones, pointer))
        self.edit(t)
        return self.hook('Stop', sid, env=env, transcript_path=t.path, stop_hook_active=False, prompt_id=prompt)

    def test_off_by_default(self):
        t = Transcript(os.path.join(self.tmp, 's0.jsonl'))
        self.hook('SessionStart', '5e5e0000-1', source='startup', transcript_path=t.path)
        self.assertIsNone(self.turn('5e5e0000-1', t, '2026-01-13-0900-long.md', 9, {}))

    def test_detailed_journal_at_threshold_is_asked_once(self):
        env = {'SPINE_PROMOTION_THRESHOLD': '6'}
        t = Transcript(os.path.join(self.tmp, 's1.jsonl'))
        self.hook('SessionStart', '5e5e0000-2', env=env, source='startup', transcript_path=t.path)
        self.assertIsNone(self.turn('5e5e0000-2', t, '2026-01-13-0900-long.md', 5, env, prompt='a'), 'below threshold')
        d = self.turn('5e5e0000-2', t, '2026-01-13-0900-long.md', 6, env, prompt='b')
        self.assertEqual(d['decision'], 'block')
        self.assertIn('6 milestones', d['reason'])
        self.assertIn('docs/plans/', d['reason'])
        self.assertIsNone(self.hook('Stop', '5e5e0000-2', env=env, transcript_path=t.path, stop_hook_active=True,
                                    prompt_id='b'))
        self.assertIsNone(self.turn('5e5e0000-2', t, '2026-01-13-0900-long.md', 9, env, prompt='c'), 'once per journal')

    def test_thin_journal_is_never_asked(self):
        env = {'SPINE_PROMOTION_THRESHOLD': '2'}
        t = Transcript(os.path.join(self.tmp, 's2.jsonl'))
        self.hook('SessionStart', '5e5e0000-3', env=env, source='startup', transcript_path=t.path)
        self.assertIsNone(self.turn('5e5e0000-3', t, '2026-01-13-0901-thin.md', 9, env, pointer='docs/plans/x.md'))

    def test_judges_this_sessions_journal_not_the_newest(self):
        env = {'SPINE_PROMOTION_THRESHOLD': '3', 'SPINE_PROMOTION_TARGET_HINT': 'specs/'}
        p = self.jfile('2026-01-13-1000-someone-elses.md')
        open(p, 'w').write(self.detailed('other', 20))
        os.utime(p, (time.time() + 60,) * 2)               # the newest file belongs to nobody in this session
        t = Transcript(os.path.join(self.tmp, 's3.jsonl'))
        self.hook('SessionStart', '5e5e0000-4', env=env, source='startup', transcript_path=t.path)
        self.assertIsNone(self.turn('5e5e0000-4', t, '2026-01-13-0902-mine.md', 2, env, prompt='a'))
        d = self.turn('5e5e0000-4', t, '2026-01-13-0902-mine.md', 3, env, prompt='b')
        self.assertIn('2026-01-13-0902-mine.md', d['reason'])
        self.assertIn('specs/', d['reason'])
        self.assertNotIn('someone-elses', d['reason'])

    def test_title_cased_headings_are_recognised(self):
        env = {'SPINE_PROMOTION_THRESHOLD': '3'}
        t = Transcript(os.path.join(self.tmp, 's4.jsonl'))
        self.hook('SessionStart', '5e5e0000-5', env=env, source='startup', transcript_path=t.path)
        t.human('work')
        text = self.detailed('cased', 4, pointer='docs/plans/x.md').replace('## Live plan pointer', '## Live Plan Pointer')
        self.write_journal('5e5e0000-5', t, '2026-01-13-0903-cased.md', env=env, text=text)
        self.edit(t)
        self.assertIsNone(self.hook('Stop', '5e5e0000-5', env=env, transcript_path=t.path, stop_hook_active=False))
        text = self.detailed('cased', 4).replace('## Milestones', '## MILESTONES')
        t.human('more')
        self.write_journal('5e5e0000-5', t, '2026-01-13-0903-cased.md', env=env, text=text)
        self.edit(t)
        d = self.hook('Stop', '5e5e0000-5', env=env, transcript_path=t.path, stop_hook_active=False)
        self.assertIn('4 milestones', d['reason'])


class Lifecycle(Lab):
    def test_session_end_pauses_and_records_session_then_reconstruct(self):
        t = Transcript(os.path.join(self.tmp, '55555555-aa.jsonl'))
        self.hook('SessionStart', '55555555-aa', source='startup', transcript_path=t.path)
        t.human('investigate the flaky upload test')
        self.write_journal('55555555-aa', t, '2026-01-08-1900-flaky-upload.md')
        t.tool('Bash', command='git commit -m "fix: retry timeout"')
        t.say('Root cause: the retry timeout was shorter than the server timeout.')
        self.hook('SessionEnd', '55555555-aa', reason='prompt_input_exit')
        text = open(os.path.join(self.jdir, '2026-01-08-1900-flaky-upload.md')).read()
        self.assertIn('**Sessions:**', text)
        self.assertIn('55555555', text)
        self.assertIn('PAUSED', text)
        out = self.cli('reconstruct', '2026-01-08-1900-flaky-upload.md')
        self.assertIn('investigate the flaky upload test', out)
        self.assertIn('retry timeout', out)
        p = self.jfile('2026-01-09-0900-flaky-upload-2.md', title='follow-up')
        open(p, 'a').write(f'\n**Continues:** {self.jrel}/2026-01-08-1900-flaky-upload.md\n')
        self.assertIn('2026-01-09-0900-flaky-upload-2.md', self.cli('reconstruct', '2026-01-08-1900-flaky-upload.md'))
        self.assertIn('flaky-upload', self.cli('find', 'flaky', 'upload'))

    def test_a_committed_journal_is_not_edited_after_the_session_ends(self):
        """Live Claude run: a session that committed everything left its journal modified by SessionEnd."""
        name = '2026-01-08-1920-clean.md'
        t = Transcript(os.path.join(self.tmp, 'cl.jsonl'))
        self.hook('SessionStart', 'c0c0c0c0-1', source='startup', transcript_path=t.path)
        t.human('x')
        self.write_journal('c0c0c0c0-1', t, name)
        sh('git', 'add', '-A', cwd=self.repo)
        sh('git', 'commit', '-qm', 'work and journal', cwd=self.repo)
        before = open(os.path.join(self.jdir, name)).read()
        self.hook('SessionEnd', 'c0c0c0c0-1', reason='other')
        self.assertEqual(open(os.path.join(self.jdir, name)).read(), before)
        self.assertEqual(sh('git', 'status', '--porcelain', cwd=self.repo), '')
        self.assertIn(f'{name} [PAUSED (session ended)]', self.cli('candidates'))
        # The next session that changes the journal anyway carries the pending line when it ends.
        t2 = Transcript(os.path.join(self.tmp, 'cl2.jsonl'))
        self.hook('SessionStart', 'c1c1c1c1-2', source='startup', transcript_path=t2.path)
        t2.human('continue')
        self.write_journal('c1c1c1c1-2', t2, name, text=before.replace('- working', '- working further'))
        self.assertNotIn('PAUSED (session ended)', self.cli('candidates'), 'a later write supersedes the pending pause')
        self.hook('SessionEnd', 'c1c1c1c1-2', reason='other')
        text = open(os.path.join(self.jdir, name)).read()
        self.assertIn('c0c0c0c0', text)
        self.assertIn('c1c1c1c1', text)
        self.assertIn('**Status:** PAUSED', text)
        self.assertNotIn('stamp_pending', json.dumps(self.lease('c0c0c0c0-1')))

    def test_sweep_applies_pending_stamps(self):
        name = '2026-01-08-1930-swept.md'
        t = Transcript(os.path.join(self.tmp, 'sw.jsonl'))
        self.hook('SessionStart', 'c2c2c2c2-1', source='startup', transcript_path=t.path)
        t.human('x')
        self.write_journal('c2c2c2c2-1', t, name)
        sh('git', 'add', '-A', cwd=self.repo)
        sh('git', 'commit', '-qm', 'j', cwd=self.repo)
        self.hook('SessionEnd', 'c2c2c2c2-1', reason='other')
        self.assertIn(f'would stamp {self.jrel}/{name}', self.cli('sweep', '--dry-run'))
        self.assertIn('**Status:** ACTIVE', open(os.path.join(self.jdir, name)).read())
        self.cli('sweep')
        text = open(os.path.join(self.jdir, name)).read()
        self.assertIn('**Status:** PAUSED', text)
        self.assertIn('c2c2c2c2', text)

    def test_pause_on_end_can_be_turned_off(self):
        t = Transcript(os.path.join(self.tmp, 'pe.jsonl'))
        self.hook('SessionStart', '5c5c5c5c-1', source='startup', transcript_path=t.path)
        t.human('x')
        self.write_journal('5c5c5c5c-1', t, '2026-01-08-1910-keep.md')
        self.hook('SessionEnd', '5c5c5c5c-1', reason='other', env={'JOURNAL_PAUSE_ON_END': '0'})
        text = open(os.path.join(self.jdir, '2026-01-08-1910-keep.md')).read()
        self.assertIn('**Status:** ACTIVE', text)
        self.assertIn('5c5c5c5c', text)

    def test_clear_starts_new_session_that_is_offered_the_windows_journal(self):
        """/clear gives a NEW session id; the window's journal is offered first and is free."""
        env = {'CLAUDE_PID': str(os.getpid())}
        ta = Transcript(os.path.join(self.tmp, 'ca.jsonl'))
        self.hook('SessionStart', 'c1c1c1c1-a', env=env, source='startup', transcript_path=ta.path)
        ta.human('cutover')
        self.write_journal('c1c1c1c1-a', ta, '2026-01-08-0900-cutover.md', env=env)
        for i in range(6):
            self.jfile(f'2026-01-08-10{i}0-other-{i}.md', title=f'other {i}')
        self.hook('SessionEnd', 'c1c1c1c1-a', env=env, reason='clear')
        text = open(os.path.join(self.jdir, '2026-01-08-0900-cutover.md')).read()
        self.assertIn('ACTIVE', text)
        self.assertIn('c1c1c1c1', text)
        ctx = self.ctx_of(self.hook('SessionStart', 'c2c2c2c2-b', env=env, source='clear'))
        self.assertIn('You ran /clear', ctx)
        first_candidate = ctx.split('Candidates', 1)[1].splitlines()[1]
        self.assertIn('2026-01-08-0900-cutover.md', first_candidate)
        tb = Transcript(os.path.join(self.tmp, 'cb.jsonl'))
        tb.human('carry on')
        self.assertIsNone(self.write_journal('c2c2c2c2-b', tb, '2026-01-08-0900-cutover.md', env=env))

    def test_fork_does_not_inherit_the_parents_journal(self):
        ta = Transcript(os.path.join(self.tmp, 'fa.jsonl'), t0=time.time() - 600)
        self.hook('SessionStart', 'f0f0f0f0-a', source='startup', transcript_path=ta.path)
        ta.human('survey')
        self.write_journal('f0f0f0f0-a', ta, '2026-01-08-1100-survey.md')
        tb = Transcript(os.path.join(self.tmp, 'fb.jsonl'), t0=time.time() + 5)
        with open(tb.path, 'w') as fh:
            fh.write(open(ta.path).read())          # a fork's transcript starts with the parent's history
        ctx = self.ctx_of(self.hook('SessionStart', 'f1f1f1f1-b', source='fork', transcript_path=tb.path))
        self.assertIn('fork', ctx)
        self.assertIn('2026-01-08-1100-survey.md', ctx)
        tb.human('branch off: try the other fix')
        self.edit(tb, 'f.py')
        d = self.stop('f1f1f1f1-b', tb)
        self.assertIn('no journal yet', d['reason'])
        self.assertIsNone(self.lease('f1f1f1f1-b')['journal'])
        self.assertIn('in use', self.write_journal('f1f1f1f1-b', tb, '2026-01-08-1100-survey.md'))

    def test_health_and_sweep(self):
        p = self.jfile('2026-01-01-0900-abandoned.md', title='abandoned')
        text = open(p).read()
        open(p, 'w').write(text.replace('2026-01-08 10:00 UTC', '2026-01-01 09:00 UTC'))
        os.utime(p, (time.time() - 400 * 86400,) * 2)
        h = json.loads(self.cli('health'))
        self.assertEqual(h['stale_active_7d'], 1)
        self.assertEqual(h['version'], open(os.path.join(ROOT, 'VERSION')).read().strip())
        self.assertIn('would pause', self.cli('sweep', '24', '--dry-run'))
        self.assertIn('ACTIVE', open(p).read())
        self.cli('sweep', '24')
        self.assertIn('PAUSED (auto: idle', open(p).read())

    def test_sweep_by_git_uses_commit_dates_not_checkout_mtimes(self):
        p = self.jfile('2025-08-01-0900-old.md', title='old')
        old = '2025-08-01T09:00:00+00:00'
        sh('git', 'add', self.jrel, cwd=self.repo)
        sh('git', 'commit', '-qm', 'old journal', cwd=self.repo,
           env=dict(self.env, GIT_AUTHOR_DATE=old, GIT_COMMITTER_DATE=old))
        text = open(p).read().replace('2026-01-08 10:00 UTC', '2025-08-01 09:00 UTC')
        open(p, 'w').write(text)
        sh('git', 'commit', '-qam', 'hdr', cwd=self.repo, env=dict(self.env, GIT_AUTHOR_DATE=old, GIT_COMMITTER_DATE=old))
        self.assertIn('sweep: 0 changes', self.cli('sweep', '168'), 'a fresh checkout mtime hides the idle journal')
        self.assertIn(f'would pause {self.jrel}/2025-08-01-0900-old.md', self.cli('sweep', '168', '--by-git', '--dry-run'))
        self.cli('sweep', '168', '--by-git')
        self.assertIn('PAUSED (auto: idle >168h)', open(p).read())

    def test_sweep_by_git_refuses_when_git_log_fails(self):
        self.jfile('2026-01-01-0900-old.md')
        sh('git', 'add', self.jrel, cwd=self.repo)
        sh('git', 'commit', '-qm', 'j', cwd=self.repo)
        spec = importlib.util.spec_from_file_location('journal_under_test', J)
        jm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(jm)
        real = jm.git
        jm.git = lambda *a, **k: '' if a and a[0] == 'log' else real(*a, **k)
        old_env = dict(os.environ)
        os.environ.clear()
        os.environ.update(self.env)
        try:
            ctx = jm.Ctx(self.repo)
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = jm.cmd_sweep(ctx, ['168', '--by-git', '--dry-run'])
        finally:
            os.environ.clear()
            os.environ.update(old_env)
        self.assertNotEqual(rc, 0, buf.getvalue())
        self.assertIn('git log', buf.getvalue())


class Candidates(Lab):
    def test_candidates_rank_worktree_and_skip_done(self):
        def rewrite(path, a, b):
            text = open(path).read()
            open(path, 'w').write(text.replace(a, b))
        rewrite(self.jfile('2026-01-01-0900-old-done.md', title='old'), 'ACTIVE', 'DONE')
        rewrite(self.jfile('2026-01-02-0900-feature-wip.md', title='feature wip'), '**Status:**',
                '**Worktree:** wt-feature\n**Status:**')
        self.jfile('2026-01-03-0900-main-newer.md', title='main newer')
        ctx = self.ctx_of(self.hook('SessionStart', '66666666-b', cwd=self.wt, env={'CLAUDE_PROJECT_DIR': self.wt},
                                    source='startup'))
        self.assertNotIn('old-done', ctx)
        self.assertLess(ctx.index('feature-wip'), ctx.index('main-newer'))

    def test_candidates_rank_dirty_journal_first(self):
        p = self.jfile('2026-01-03-0900-current.md', title='current')
        text = open(p).read()
        open(p, 'w').write(text.replace('**Status:** ACTIVE', '**Status:** IN PROGRESS'))
        self.jfile('2026-01-04-0900-other.md', title='other')
        sh('git', 'add', self.jrel, cwd=self.repo)
        sh('git', 'commit', '-qm', 'j', cwd=self.repo)
        open(p, 'a').write('\n- more\n')
        out = self.cli('candidates')
        self.assertIn('current.md [IN PROGRESS]', out)
        self.assertLess(out.index('current.md'), out.index('other.md'))

    def test_open_journals_with_free_form_status_are_candidates(self):
        for name, status in (('2026-01-08-0000-board.md', 'IN PROGRESS (handoff)'),
                             ('2026-01-08-0100-wait.md', 'WAITING on review'),
                             ('2026-01-08-0200-done.md', 'DONE'), ('2026-01-08-0300-complete.md', 'COMPLETE')):
            p = self.jfile(name, title=name)
            text = open(p).read()
            open(p, 'w').write(text.replace('**Status:** ACTIVE', '**Status:** ' + status))
        out = self.cli('candidates')
        self.assertIn('board.md [IN PROGRESS (handoff)]', out)
        self.assertIn('wait.md [WAITING on review]', out)
        self.assertNotIn('done.md', out)
        self.assertNotIn('complete.md', out)

    def test_candidates_cli_filters_by_words_and_marks_in_use(self):
        plan = 'release-train-plan'
        self.jfile('2026-01-01-0900-rt-old.md', title='release train old', pointer=f'docs/{plan}.md')
        self.jfile('2026-01-09-0900-unrelated.md', title='user guide')
        ta = Transcript(os.path.join(self.tmp, 'ca.jsonl'))
        self.hook('SessionStart', 'cdcd0000-a', source='startup', transcript_path=ta.path)
        ta.human('release train')
        self.write_journal('cdcd0000-a', ta, '2026-01-10-0800-rt-live.md',
                           text=JOURNAL.format(title='rt live', pointer=f'docs/{plan}.md'))
        out = self.cli('candidates', plan, env={'CLAUDE_CODE_SESSION_ID': 'eeee0000-b'})
        self.assertIn('2026-01-01-0900-rt-old.md', out)
        self.assertIn('2026-01-10-0800-rt-live.md', out)
        self.assertNotIn('unrelated', out)
        self.assertRegex(out, r'rt-live\.md \[IN USE by live session cdcd0000')
        mine = self.cli('candidates', plan, env={'CLAUDE_CODE_SESSION_ID': 'cdcd0000-a'})
        self.assertTrue(mine.startswith(f'bound: {self.jrel}/2026-01-10-0800-rt-live.md'), mine)

    def test_first_prompt_adds_matching_journals_beyond_the_startup_list(self):
        p = self.jfile('2025-12-01-0900-search-index-migration.md', title='search index migration')
        os.utime(p, (time.time() - 30 * 86400,) * 2)
        for i in range(30):
            self.jfile(f'2026-01-0{i % 9 + 1}-09{i:02d}-unrelated-topic-{i}.md', title=f'unrelated {i}')
        ctx = self.ctx_of(self.hook('SessionStart', '9e9e9e9e-a', source='startup'))
        self.assertNotIn('search-index', ctx)
        out = self.ctx_of(self.hook('UserPromptSubmit', '9e9e9e9e-a', prompt='continue the search index migration'))
        self.assertIn('2025-12-01-0900-search-index-migration.md', out)


class Worktrees(Lab):
    def test_worktree_session_writes_journal_in_main_checkout(self):
        t = Transcript(os.path.join(self.tmp, 'w.jsonl'))
        env = {'CLAUDE_PROJECT_DIR': self.wt}
        ctx = self.ctx_of(self.hook('SessionStart', 'cccccccc-3', cwd=self.wt, env=env, source='startup',
                                    transcript_path=t.path))
        self.assertIn(os.path.realpath(self.jdir), ctx.replace(self.repo, os.path.realpath(self.repo)))
        self.assertIn("worktree 'wt-feature'", ctx)
        self.assertIn('**Worktree:** wt-feature (feature)', ctx)
        t.human('feature work')
        reason = self.write_journal('cccccccc-3', t, '2026-01-08-1200-feature.md', cwd=self.wt, env=env)
        self.assertIn('main checkout', reason)
        ti = {'file_path': os.path.join(self.jdir, '2026-01-08-1200-feature.md'), 'content': 'x'}
        self.assertIsNone(self.hook('PreToolUse', 'cccccccc-3', cwd=self.wt, env=env, tool_name='Write', tool_input=ti))
        lease = self.lease('cccccccc-3')
        self.assertEqual((lease['worktree'], lease['branch']), ('wt-feature', 'feature'))
        self.assertFalse(os.path.exists(os.path.join(self.wt, '.claude')), 'no state in the linked worktree')

    def test_pooled_worktree_is_named_by_its_branch(self):
        """Pooled worktrees are often checked out as <pool>/<n>/<repo-name>: the basename says nothing."""
        self.jfile('2026-01-01-0000-old.md', title='old work')
        sh('git', 'add', self.jrel, cwd=self.repo)
        sh('git', 'commit', '-qm', 'old', cwd=self.repo)
        slot = os.path.join(self.tmp, 'pool', '1', 'repo')
        os.makedirs(os.path.dirname(slot))
        sh('git', 'worktree', 'add', '-q', '-b', 'w/gap', slot, cwd=self.repo)
        env = {'CLAUDE_PROJECT_DIR': slot}
        t = Transcript(os.path.join(self.tmp, 'th.jsonl'))
        ctx = self.ctx_of(self.hook('SessionStart', 'dede0000-1', cwd=slot, env=env, source='startup',
                                    transcript_path=t.path))
        self.assertIn('**Worktree:** w/gap (w/gap)', ctx)
        t.human('implement the gap')
        text = JOURNAL.format(title='gap', pointer='none').replace('**Status:** ACTIVE',
                                                                  '**Status:** ACTIVE\n**Worktree:** w/gap (w/gap)')
        self.assertIsNone(self.write_journal('dede0000-1', t, '2026-01-10-0900-gap.md', cwd=self.repo, env=env, text=text))
        self.hook('SessionEnd', 'dede0000-1', cwd=slot, env=env, reason='other')
        body = open(os.path.join(self.jdir, '2026-01-10-0900-gap.md')).read()
        self.assertIn('dede0000 (w/gap/w/gap', body)
        self.assertEqual(sorted(os.listdir(os.path.join(slot, self.jrel))), ['2026-01-01-0000-old.md'])
        self.assertFalse(os.path.exists(os.path.join(slot, '.claude')))

    def test_hooks_anchor_on_project_dir_not_on_cwd(self):
        """A hook's cwd follows the agent's `cd`; journals and state must stay with the session's project."""
        other = os.path.join(self.tmp, 'other-repo')
        os.makedirs(other)
        sh('git', 'init', '-q', '-b', 'main', cwd=other)
        env = {'CLAUDE_PROJECT_DIR': self.repo}
        t = Transcript(os.path.join(self.tmp, 'o.jsonl'))
        self.hook('SessionStart', 'abab0000-1', env=env, source='startup', transcript_path=t.path)
        t.human('fix helper')
        t.tool('Edit', file_path=os.path.join(other, 'helper.sh'), old_string='a', new_string='b')
        t.tool('Bash', command='git commit -am helper')
        d = self.hook('Stop', 'abab0000-1', cwd=other, env=env, transcript_path=t.path, stop_hook_active=False)
        self.assertIn(self.jdir, d['reason'])
        self.hook('PreToolUse', 'abab0000-1', cwd=other, env=env, tool_name='Bash',
                  tool_input={'command': f'ls {self.jrel}/'})
        self.assertFalse(os.path.exists(os.path.join(other, self.jrel)))
        self.assertFalse(os.path.exists(os.path.join(other, '.claude')))
        self.assertTrue(os.path.exists(os.path.join(self.state, 'leases', 'abab0000-1.json')))

    def test_repo_without_journal_dir_is_left_alone(self):
        bare = os.path.join(self.tmp, 'plain')
        os.makedirs(bare)
        sh('git', 'init', '-q', cwd=bare)
        env = {'CLAUDE_PROJECT_DIR': bare}
        self.assertIsNone(self.hook('SessionStart', 'acac0000-1', cwd=bare, env=env, source='startup'))
        self.assertIsNone(self.hook('Stop', 'acac0000-1', cwd=bare, env=env, stop_hook_active=False))
        self.assertEqual(sorted(os.listdir(bare)), ['.git'])

    def test_journal_file_in_another_repository_is_not_ours(self):
        other = os.path.join(self.tmp, 'elsewhere')
        os.makedirs(os.path.join(other, self.jrel))
        sh('git', 'init', '-q', cwd=other)
        ti = {'file_path': os.path.join(other, self.jrel, '2026-01-08-1200-x.md'), 'content': 'x'}
        self.assertIsNone(self.hook('PreToolUse', 'a0a0a0a0-1', tool_name='Write', tool_input=ti))


class Workers(Lab):
    def test_worker_results_reach_the_lead_and_find(self):
        tl, tw = Transcript(os.path.join(self.tmp, 'l.jsonl')), Transcript(os.path.join(self.tmp, 'w.jsonl'))
        self.hook('SessionStart', '99999999-lead', source='startup', transcript_path=tl.path)
        tl.human('coordinate')
        self.write_journal('99999999-lead', tl, '2026-01-08-2200-coord.md')
        env = {'JOURNAL_ROLE': 'worker'}
        self.hook('SessionStart', 'aaaa0000-wrk', env=env, source='startup', transcript_path=tw.path)
        tw.human('add divide()')
        self.edit(tw, 'src/calc.py')
        tw.tool('Bash', command='git commit -am "Add divide"')
        tw.say('divide() added with ValueError on zero; tests pass.')
        self.assertIsNone(self.hook('Stop', 'aaaa0000-wrk', env=env, transcript_path=tw.path, stop_hook_active=False))
        out = self.ctx_of(self.hook('UserPromptSubmit', '99999999-lead', prompt='status?'))
        self.assertIn('worker aaaa0000', out)
        self.assertIn('divide', out)
        self.assertIsNone(self.hook('UserPromptSubmit', '99999999-lead', prompt='again'), 'shown once')
        self.assertIn('Worker ledger', self.cli('find', 'divide'))

    def test_dispatch_prompt_worker_is_soft_env_worker_is_hard(self):
        rx = {'JOURNAL_WORKER_PROMPT': r'Read \S+task\.md and follow it exactly'}
        t = Transcript(os.path.join(self.tmp, 'k.jsonl'))
        self.hook('SessionStart', 'dddddddd-4', env=rx, source='startup', transcript_path=t.path)
        out = self.ctx_of(self.hook('UserPromptSubmit', 'dddddddd-4', env=rx,
                                    prompt='Read /x/tasks/T1/task.md and follow it exactly.'))
        self.assertIn('WORKER', out)
        t.human('Read /x/tasks/T1/task.md and follow it exactly.')
        self.edit(t, 'guide.md')
        t.tool('Bash', command='git commit -am guide')
        self.assertIsNone(self.hook('Stop', 'dddddddd-4', env=rx, transcript_path=t.path, stop_hook_active=False))
        self.assertIsNone(self.write_journal('dddddddd-4', t, '2026-01-08-1300-deliverable.md', env=rx),
                          'a soft worker may keep the journal its task asks for')
        self.hook('SessionStart', 'dddddddd-5', env=rx, source='startup')
        self.assertIsNone(self.hook('UserPromptSubmit', 'dddddddd-5', env=rx,
                                    prompt='about /x/tasks/T1/task.md: what changes for the operator?'))
        self.assertEqual(self.lease('dddddddd-5')['role'], 'lead')
        te = Transcript(os.path.join(self.tmp, 'e.jsonl'))
        env = {'JOURNAL_ROLE': 'worker'}
        self.assertIn('WORKER', self.ctx_of(self.hook('SessionStart', 'eeeeeeee-4', env=env, source='startup',
                                                      transcript_path=te.path)))
        te.human('x')
        self.assertIn('worker', self.write_journal('eeeeeeee-4', te, '2026-01-08-1301-noise.md', env=env))
        self.cli('role', 'lead', env={'CLAUDE_CODE_SESSION_ID': 'eeeeeeee-4'})
        self.assertIsNone(self.write_journal('eeeeeeee-4', te, '2026-01-08-1301-noise.md', env=env))

    def test_no_worker_heuristic_without_configuration(self):
        self.hook('SessionStart', 'dddd0000-6', source='startup')
        self.assertIsNone(self.hook('UserPromptSubmit', 'dddd0000-6', prompt='Read /x/task.md and follow it exactly.'))
        self.assertEqual(self.lease('dddd0000-6')['role'], 'lead')


class Secrets(Lab):
    LEAK = ('api_key = ' + 'sk-' + 'live4eC39HqLyjWDarjtT1zdp7dc')

    def test_credential_write_is_denied_without_echoing_the_value(self):
        t = Transcript(os.path.join(self.tmp, 's.jsonl'))
        self.hook('SessionStart', 'ffffffff-5', source='startup', transcript_path=t.path)
        t.human('storage')
        key = 'DefaultEndpointsProtocol=https;AccountName=demo;AccountKey=' + 'A' * 86 + '=='
        for body, kind in ((key, 'azure-storage-key'), ('dbPassword=Dr@gon5ly164', 'secret-assignment'),
                           ('The staging database password is Hunter2Secret!x so', 'password-prose'),
                           (self.LEAK, 'api-key')):
            reason = self.write_journal('ffffffff-5', t, '2026-01-08-1400-store.md',
                                        text=JOURNAL.format(title='b', pointer='none') + body)
            self.assertIn('credential', reason or '', body)
            self.assertIn(kind, reason)
            for fragment in ('AAAA', 'Dr@gon', 'Hunter2', 'live4eC'):
                self.assertNotIn(fragment, reason)
        self.assertFalse(os.path.exists(os.path.join(self.jdir, '2026-01-08-1400-store.md')))

    def test_redactions_and_references_are_accepted(self):
        t = Transcript(os.path.join(self.tmp, 's.jsonl'))
        self.hook('SessionStart', 'fefefefe-5', source='startup', transcript_path=t.path)
        t.human('storage')
        for benign in ('password: <redacted>', 'token: $API_TOKEN', 'client_secret: ${CLIENT_SECRET}',
                       'api_key: stored-in-ci-secrets', 'password: redacted (32 chars)', 'secretName: app-secret',
                       'ingress.tls.secret=default/wildcard-cert', 'adminPassword: mandatory',
                       'Cipher: Secret AES_128_CBC', 'commit 0123456789abcdef0123456789abcdef01234567',
                       'sha256 9991e0b2903da4c8f6122b5c3186448b927a5da4deef1fe45271c3793f4ee29c',
                       'api_key: sk-live-...', 'Authorization: Bearer <token>',
                       self.LEAK + ' <!-- journal-secrets-ok -->'):
            self.assertIsNone(self.write_journal('fefefefe-5', t, '2026-01-08-1400-ok.md',
                                                 text=JOURNAL.format(title='b', pointer='none') + benign), benign)

    def test_bash_heredoc_with_a_credential_is_denied(self):
        cmd = f"cat >> {self.jrel}/2026-01-08-1400-x.md <<'EOF'\n{self.LEAK}\nEOF"
        d = self.hook('PreToolUse', 'f1f1f1f1-1', tool_name='Bash', tool_input={'command': cmd}, tool_use_id='u')
        self.assertEqual(d['hookSpecificOutput']['permissionDecision'], 'deny')

    def test_warn_mode_is_advisory(self):
        env = {'JOURNAL_SECRETS': 'warn'}
        t = Transcript(os.path.join(self.tmp, 'w.jsonl'))
        self.hook('SessionStart', 'f2f2f2f2-1', env=env, source='startup', transcript_path=t.path)
        t.human('x')
        note = self.write_journal('f2f2f2f2-1', t, '2026-01-08-1400-w.md', env=env, post=True,
                                  text=JOURNAL.format(title='w', pointer='none') + self.LEAK)
        self.assertIn('credential', note)
        self.assertNotIn('live4eC', note)
        self.assertTrue(os.path.exists(os.path.join(self.jdir, '2026-01-08-1400-w.md')))

    def test_scan_cli_reports_lines_not_values(self):
        self.jfile('2026-01-08-1500-clean.md')
        p = self.jfile('2026-01-08-1501-leak.md')
        open(p, 'a').write(self.LEAK + '\n')
        r = subprocess.run([sys.executable, J, 'scan'], capture_output=True, text=True, env=self.env, cwd=self.repo)
        self.assertEqual(r.returncode, 1)
        self.assertIn('2026-01-08-1501-leak.md', r.stdout)
        self.assertNotIn('clean.md', r.stdout)
        self.assertNotIn('live4eC', r.stdout)


class Codex(Lab):
    """Codex sends turn_id, uses apply_patch with tool_input.command, and has a rollout transcript the Claude parser
    does not read: the hooks record their own turn facts."""

    def codex(self, event, sid, **inp):
        inp.setdefault('transcript_path', os.path.join(self.tmp, 'rollout.jsonl'))
        return self.hook(event, sid, model='gpt-test', **inp)

    def patch(self, path, body='+x'):
        return f'*** Begin Patch\n*** Add File: {path}\n{body}\n*** End Patch\n'

    def test_codex_turn_with_an_edit_and_no_journal_is_nudged_once(self):
        open(os.path.join(self.tmp, 'rollout.jsonl'), 'w').write('{"type":"session_meta","payload":{}}\n')
        self.codex('SessionStart', 'thr_1', source='startup')
        self.codex('UserPromptSubmit', 'thr_1', turn_id='turn-1', prompt='add a feature')
        cmd = self.patch('src/feature.py')
        self.assertIsNone(self.codex('PreToolUse', 'thr_1', turn_id='turn-1', tool_name='apply_patch',
                                     tool_input={'command': cmd}, tool_use_id='c1'))
        self.codex('PostToolUse', 'thr_1', turn_id='turn-1', tool_name='apply_patch', tool_input={'command': cmd},
                   tool_use_id='c1')
        d = self.codex('Stop', 'thr_1', turn_id='turn-1', stop_hook_active=False)
        self.assertEqual(d['decision'], 'block')
        self.assertIn('no journal yet', d['reason'])
        self.assertIsNone(self.codex('Stop', 'thr_1', turn_id='turn-1', stop_hook_active=True))
        journal = self.patch(f'{self.jrel}/2026-01-12-0900-feature.md', '+' + JOURNAL.replace('\n', '\n+').format(
            title='feature', pointer='none'))
        self.codex('PreToolUse', 'thr_1', turn_id='turn-1', tool_name='apply_patch', tool_input={'command': journal},
                   tool_use_id='c2')
        os.makedirs(self.jdir, exist_ok=True)
        open(os.path.join(self.jdir, '2026-01-12-0900-feature.md'), 'w').write('x')
        self.codex('PostToolUse', 'thr_1', turn_id='turn-1', tool_name='apply_patch', tool_input={'command': journal},
                   tool_use_id='c2')
        self.assertEqual(self.lease('thr_1')['journal'], '2026-01-12-0900-feature.md')
        self.codex('UserPromptSubmit', 'thr_1', turn_id='turn-2', prompt='what does it do?')
        self.assertIsNone(self.codex('Stop', 'thr_1', turn_id='turn-2', stop_hook_active=False), 'read-only turn')
        self.codex('UserPromptSubmit', 'thr_1', turn_id='turn-3', prompt='commit')
        self.codex('PostToolUse', 'thr_1', turn_id='turn-3', tool_name='Bash', tool_input={'command': 'git commit -am f'},
                   tool_use_id='c3')
        d = self.codex('Stop', 'thr_1', turn_id='turn-3', stop_hook_active=False)
        self.assertIn('2026-01-12-0900-feature.md', d['reason'])

    def test_codex_apply_patch_into_an_in_use_journal_is_denied(self):
        t = Transcript(os.path.join(self.tmp, 'a.jsonl'))
        self.hook('SessionStart', 'aaaa2222-1', source='startup', transcript_path=t.path)
        t.human('x')
        self.write_journal('aaaa2222-1', t, '2026-01-12-1000-owned.md')
        cmd = '*** Begin Patch\n*** Update File: ' + f'{self.jrel}/2026-01-12-1000-owned.md\n@@\n+more\n*** End Patch\n'
        d = self.codex('PreToolUse', 'thr_2', turn_id='turn-1', tool_name='apply_patch', tool_input={'command': cmd},
                       tool_use_id='c1')
        self.assertEqual(d['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertIn('in use', d['hookSpecificOutput']['permissionDecisionReason'])

    def test_codex_session_end_reason_other_pauses(self):
        self.codex('SessionStart', 'thr_3', source='startup')
        self.codex('UserPromptSubmit', 'thr_3', turn_id='t1', prompt='x')
        p = self.jfile('2026-01-12-1100-c.md')
        cmd = '*** Begin Patch\n*** Update File: ' + f'{self.jrel}/2026-01-12-1100-c.md\n@@\n+more\n*** End Patch\n'
        self.codex('PostToolUse', 'thr_3', turn_id='t1', tool_name='apply_patch', tool_input={'command': cmd},
                   tool_use_id='c1')
        self.codex('SessionEnd', 'thr_3', reason='other')
        text = open(p).read()
        self.assertIn('PAUSED', text)
        self.assertIn('thr_3', text)
        self.assertIn('codex', text)


class CustomDirectory(SessionBinding):
    """Every session-binding scenario again with the journal directory under docs/."""
    jrel = 'docs/sessions'


class Robustness(Lab):
    def test_hook_never_crashes_on_garbage(self):
        for ev in ('Stop', 'PreToolUse', 'PostToolUse', 'SessionStart', 'UserPromptSubmit', 'SessionEnd', 'Nope'):
            for payload in ('not json', '[]', '{"tool_input": "str"}', ''):
                r = subprocess.run([sys.executable, J, 'hook', ev], input=payload, capture_output=True, text=True,
                                   cwd=self.repo, env=self.env)
                self.assertEqual(r.returncode, 0, (ev, payload, r.stderr))
                if ev == 'Stop':
                    json.loads(r.stdout)

    def test_disable_switch(self):
        r = subprocess.run([sys.executable, J, 'hook', 'SessionStart'], input='{"session_id":"x"}', capture_output=True,
                           text=True, cwd=self.repo, env=dict(self.env, SESSION_JOURNAL_DISABLE='1'))
        self.assertEqual(r.stdout, '')
        self.assertFalse(os.path.exists(self.state))

    def test_version_matches_the_release(self):
        self.assertEqual(self.cli('version').strip(), open(os.path.join(ROOT, 'VERSION')).read().strip())

    def test_unrelated_tool_calls_take_the_fast_path(self):
        r = subprocess.run([sys.executable, J, 'hook', 'PreToolUse'], capture_output=True, text=True, cwd=self.repo,
                           env=self.env, input=json.dumps({'session_id': 's', 'tool_name': 'Read',
                                                           'tool_input': {'file_path': '/etc/hosts'}}))
        self.assertEqual((r.returncode, r.stdout), (0, ''))
        self.assertFalse(os.path.exists(self.state), 'no state touched for a call that cannot matter')


if __name__ == '__main__':
    unittest.main()
