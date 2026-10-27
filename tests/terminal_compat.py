"""Stock tmux -> Kitty native VT parser integration, without desktop windows.

kitty +runpy 'import runpy; runpy.run_path("tests/terminal_compat.py", run_name="__main__")'
Uses an isolated socket and Neovim instance; does not touch active sessions.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

from kitty.fast_data_types import Screen

ROOT = Path(__file__).resolve().parent.parent
SAMPLE = '| 濁点 | 結合文字の濁点を基底文字から分断しません。 | が / ｶﾞ / ﾊﾟ |'


class TerminalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='inkstone-terminal-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.socket = str(self.root / 'tmux.sock')
        self.nvim_socket = str(self.root / 'nvim.sock')
        self.env = os.environ.copy()
        for key in ('TMUX', 'TMUX_PANE'):
            self.env.pop(key, None)
        self.env.update(TERM='xterm-kitty', LC_ALL='C.UTF-8')
        self.tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-x', '120', '-y', '24',
                  'nvim', '--clean', '-n', '-i', 'NONE', '--listen', self.nvim_socket)
        self.addCleanup(lambda: self.tmux('kill-server'))
        self.tmux('set-option', '-g', 'status', 'off')
        self.screen = Screen(None, 24, 120, 100)
        self.output = bytearray()
        pid, self.fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 120, 0, 0))
            os.execvpe('tmux', ['tmux', '-S', self.socket, 'attach', '-t', 'test'], self.env)
        self.pid = pid
        self.addCleanup(self.close_terminal)
        self.pump(0.15)
        os.write(self.fd, b'\x1bP>|kitty(0.49.2)\x1b\\')
        self.pump(0.15)

    def close_terminal(self):
        os.kill(self.pid, signal.SIGTERM)
        os.waitpid(self.pid, 0)
        os.close(self.fd)

    def tmux(self, *args):
        return subprocess.check_output(['tmux', '-S', self.socket, *args], env=self.env, stderr=subprocess.PIPE).decode().strip()

    def lua(self, body):
        expression = 'execute(' + json.dumps('lua ' + body, ensure_ascii=False) + ')'
        return subprocess.check_output(['nvim', '--server', self.nvim_socket, '--remote-expr', expression],
                                       env=self.env, stderr=subprocess.PIPE).decode().strip()

    def pump(self, duration=0.15):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.fd], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            data = os.read(self.fd, 65536)
            if not data:
                raise RuntimeError('tmux client exited')
            self.output.extend(data)
            while data:
                used = self.screen.test_commit_write_buffer(data, self.screen.test_create_write_buffer())
                self.screen.test_parse_written_data()
                data = data[used:]

    def render(self, lines, cell='trimmed', wrap=False, enabled=True):
        self.lines = lines
        body = 'vim.opt.rtp:prepend(' + json.dumps(str(ROOT)) + '); '
        body += "require('inkstone').setup({anti_conceal={enabled=false}, display_compat={enabled="
        body += str(enabled).lower() + "}, pipe_table={cell='" + cell + "',wrap=" + str(wrap).lower()
        body += "}, code={sign=false}, win_options={conceallevel={default=0,rendered=2}}}); "
        body += 'vim.api.nvim_buf_set_lines(0,0,-1,false,vim.json.decode('
        body += json.dumps(json.dumps(lines, ensure_ascii=False), ensure_ascii=False) + ')); '
        body += "vim.bo.filetype='markdown'; vim.treesitter.start(0,'markdown'); vim.api.nvim_win_set_cursor(0,{1,0}); "
        body += "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
        body += "vim.wait(1000,function() local ui=require('inkstone.core.ui'); local d=ui.cache[vim.api.nvim_get_current_buf()]; return d and d.n>0 end); vim.cmd('redraw!')"
        self.lua(body)
        self.pump()

    def visible_text(self):
        return '\n'.join(str(self.screen.line(row)) for row in range(24))

    def assert_source(self):
        result = self.lua("print(vim.json.encode(vim.api.nvim_buf_get_lines(0,0,-1,false)))")
        self.assertEqual(json.loads(result), self.lines)

    def assert_table(self, aligned=True):
        text = self.visible_text()
        self.assertIn('ガ', text)
        self.assertIn('パ', text)
        self.assertNotIn('ｶﾞ', text)
        rows = []
        for row in range(24):
            bars = [col for col, cell in enumerate(self.screen.cpu_cells(row)) if cell['text'] == '│']
            if len(bars) >= 3:
                rows.append(bars)
        self.assertGreaterEqual(len(rows), 2, text)
        if aligned:
            self.assertTrue(all(row == rows[0] for row in rows), rows)
        else:
            # raw/overlay intentionally preserve source column positions.
            width = int(self.lua('print(vim.fn.strdisplaywidth(' + json.dumps(SAMPLE, ensure_ascii=False) + '))'))
            self.assertEqual(rows[-1][-1], width - 1)
        self.assert_source()

    def test_tables_and_redraw(self):
        for cell in ('padded', 'trimmed', 'raw', 'overlay'):
            with self.subTest(cell=cell):
                self.render(['BEFORE', '', '| 項目 | 説明 | 内容 |', '| --- | --- | --- |', SAMPLE, '', 'AFTER'], cell)
                self.assert_table(cell in ('padded', 'trimmed'))
                self.tmux('refresh-client')
                self.pump()
                self.assert_table(cell in ('padded', 'trimmed'))
        self.assertNotIn(b'\x1b]66;', self.output)

    def test_wrapped_virtual_rows(self):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 54, 0, 0))
        self.screen.resize(24, 54)
        os.kill(self.pid, signal.SIGWINCH)
        self.pump()
        self.render(['BEFORE', '', '| 項目 | 説明 | 内容 |', '| --- | --- | --- |', SAMPLE, '', 'AFTER'], wrap=True)
        self.assert_table()

    def test_plain_text_and_disable(self):
        source = 'prefix ｶﾞ / ﾊﾟ / ｳﾞ / ｱﾞ / ｶﾟ suffix|'
        self.render(['BEFORE', source, 'AFTER'])
        self.assertIn('prefix ガ / パ / ヴ / ア゙ / カ゚ suffix|', self.visible_text())
        self.assert_source()
        self.lua("vim.api.nvim_win_set_cursor(0,{2,0}); vim.cmd('normal! \"zyy'); print(vim.json.encode(vim.fn.getreg('z')))")
        copied = self.lua("print(vim.json.encode(vim.fn.getreg('z')))")
        self.assertEqual(json.loads(copied), source + '\n')
        self.render(['BEFORE', source, 'AFTER'], enabled=False)
        self.assertIn(source, self.visible_text())
        self.assert_source()


if __name__ == '__main__':
    unittest.main(argv=[str(__file__)], verbosity=2)
