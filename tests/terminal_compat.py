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
import shutil
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
        identity = b'kitty(0.39.0)' if self._testMethodName == 'test_old_kitty_keeps_native_text' else b'kitty(0.49.2)'
        os.write(self.fd, b'\x1bP>|' + identity + b'\x1b\\')
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
            # The native parser has no PTY response callback. Supply its known
            # XTVERSION identity when an application probes the real protocol.
            if b'\x1b[>0q' in data:
                response = b'\x1bP>|' + getattr(self, 'terminal_version', b'kitty(0.49.2)')
                if getattr(self, 'fragment_response', False):
                    os.write(self.fd, response[:6])
                    time.sleep(.03)
                    os.write(self.fd, response[6:])
                    time.sleep(.03)
                    os.write(self.fd, b'\x1b\\')
                else:
                    os.write(self.fd, response + b'\x1b\\')
            observer = getattr(self, 'frame_observer', None)
            chunks = (bytes((byte,)) for byte in data) if observer else (data,)
            for part in chunks:
                chunk = part
                while chunk:
                    used = self.screen.test_commit_write_buffer(chunk, self.screen.test_create_write_buffer())
                    self.screen.test_parse_written_data()
                    chunk = chunk[used:]
                if observer:
                    self.frame_tail = (getattr(self, 'frame_tail', b'') + part)[-8:]
                    if self.frame_tail.endswith((b'\x1b[?2026l', b'\x1bP=2s\x1b\\')):
                        observer()

    def render(self, lines, cell='trimmed', wrap=False, enabled=True, conceallevel=2, anti_conceal=False):
        self.lines = lines
        body = 'vim.opt.rtp:prepend(' + json.dumps(str(ROOT)) + '); '
        body += "require('inkstone').setup({anti_conceal={enabled=" + str(anti_conceal).lower() + "}, display_compat={enabled="
        body += str(enabled).lower() + "}, pipe_table={cell='" + cell + "',wrap=" + str(wrap).lower()
        body += "}, code={sign=false}, win_options={conceallevel={default=0,rendered=" + str(conceallevel) + "}}}); "
        body += 'vim.api.nvim_buf_set_lines(0,0,-1,false,vim.json.decode('
        body += json.dumps(json.dumps(lines, ensure_ascii=False), ensure_ascii=False) + ')); '
        body += "vim.bo.filetype='markdown'; vim.treesitter.start(0,'markdown'); vim.api.nvim_win_set_cursor(0,{1,0}); "
        body += "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
        body += "vim.wait(1000,function() local ui=require('inkstone.core.ui'); local d=ui.cache[vim.api.nvim_get_current_buf()]; return d and d.n>0 end); vim.cmd('redraw!')"
        self.lua(body)
        self.pump()

    def visible_text(self):
        return '\n'.join(str(self.screen.line(row)) for row in range(24))

    def scaled_text(self):
        return '\n'.join(''.join(cell['text'] for cell in self.screen.cpu_cells(row)
                                  if cell.get('mcd') and cell['x'] == 0 and cell['y'] == 0)
                          for row in range(24))

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

    def test_acp_indented_table(self):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 60, 0, 0))
        self.screen.resize(24, 60)
        os.kill(self.pid, signal.SIGWINCH)
        self.pump()
        self.render([
            'BEFORE', '',
            ' | 比較対象 | Inkstone の状況 |',
            ' |---|---|',
            ' | [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim#features) | ベースの主要機能は継承。上流の最新変更すべてとの一致は未確認 |',
            ' | [markview.nvim](https://github.com/OXY2DEV/markview.nvim#-complete-feature-list) | 基本描画は広く対応。HTML の標準装飾、絵文字略記・文字参照、Obsidian タグ、Typst／AsciiDoc などで差がある |',
            ' | [md-render.nvim](https://github.com/delphinus/md-render.nvim#highlights) | 通常段落の日本語折り返し、画像・動画、Mermaid／PlantUML、操作できる折りたたみが未対応 |',
            '', 'AFTER',
        ], wrap=True, conceallevel=3)
        bars = []
        for row in range(24):
            cols = [col for col, cell in enumerate(self.screen.cpu_cells(row)) if cell['text'] in ('│', '┌', '┬', '┐', '├', '┼', '┤', '└', '┴', '┘')]
            if len(cols) == 3:
                bars.append(cols)
        self.assertGreater(len(bars), 4, self.visible_text())
        self.assertTrue(all(row == bars[0] for row in bars), (bars, self.visible_text()))
        self.assert_source()

    def test_paragraph_reflow_and_cursor_restore(self):
        self.render(['BEFORE', '', ' 日本語の**段落**を', ' 文節で折り返します。  ', ' English words follow.', '', 'AFTER'], conceallevel=3, anti_conceal=True)
        text = self.visible_text()
        self.assertIn('日本語の段落を文節で折り返します。', text)
        self.assertNotIn('**', text)
        self.assertIn(' English words follow.', text)
        self.lua("vim.api.nvim_win_set_cursor(0,{4,0}); require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100); vim.cmd('redraw!')")
        self.pump()
        self.assertIn('日本語の', self.visible_text())
        self.assertNotIn('日本語の段落を文節で折り返します。', self.visible_text())
        self.assert_source()
        self.lua("vim.api.nvim_win_set_cursor(0,{1,0}); require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100); vim.cmd('redraw!')")
        self.pump()
        self.assertIn('日本語の段落を文節で折り返します。', self.visible_text())

    def test_wrapped_table_cursor_edit_and_restore(self):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 60, 0, 0))
        self.screen.resize(24, 60)
        os.kill(self.pid, signal.SIGWINCH)
        self.pump()
        for anti_conceal in (False, True):
            with self.subTest(anti_conceal=anti_conceal):
                self.render(['BEFORE', '', '| A | B |', '| - | - |',
                             '| [label](https://example.org/' + 'long-path/' * 10 + ') | 日本語の説明を折り返して表示します。 |',
                             '| short | cell |', '', 'AFTER'], wrap=True, conceallevel=3, anti_conceal=anti_conceal)
                before = self.visible_text()
                self.assertIn('│', before)
                self.assertNotIn('https://example.org/', before)
                for row, col in ((5, 0), (5, 80), (6, 0)):
                    self.lua('vim.api.nvim_win_set_cursor(0,{' + str(row) + ',' + str(col) + '}); '
                             "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100); vim.cmd('redraw!')")
                    self.pump()
                    text = self.visible_text()
                    if anti_conceal:
                        self.assertIn('| A | B |', text)
                        self.assertNotIn('│', text)
                        self.assertNotIn('┌', text)
                    else:
                        self.assertIn('│', text)
                        self.assertNotIn('https://example.org/', text)
                    self.assert_source()
                self.lua("vim.api.nvim_win_set_cursor(0,{5,20}); vim.api.nvim_buf_set_text(0,4,20,4,20,{'changed-'}); "
                         "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100); vim.cmd('redraw!')")
                self.lines[4] = self.lines[4][:20] + 'changed-' + self.lines[4][20:]
                self.pump()
                if anti_conceal:
                    self.assertNotIn('│', self.visible_text())
                else:
                    self.assertIn('│', self.visible_text())
                self.assert_source()
                self.lua("vim.api.nvim_win_set_cursor(0,{1,0}); require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
                         "vim.wait(100); vim.cmd('normal! ggzt'); vim.cmd('redraw!')")
                self.pump()
                self.assertIn('│', self.visible_text())
                self.assertNotIn('long-path/', self.visible_text())
                self.assert_source()

    def test_details_callout_and_code_folds(self):
        self.render(['BEFORE', '', '<details>', '<summary>Details title</summary>', '', 'Secret detail body', '', '</details>', '',
                     '> [!NOTE]- Note', '> Secret callout body', '', '```lua', 'print("Code body")', '```', '', 'AFTER'], conceallevel=3)
        text = self.visible_text()
        self.assertIn('Details title', text)
        self.assertNotIn('Secret detail body', text)
        self.assertNotIn('Secret callout body', text)
        self.assertIn('Code body', text)
        self.lua("vim.api.nvim_win_set_cursor(0,{3,0}); require('inkstone.api').toggle_fold(); vim.wait(100); vim.cmd('redraw!')")
        self.pump()
        self.assertIn('Secret detail body', self.visible_text())
        self.lua("vim.api.nvim_win_set_cursor(0,{13,0}); require('inkstone.api').toggle_fold(); vim.wait(100); vim.cmd('redraw!')")
        self.pump()
        self.assertNotIn('Code body', self.visible_text())
        self.assert_source()

    def test_table_list_and_chart_toggles(self):
        self.render(['BEFORE', '', '| Name | Before | After |', '| - | - | - |',
                     '| Alpha | 20ms | 10ms |', '| Beta | 30ms | 15ms |', '', 'AFTER'], wrap=True)
        self.lua("vim.api.nvim_win_set_cursor(0,{5,0}); require('inkstone.api').toggle_list(); vim.wait(150); vim.cmd('redraw!')")
        self.pump()
        text = self.visible_text()
        self.assertIn('Table · list', text)
        self.assertIn('• Name', text)
        self.assertIn('Alpha', text)
        self.assertNotIn('| Name |', text)
        self.assertNotIn('│', text)
        self.assert_source()
        self.lua("vim.api.nvim_win_set_cursor(0,{5,0}); require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
                 "vim.wait(100); vim.cmd('redraw!')")
        self.pump()
        self.assertIn('Table · list', self.visible_text())
        self.assertIn('• Name', self.visible_text())
        self.lua("require('inkstone.state').get(vim.api.nvim_get_current_buf()).anti_conceal={enabled=true,above=0,below=0,disabled_modes={}}; "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100); vim.cmd('redraw!')")
        self.pump()
        self.assertIn('| Name | Before | After |', self.visible_text())
        self.assertNotIn('Table · list', self.visible_text())
        self.assertNotIn('• Name', self.visible_text())
        self.lua("require('inkstone.state').get(vim.api.nvim_get_current_buf()).anti_conceal.enabled=false; "
                 "vim.api.nvim_win_set_cursor(0,{3,0}); require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100)")
        self.lua("require('inkstone.api').toggle_chart(); vim.wait(150); vim.cmd('redraw!')")
        self.pump()
        text = self.visible_text()
        self.assertIn('Table · chart', text)
        self.assertIn('█', text)
        self.assertNotIn('• Name', text)
        self.lua("require('inkstone.api').toggle_chart(); vim.api.nvim_win_set_cursor(0,{1,0}); "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150); vim.cmd('redraw!')")
        self.pump()
        self.assertIn('│', self.visible_text())
        self.assert_source()

    def test_sized_text_preserves_theme_colors_backgrounds_and_inline_styles(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# HEAD *ITALIC* [LINK](https://example.org)', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.core.colors').init(); "
                 "vim.api.nvim_set_hl(0,'@markup.heading.1.markdown',{fg=0x112233,bold=true}); "
                 "vim.api.nvim_set_hl(0,'InkstoneH1Bg',{bg=0x223344}); "
                 "vim.api.nvim_set_hl(0,'@markup.italic.markdown_inline',{italic=true}); "
                 "vim.api.nvim_set_hl(0,'InkstoneLink',{fg=0x445566,underline=true}); "
                 "vim.api.nvim_set_hl(0,'@markup.link.label.markdown_inline',{link='InkstoneLink'}); "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150)")
        self.pump(.2)

        def style(text):
            for row in range(24):
                leads = [(col, cell) for col, cell in enumerate(self.screen.cpu_cells(row))
                         if cell.get('mcd') and cell['x'] == 0 and cell['y'] == 0]
                offset = ''.join(cell['text'] for _, cell in leads).find(text)
                if offset < 0:
                    continue
                for col, cell in leads:
                    if offset < len(cell['text']):
                        return self.screen.line(row).cursor_from(col)
                    offset -= len(cell['text'])
            self.fail('Missing sized text: ' + text)

        head = style('HEAD')
        self.assertEqual(head.fg, (0x112233 << 8) | 2)
        self.assertEqual(head.bg, (0x223344 << 8) | 2)
        self.assertTrue(head.bold)
        self.assertTrue(style('ITALIC').italic)
        link = style('LINK')
        self.assertEqual(link.fg, (0x445566 << 8) | 2)
        self.assertEqual(link.decoration, 1)
        self.lua("vim.api.nvim_set_hl(0,'@markup.heading.1.markdown',{fg=0x665544}); vim.cmd('redraw!')")
        self.pump(.2)
        self.assertEqual(style('HEAD').fg, (0x665544 << 8) | 2)
        self.assert_source()

    def test_kitty_font_sizes_repaint_and_cursor_restore(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# Large 日本語', '', 'Normal <small>Small</small> after', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; local c=require('inkstone.state').get(vim.api.nvim_get_current_buf()); "
                 "c.typography.enabled=true; c.typography.recovery=true; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
                 "vim.wait(300); vim.cmd('redraw!')")
        self.pump(.4)

        def scales():
            return [cell['mcd'] for row in range(24) for cell in self.screen.cpu_cells(row) if cell.get('mcd')]

        self.assertTrue(any(cell['scale'] == 2 for cell in scales()), self.visible_text())
        self.assertTrue(any(cell['subscale_n'] == 4 and cell['subscale_d'] == 5 for cell in scales()), self.visible_text())
        self.assertIn('AFTER', self.visible_text())
        self.assert_source()

        self.tmux('refresh-client')
        self.pump(.4)
        self.assertTrue(any(cell['scale'] == 2 for cell in scales()), self.visible_text())
        self.lua("vim.api.nvim_win_set_cursor(0,{3,0}); require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
                 "vim.wait(150); vim.cmd('redraw!')")
        self.pump(.3)
        self.assertTrue(any(cell['scale'] == 2 for cell in scales()), self.visible_text())
        self.lua("require('inkstone.state').get(vim.api.nvim_get_current_buf()).anti_conceal={enabled=true,above=0,below=0,disabled_modes={}}; "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100); vim.cmd('redraw!')")
        self.pump(.3)
        self.assertIn('# Large 日本語', self.visible_text())
        self.assertFalse(any(cell['scale'] == 2 for cell in scales()), self.visible_text())
        self.lua("vim.api.nvim_win_set_cursor(0,{5,0}); require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
                 "vim.wait(100); vim.cmd('redraw!')")
        self.pump(.3)
        self.assertIn('<small>Small</small>', self.visible_text())
        self.assertFalse(any(cell['subscale_n'] == 4 and cell['subscale_d'] == 5 for cell in scales()), self.visible_text())
        self.lua("require('inkstone.state').get(vim.api.nvim_get_current_buf()).anti_conceal.enabled=false; "
                 "vim.api.nvim_win_set_cursor(0,{1,0}); require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
                 "vim.wait(150); vim.cmd('redraw!')")
        self.pump(.3)
        self.assertTrue(any(cell['scale'] == 2 for cell in scales()), self.visible_text())
        self.lua("require('inkstone.state').get(vim.api.nvim_get_current_buf()).typography.headings[1]=1.5; "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100)")
        self.pump(.3)
        self.assertTrue(any(cell['scale'] == 2 for cell in scales()), self.visible_text())
        self.assertTrue(all(cell['subscale_n'] == 3 and cell['subscale_d'] == 4
                            for cell in scales() if cell['scale'] == 2), self.visible_text())
        self.lua("require('inkstone.api').typography(); vim.wait(100); vim.cmd('redraw!')")
        self.pump(.3)
        self.assertFalse(any(cell['scale'] != 1 or cell['subscale_d'] for cell in scales()), self.visible_text())
        self.assert_source()

    def test_kitty_font_sizes_with_extended_keys(self):
        self.tmux('set-option', '-s', 'extended-keys', 'on')
        self.test_kitty_font_sizes_repaint_and_cursor_restore()

    def test_fractional_text_chunks_do_not_add_gaps_inside_words(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# Integer heading', '', '## Images and diagrams', '',
                     '### Formatting and rendering', '', 'Normal <small>Images and diagrams</small> after', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
                 "vim.wait(150); vim.cmd('redraw!')")
        self.pump(.3)
        rendered = []
        for row in range(24):
            leads = [(col, cell) for col, cell in enumerate(self.screen.cpu_cells(row))
                     if cell.get('mcd') and cell['x'] == 0 and cell['y'] == 0]
            if not leads:
                continue
            rendered.append(''.join(cell['text'] for _, cell in leads))
            for (col, cell), (next_col, next_cell) in zip(leads, leads[1:]):
                meta = cell['mcd']
                numerator, denominator = meta['subscale_n'] or 1, meta['subscale_d'] or 1
                expected = len(cell['text']) * meta['scale'] * numerator
                actual = (next_col - col) * denominator
                if actual != expected:
                    self.assertTrue(cell['text'][-1].isspace() or next_cell['text'][0].isspace(),
                                    (row, col, cell))
                    self.assertGreaterEqual(actual, expected)
        self.assertEqual(rendered, ['Integer heading', 'Images and diagrams',
                                    'Formatting and rendering', 'Images and diagrams'])
        self.assert_source()

    def test_photographed_word_gaps_use_native_ascii_cells_and_unsplit_fractional_words(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# Performance evidence', '', '## Reproduce', '',
                     '## Incremental rendering with paragraph reflow', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150)")
        self.pump(.2)
        leads = [(row, col, cell) for row in range(24) for col, cell in enumerate(self.screen.cpu_cells(row))
                 if cell.get('mcd') and cell['x'] == 0 and cell['y'] == 0]
        integer = [(col, cell) for _, col, cell in leads
                   if cell['mcd']['scale'] == 2 and not cell['mcd']['subscale_n']]
        self.assertEqual(''.join(cell['text'] for _, cell in integer), 'Performance evidence')
        self.assertTrue(all(len(cell['text']) == 1 for _, cell in integer))
        for (col, _), (next_col, _) in zip(integer, integer[1:]):
            self.assertEqual(next_col - col, 2)
        for word in ('Reproduce', 'paragraph'):
            self.assertTrue(any(word in cell['text'] for _, _, cell in leads), word)
        self.assertIn('Incremental rendering with paragraph reflow', self.scaled_text())

        # Replay the exact unwrapped packets without tmux: cell positions and
        # payloads must agree, isolating grouping from passthrough transport.
        direct = Screen(None, 24, 120, 100)
        packets = json.loads(self.lua("print(vim.json.encode(require('inkstone.core.typography').drawn))"))
        for packet in packets:
            data = packet['payload'].encode()
            direct.test_commit_write_buffer(data, direct.test_create_write_buffer())
            direct.test_parse_written_data()
        direct_leads = [(row, col, cell) for row in range(24) for col, cell in enumerate(direct.cpu_cells(row))
                        if cell.get('mcd') and cell['x'] == 0 and cell['y'] == 0]
        self.assertEqual(leads, direct_leads)
        self.assert_source()

    def test_fractional_word_spaces_do_not_stack_packet_rounding(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        words = ['A', 'B', 'CD', 'EFG', 'HIJKLMN', 'OPQRSTUV', 'WXYZABCDE', 'Z']
        text = ' '.join(words)
        self.render(['BEFORE', '', '## ' + text, '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150)")
        self.pump(.2)
        visible = [(col, cell) for row in range(24) for col, cell in enumerate(self.screen.cpu_cells(row))
                   if cell.get('mcd') and cell['x'] == 0 and cell['y'] == 0]
        self.assertEqual(''.join(cell['text'] for _, cell in visible), text)
        glyphs = [(col, cell['text'].rstrip()) for col, cell in visible if cell['text'].strip()]
        self.assertEqual([word for _, word in glyphs], words)
        gaps = [next_col - (col + 1.5 * len(word))
                for (col, word), (next_col, _) in zip(glyphs, glyphs[1:])]
        self.assertTrue(all(1.5 <= gap <= 2 for gap in gaps), gaps)
        self.assertLessEqual(max(gaps) - min(gaps), .5)
        self.assert_source()

    def test_cursor_movement_keeps_typography_without_erase_frames(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# Large heading', '', 'one', 'two', 'three', 'four', 'five', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; local c=require('inkstone.state').get(vim.api.nvim_get_current_buf()); "
                 "c.typography.enabled=true; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150)")
        self.pump(.3)
        self.lua("local t=require('inkstone.core.typography'); local erase=t.erase; _G.typography_erases=0; "
                 "t.erase=function(...) _G.typography_erases=_G.typography_erases+1; return erase(...) end")
        for row in (6, 7, 8, 3, 9, 6):
            self.lua('vim.api.nvim_win_set_cursor(0,{' + str(row) + ',0})')
            self.pump(.04)
            self.assertTrue(any((cell.get('mcd') or {}).get('scale') == 2
                                for line in range(24) for cell in self.screen.cpu_cells(line)), self.visible_text())
        self.assertEqual(int(self.lua('print(_G.typography_erases)')), 0)
        self.assert_source()

    def test_command_input_and_unrelated_float_do_not_erase_typography(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# Heading', '', 'BODY', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150)")
        self.pump(.3)
        self.lua("local t=require('inkstone.core.typography'); local erase=t.erase; _G.typography_erases=0; "
                 "t.erase=function(...) _G.typography_erases=_G.typography_erases+1; return erase(...) end")
        os.write(self.fd, b':echo "')
        for char in b'command input':
            os.write(self.fd, bytes([char]))
            self.pump(.025)
        os.write(self.fd, b'\x1b')
        self.pump(.08)
        self.assertEqual(int(self.lua('print(_G.typography_erases)')), 0)
        for height in (2, 1):
            self.lua('vim.o.cmdheight=' + str(height))
            self.pump(.05)
        self.assertEqual(int(self.lua('print(_G.typography_erases)')), 0)
        self.lua("_G.foreign_buf=vim.api.nvim_create_buf(false,true); "
                 "_G.foreign_win=vim.api.nvim_open_win(_G.foreign_buf,true,"
                 "{relative='editor',row=10,col=60,width=40,height=7,style='minimal',border='single'})")
        for i in range(4):
            self.lua("vim.api.nvim_buf_set_lines(_G.foreign_buf,0,-1,false,{'filter " + str(i) + "'}); "
                     "require('inkstone.core.typography').clear(_G.foreign_buf); vim.cmd('redraw')")
            self.pump(.05)
            self.assertTrue(any((cell.get('mcd') or {}).get('scale') == 2
                                for row in range(24) for cell in self.screen.cpu_cells(row)), self.visible_text())
        self.assertEqual(int(self.lua('print(_G.typography_erases)')), 0)
        self.lua('vim.api.nvim_win_close(_G.foreign_win,true)')
        self.pump()
        self.assert_source()

    def test_float_overlap_hides_only_the_covered_heading(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# TOP', '', 'one', 'two', 'three', '', '# LOWER', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150)")
        self.pump(.3)
        self.lua("_G.cover_buf=vim.api.nvim_create_buf(false,true); "
                 "_G.cover_win=vim.api.nvim_open_win(_G.cover_buf,true,"
                 "{relative='editor',row=1,col=0,width=35,height=4,style='minimal',border='single'})")
        for i in range(3):
            self.lua("vim.api.nvim_buf_set_lines(_G.cover_buf,0,-1,false,{'popup " + str(i) + "'}); vim.cmd('redraw')")
            self.pump(.08)
            text = self.scaled_text()
            self.assertNotIn('TOP', text)
            self.assertIn('LOWER', text)
        self.lua('vim.api.nvim_win_close(_G.cover_win,true)')
        self.pump(.3)
        self.assert_source()

    def test_fzf_filter_keeps_unrelated_heading_intact(self):
        if not shutil.which('fzf'):
            self.skipTest('fzf is not installed')
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# Heading', '', 'BODY', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150)")
        self.pump(.3)
        command = "printf 'alpha\\nbravo\\nalphabet\\ncharlie\\n' | fzf --sync --no-info --no-mouse --layout=reverse"
        self.lua("local t=require('inkstone.core.typography'); local erase=t.erase; _G.typography_erases=0; "
                 "t.erase=function(...) _G.typography_erases=_G.typography_erases+1; return erase(...) end; "
                 "_G.fzf_buf=vim.api.nvim_create_buf(false,true); "
                 "_G.fzf_win=vim.api.nvim_open_win(_G.fzf_buf,true,"
                 "{relative='editor',row=10,col=60,width=40,height=7,style='minimal',border='single'}); "
                 "_G.fzf_job=vim.fn.jobstart({'sh','-c'," + json.dumps(command) + "},{term=true})")
        self.pump(.2)
        for text in ('a', 'l', 'p', 'h'):
            self.lua('vim.api.nvim_chan_send(_G.fzf_job,' + json.dumps(text) + ')')
            self.pump(.08)
            self.assertTrue(any((cell.get('mcd') or {}).get('scale') == 2
                                for row in range(24) for cell in self.screen.cpu_cells(row)), self.visible_text())
        self.assertEqual(int(self.lua('print(vim.fn.jobwait({_G.fzf_job},0)[1])')), -1)
        self.assertEqual(int(self.lua('print(_G.typography_erases)')), 0)
        self.assertIn('alpha', self.lua('print(vim.json.encode(vim.api.nvim_buf_get_lines(_G.fzf_buf,0,-1,false)))'))
        self.lua('vim.fn.jobstop(_G.fzf_job); vim.api.nvim_win_close(_G.fzf_win,true)')
        self.pump()
        self.assert_source()

    def test_unchanged_replay_does_not_clear_glyphs(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# FIRST', '', '# SECOND', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150)")
        self.pump(.3)
        result = json.loads(self.lua("local t=require('inkstone.core.typography'); local send=vim.api.nvim_ui_send; "
                 "local packets={}; vim.api.nvim_ui_send=function(s) packets[#packets+1]=s end; "
                 "t.paint(false); local unchanged=#packets; "
                 "t.paint(true); local recovery=table.concat(packets); vim.api.nvim_ui_send=send; "
                 "print(vim.json.encode({unchanged=unchanged,recovery=recovery}))"))
        self.assertEqual(result['unchanged'], 0)
        self.assertIn('FIRST', result['recovery'])
        self.assertIn('SECOND', result['recovery'])
        self.assertNotIn('X', result['recovery'])
        self.assert_source()

    def test_delayed_cursorline_keeps_headings_and_body_highlights(self):
        plugin = Path(os.environ.get('INKSTONE_CURSORLINE_RTP', Path.home() / '.local/share/nvim/lazy/auto-cursorline.nvim'))
        if not (plugin / 'lua/auto_cursorline/init.lua').is_file():
            self.skipTest('auto-cursorline.nvim is not installed')
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# FIRST', '', '## SECOND', '', '### THIRD', '', 'BODY', 'OTHER BODY', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; vim.api.nvim_set_hl(0,'CursorLine',{bg=0x334455}); "
                 "require('inkstone.state').get(vim.api.nvim_get_current_buf()).paragraph.wrap=false; "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150); "
                 "vim.api.nvim_win_set_cursor(0,{9,0}); vim.wo.cursorline=false; vim.cmd('redraw!')")
        self.pump(.3)
        self.lua('vim.opt.rtp:prepend(' + json.dumps(str(plugin)) + '); '
                 "require('auto_cursorline').setup({wait_ms=60}); "
                 "_G.typography_clears=0; "
                 "local send=vim.api.nvim_ui_send; vim.api.nvim_ui_send=function(s) "
                 "if s:find('%d+X') then _G.typography_clears=_G.typography_clears+1 end; return send(s) end")
        for row in (10, 9, 3, 5, 7, 9):
            self.lua('vim.api.nvim_win_set_cursor(0,{' + str(row) + ',0}); require("auto_cursorline").cursor_moved()')
            self.pump(.15)
            self.assertEqual(self.lua('print(vim.wo.cursorline)'), 'false')
            self.assertEqual(self.lua('print(vim.w.auto_cursorline_extmark)'), 'true')
            if row in (9, 10):
                self.assertEqual(self.lua("local w=vim.api.nvim_get_current_win(); local a=vim.fn.screenpos(w," + str(row) + ",1); local b=vim.fn.screenpos(w,12,1); "
                                 "print(vim.fn.screenattr(a.row,a.col)~=vim.fn.screenattr(b.row,b.col))"), 'true')
            self.assertEqual(int(self.lua('print(_G.typography_clears)')), 0)
            text = self.scaled_text()
            self.assertIn('FIRST', text)
            self.assertIn('SECOND', text)
            self.assertIn('THIRD', text)
        self.lua('vim.api.nvim_win_set_cursor(0,{3,0}); require("auto_cursorline").cursor_moved()')
        self.pump(.15)
        self.assertEqual(self.lua('print(vim.wo.cursorline)'), 'false')
        self.lua("require('inkstone.api').typography(); vim.wait(50)")
        self.pump(.15)
        self.assertEqual(self.lua('print(vim.w.auto_cursorline_disabled)'), 'nil')
        self.assertEqual(self.lua('print(vim.w.auto_cursorline_extmark)'), 'nil')
        self.assertEqual(self.lua('print(vim.wo.cursorline)'), 'true')
        self.assert_source()

    def test_fractional_typography_is_idle_until_damage_or_explicit_refresh(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# FIRST', '', '## SECOND', '', '### THIRD', '', 'BODY'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(200)")
        self.pump(.3)
        self.lua("_G.font_packets={}; local send=vim.api.nvim_ui_send; vim.api.nvim_ui_send=function(s) "
                 "if s:find(']66;',1,true) then _G.font_packets[#_G.font_packets+1]=s end; return send(s) end")
        self.pump(.8)
        self.assertEqual(self.lua('print(#_G.font_packets)'), '0')
        self.assertEqual(self.lua("print(require('inkstone.core.typography').timer:is_active())"), 'false')
        self.lua("vim.api.nvim_buf_set_extmark(0,vim.api.nvim_create_namespace('FractionalDamage'),4,0,"
                 "{virt_text={{'!','ErrorMsg'}},virt_text_win_col=0,priority=10000}); vim.cmd('redraw!')")
        self.pump(.15)
        packets = self.lua('print(table.concat(_G.font_packets))')
        self.assertIn('SECOND', packets)
        self.assertIn('FIRST', packets)
        self.assertIn('THIRD', packets)
        self.assertNotIn('X', packets)
        self.tmux('refresh-client')
        self.pump(.15)
        self.lua("require('inkstone.api').refresh(); vim.wait(150)")
        self.pump(.2)
        text = self.scaled_text()
        for heading in ('FIRST', 'SECOND', 'THIRD'):
            self.assertIn(heading, text)
        self.assert_source()

    def test_redrawn_identical_native_cells_still_repair_scaled_text(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# FIRST', '', '## SECOND', '', 'BODY'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(200)")
        self.pump(.2)
        self.lua("local t=require('inkstone.core.typography'); local r=t.drawn[1]; "
                 "_G.repair_label=r.payload:find('FIRST',1,true) and 'FIRST' or 'SECOND'; "
                 "vim.api.nvim_ui_send(t.wrap(('\\27'..'7\\27[%d;%dH\\27[%dX\\27'..'8'):format(r.row,r.col,r.width)))")
        self.pump(.1)

        def scaled_text():
            return self.scaled_text()

        label = self.lua('print(_G.repair_label)')
        self.assertNotIn(label, scaled_text(), 'native repaint must actually overwrite the overlay')
        self.lua("require('inkstone.core.typography').schedule(true)")
        self.pump(.15)
        self.assertIn(label, scaled_text(), 'a same-cell redraw must recover without cursor input or a timer')
        self.lua("local t=require('inkstone.core.typography'); local r=t.drawn[1]; "
                 "vim.api.nvim_ui_send(t.wrap(('\\27'..'7\\27[%d;%dH\\27[%dX\\27'..'8'):format(r.row,r.col,r.width)))")
        self.pump(.1)
        self.assertNotIn(label, scaled_text())
        self.lua("vim.cmd('redraw')")
        self.pump(.15)
        self.assertIn(label, scaled_text(), 'a completed redraw must repair even without explicit source-row damage')
        self.assert_source()

    def test_native_redraw_never_exposes_a_normal_size_typography_copy(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# FIRST', '', '## SECOND', '', '### THIRD', '',
                     'Normal <small>SMALL</small> after', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; local c=require('inkstone.state').get(vim.api.nvim_get_current_buf()); "
                 "c.paragraph.wrap=false; vim.api.nvim_set_hl(0,'CursorLine',{bg=0x334455}); "
                 "vim.api.nvim_win_set_cursor(0,{5,0}); vim.wo.cursorline=false; "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(200)")
        self.pump(.2)
        rectangles = json.loads(self.lua("local rectangles=vim.deepcopy(require('inkstone.core.typography').drawn); "
                 "for _,r in ipairs(rectangles) do r.native={}; "
                 "for row=r.screen_row,r.screen_row+r.height-1 do for col=r.screen_col,r.screen_col+r.width-1 do "
                 "r.native[#r.native+1]=vim.fn.screenstring(row,col) end end end; "
                 "print(vim.json.encode(rectangles))"))
        self.assertEqual(len(rectangles), 4)
        for rect in rectangles:
            self.assertTrue(all(not cell.strip() for cell in rect['native']), rect['key'])
        normal_copies = []
        frames = []

        def observe():
            frames.append(True)
            for rect in rectangles:
                for row in range(rect['screen_row'] - 1, rect['screen_row'] - 1 + rect['height']):
                    cells = self.screen.cpu_cells(row)
                    for cell in cells[rect['screen_col'] - 1:rect['screen_col'] - 1 + rect['width']]:
                        if cell['text'].strip() and not cell.get('mcd'):
                            normal_copies.append(cell['text'])

        self.frame_observer = observe
        for enabled in ('true', 'false'):
            self.lua('vim.wo.cursorline=' + enabled + "; vim.cmd('redraw')")
            self.pump(.15)
        self.assertTrue(frames)
        self.assertEqual(normal_copies, [])
        self.frame_observer = None
        self.lua("vim.cmd('redraw!')")
        self.pump(.2)
        text = self.scaled_text()
        for label in ('FIRST', 'SECOND', 'THIRD', 'SMALL'):
            self.assertIn(label, text)
        self.lua("require('inkstone.api').typography(); vim.wait(150)")
        self.pump(.2)
        for label in ('FIRST', 'SECOND', 'THIRD', 'SMALL'):
            self.assertIn(label, self.visible_text())
        self.assert_source()

    def test_cursorline_and_scaled_text_are_present_in_the_same_terminal_frame(self):
        plugin = Path(os.environ.get('INKSTONE_CURSORLINE_RTP', Path.home() / '.local/share/nvim/lazy/auto-cursorline.nvim'))
        if not (plugin / 'lua/auto_cursorline/init.lua').is_file():
            self.skipTest('auto-cursorline.nvim is not installed')
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# FIRST', '', '## SECOND', '', '### THIRD', '', 'BODY'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; vim.api.nvim_set_hl(0,'CursorLine',{bg=0x334455}); "
                 "require('inkstone.state').get(vim.api.nvim_get_current_buf()).paragraph.wrap=false; "
                 "vim.api.nvim_win_set_cursor(0,{9,0}); vim.wo.cursorline=false; "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(200)")
        self.pump(.2)
        self.lua('vim.opt.rtp:prepend(' + json.dumps(str(plugin)) + '); '
                 "require('auto_cursorline').setup({wait_ms=60}); _G.native_toggles=0; "
                 "vim.api.nvim_create_autocmd('OptionSet',{pattern='cursorline',callback=function() _G.native_toggles=_G.native_toggles+1 end})")
        frames = []

        def observe():
            text = self.scaled_text()
            frames.append([label for label in ('FIRST', 'SECOND', 'THIRD') if label not in text])

        self.frame_observer = observe
        for _ in range(2):
            self.lua("require('auto_cursorline').cursor_moved()")
            self.pump(.15)
        self.assertTrue(frames, 'the real terminal must expose synchronized frame boundaries')
        self.assertTrue(all(not missing for missing in frames), frames)
        self.assertEqual(self.lua('print(_G.native_toggles)'), '0')
        self.assertEqual(self.lua('print(vim.wo.cursorline)'), 'false')
        self.assert_source()

    def test_leaving_rendered_buffer_or_tab_clears_overlays_before_new_text(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# FIRST', '', '## SECOND', '', 'BODY'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; _G.font_buf=vim.api.nvim_get_current_buf(); "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(200)")
        self.pump(.2)
        for action in ('buffer', 'window', 'tab'):
            plain = "{'PLAIN BEFORE','','PLAIN AFTER','','PLAIN TAIL'}"
            if action == 'buffer':
                self.lua("local buf=vim.api.nvim_create_buf(false,true); vim.api.nvim_buf_set_lines(buf,0,-1,false," + plain + "); "
                         "vim.api.nvim_win_set_buf(0,buf); vim.cmd('redraw')")
            elif action == 'window':
                self.lua("local old=vim.api.nvim_get_current_win(); local buf=vim.api.nvim_create_buf(false,true); "
                         "vim.api.nvim_buf_set_lines(buf,0,-1,false," + plain + "); vim.cmd('vsplit'); "
                         "vim.api.nvim_win_set_buf(0,buf); vim.api.nvim_win_close(old,true); vim.cmd('redraw')")
            else:
                self.lua("vim.cmd('tabnew'); vim.api.nvim_buf_set_lines(0,0,-1,false," + plain + "); vim.cmd('redraw')")
            self.pump(.15)
            text = self.visible_text()
            self.assertIn('PLAIN AFTER', text)
            self.assertIn('PLAIN TAIL', text)
            self.assertFalse(any(cell.get('mcd') for row in range(24) for cell in self.screen.cpu_cells(row)), text)
            if action in ('buffer', 'window'):
                self.lua("vim.api.nvim_win_set_buf(0,_G.font_buf); vim.wait(150)")
            else:
                self.lua("vim.cmd('tabclose!'); vim.wait(150)")
            self.pump(.2)
            self.assert_source()

    def test_hidden_tmux_window_cannot_paint_or_erase_the_destination(self):
        self.check_tmux_hidden_window('on')

    def test_hidden_tmux_window_is_safe_without_focus_notifications(self):
        self.check_tmux_hidden_window('off')

    def check_tmux_hidden_window(self, focus):
        self.tmux('set-option', '-g', 'allow-passthrough', 'all')
        self.tmux('set-option', '-g', 'focus-events', focus)
        self.render(['BEFORE', '', '# FIRST', '', '## SECOND', '', 'BODY'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(200)")
        self.pump(.2)
        source = self.tmux('display-message', '-p', '#{window_id}')
        other = self.tmux('new-window', '-d', '-P', '-F', '#{window_id}', 'sh', '-c',
                          "printf 'PLAIN BEFORE\\n\\nPLAIN AFTER\\n'; sleep 60")
        self.tmux('select-window', '-t', other)
        self.pump(.2)
        self.lua("vim.cmd('redraw!'); require('inkstone.core.typography').erase(); vim.cmd('redraw!')")
        self.pump(.25)
        self.assertFalse(any(c.get('mcd') for row in range(24) for c in self.screen.cpu_cells(row)))
        self.assertIn('PLAIN AFTER', self.visible_text())
        self.tmux('select-window', '-t', source)
        if focus == 'off':
            self.lua("vim.cmd('redraw')")
        self.pump(.35)
        text = self.scaled_text()
        self.assertIn('FIRST', text)
        self.assertIn('SECOND', text)
        self.assert_source()

    def test_unfocused_tmux_pane_rechecks_window_and_zoom_visibility(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'all')
        self.tmux('set-option', '-g', 'focus-events', 'on')
        self.render(['BEFORE', '', '# FIRST', '', '## SECOND', '', 'BODY'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(200)")
        self.pump(.2)
        source = self.tmux('display-message', '-p', '#{window_id}')
        sibling = self.tmux('split-window', '-h', '-d', '-P', '-F', '#{pane_id}', 'sleep', '60')
        self.pump(.2)
        self.tmux('select-pane', '-t', sibling)
        self.pump(.25)

        def scaled_text():
            return self.scaled_text()

        self.assertIn('FIRST', scaled_text(), 'visible inactive panes keep typography')
        self.tmux('resize-pane', '-Z', '-t', sibling)
        self.lua("vim.cmd('redraw!')")
        self.pump(.2)
        self.assertFalse(scaled_text().strip())
        self.tmux('resize-pane', '-Z', '-t', sibling)
        self.lua("vim.cmd('redraw!')")
        self.pump(.25)
        self.assertIn('FIRST', scaled_text())
        other = self.tmux('new-window', '-d', '-P', '-F', '#{window_id}', 'sleep', '60')
        self.tmux('select-window', '-t', other)
        self.lua("vim.cmd('redraw!')")
        self.pump(.25)
        self.assertFalse(scaled_text().strip())
        self.tmux('select-window', '-t', source)
        self.lua("vim.cmd('redraw!')")
        self.pump(.25)
        self.assertIn('FIRST', scaled_text())
        self.assert_source()

    def test_periodic_typography_recovery_only_replays_opted_in_buffers(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '## FIRST', '', 'BODY'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; _G.first_win=vim.api.nvim_get_current_win(); "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(150); "
                 "vim.cmd('vnew'); vim.api.nvim_buf_set_lines(0,0,-1,false,{'BEFORE','','## SECOND','','BODY'}); "
                 "vim.bo.filetype='markdown'; vim.treesitter.start(0,'markdown'); "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf(),config={typography={recovery=true}}}); vim.wait(200)")
        self.pump(.3)
        self.lua("_G.font_packets={}; local send=vim.api.nvim_ui_send; vim.api.nvim_ui_send=function(s) "
                 "if s:find(']66;',1,true) then _G.font_packets[#_G.font_packets+1]=s end; return send(s) end")
        self.pump(.6)
        packets = self.lua('print(table.concat(_G.font_packets))')
        self.assertIn('SECOND', packets)
        self.assertNotIn('FIRST', packets)
        self.lua("local opted=vim.api.nvim_get_current_win(); vim.api.nvim_set_current_win(_G.first_win); vim.api.nvim_win_close(opted,true); vim.wait(150)")
        self.pump(.2)
        self.lua('_G.font_packets={}')
        self.pump(.6)
        self.assertEqual(self.lua('print(#_G.font_packets)'), '0')
        self.assertEqual(self.lua("print(require('inkstone.core.typography').timer:is_active())"), 'false')
        self.assert_source()

    def test_fragmented_version_reply_never_becomes_mapped_input(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.lua("vim.env.KITTY_WINDOW_ID=nil; vim.env.TERM_PROGRAM=nil")
        self.render(['BEFORE', '', '# Large heading', '', 'BODY', '', 'AFTER'])
        self.fragment_response = True
        query_start = len(self.output)
        self.lua("vim.o.ttimeout=true; vim.o.ttimeoutlen=1; _G.version_puts=0; "
                 "vim.keymap.set('n','P',function() _G.version_puts=_G.version_puts+1 end); "
                 "vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()})")
        for attempt in range(2):
            if attempt:
                self.lua("require('inkstone.api').typography(); require('inkstone.core.typography').capability=nil; "
                         "require('inkstone.api').typography()")
            self.pump(.5)
            self.assert_source()
            state = json.loads(self.lua("print(vim.json.encode({vim.api.nvim_get_mode().mode,_G.version_puts,vim.o.ttimeoutlen}))"))
            self.assertEqual(state, ['n', 0, 1])
            self.assertTrue(any((cell.get('mcd') or {}).get('scale') == 2
                                for row in range(24) for cell in self.screen.cpu_cells(row)), self.visible_text())
            self.assertNotIn(b'\x1b[>0q', self.output[query_start:])

    def test_tmux_csi_u_version_probe_does_not_trigger_mappings(self):
        self.tmux('set-option', '-s', 'extended-keys', 'always')
        self.tmux('set-option', '-s', 'extended-keys-format', 'csi-u')
        self.test_fragmented_version_reply_never_becomes_mapped_input()

    def test_latex2text_demo_without_latex_parser(self):
        if not shutil.which('latex2text'):
            self.skipTest('latex2text is not installed')
        self.render(Path(ROOT / 'demo/latex.md').read_text().splitlines())
        self.lua("require('inkstone.state').get(vim.api.nvim_get_current_buf()).latex.converter='latex2text'; "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100); vim.cmd('redraw!')")
        self.pump()
        text = self.visible_text()
        self.assertIn('√(3x-1)+(1+x)^2', text)
        self.assertIn('lim_n→∞ (1 + 1/n)^n', text)
        self.assert_source()

    def test_utftex_rich_math_has_no_source_tails(self):
        if not shutil.which('utftex'):
            self.skipTest('utftex is not installed')
        self.render(Path(ROOT / 'demo/latex.md').read_text().splitlines(), conceallevel=3)
        text = self.visible_text()
        self.assertIn('lim', text)
        self.assertIn('n→∞', text)
        self.assertIn('─', text)
        self.assertNotIn('\\lim', text)
        self.assertNotIn('\\sqrt', text)
        self.assertNotIn('$$', text)
        self.lua("vim.api.nvim_win_set_cursor(0,{6,0}); require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
                 "vim.wait(100); vim.cmd('redraw!')")
        self.pump()
        self.assertNotIn('\\lim', self.visible_text())
        self.lua("require('inkstone.state').get(vim.api.nvim_get_current_buf()).anti_conceal={enabled=true,above=0,below=0,disabled_modes={}}; "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(100); vim.cmd('redraw!')")
        self.pump()
        self.assertIn('\\lim', self.visible_text())
        self.assertNotIn('n→∞', self.visible_text())
        self.assert_source()

    def test_kitty_graphics_chart_and_viewer(self):
        snacks = Path(os.environ.get('INKSTONE_SNACKS_RTP', Path.home() / '.local/share/nvim/lazy/snacks.nvim'))
        if not (snacks / 'lua/snacks/init.lua').is_file():
            self.skipTest('snacks.nvim is not installed')
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '| Name | Value |', '| - | - |', '| Alpha | 20 |', '| Beta | 10 |', '', 'AFTER'], wrap=True)
        self.lua('vim.opt.rtp:prepend(' + json.dumps(str(snacks)) + '); vim.env.KITTY_WINDOW_ID="1"; vim.env.SNACKS_KITTY="true"; '
                 'require("snacks").setup({image={enabled=true,doc={enabled=false},math={enabled=false},cache='
                 + json.dumps(str(self.root / 'snacks-cache')) + '}}); '
                 'local c=require("inkstone.state").get(vim.api.nvim_get_current_buf()); c.media.cache_dir='
                 + json.dumps(str(self.root / 'charts')) + '; '
                 'vim.api.nvim_win_set_cursor(0,{5,0}); require("inkstone.api").toggle_chart(); '
                 'vim.wait(1500); vim.cmd("redraw!")')
        self.pump(.5)
        self.assertGreater(self.screen.grman.image_count, 0, self.visible_text())
        self.assertIn('Table · chart', self.visible_text())
        self.assertNotIn('█', self.visible_text())
        self.assert_source()
        self.lua("require('inkstone.api').toggle_chart(); vim.api.nvim_win_set_cursor(0,{1,0}); "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(300); vim.cmd('redraw!')")
        self.pump(.3)
        self.assertIn('│', self.visible_text())
        image = self.root / 'gradient.png'
        subprocess.run(['magick', '-size', '1600x900', 'gradient:red-blue', str(image)], check=True)
        self.lua('_G.inkstone_viewer=require("inkstone.core.viewer").open(' + json.dumps(str(image))
                 + ',{origin=vim.api.nvim_get_current_buf()}); vim.wait(1200); vim.cmd("redraw!")')
        self.pump(.4)
        self.assertIn('100%', self.visible_text())
        self.lua("require('inkstone.core.viewer').action(_G.inkstone_viewer,'zoom_in'); vim.wait(800); vim.cmd('redraw!')")
        self.pump(.3)
        self.assertIn('125%', self.visible_text())
        self.assertGreater(self.screen.grman.image_count, 1)
        self.lua("vim.api.nvim_win_close(_G.inkstone_viewer.win,true); vim.wait(200); vim.cmd('redraw!')")
        self.pump(.3)
        self.assertNotIn('125%', self.visible_text())
        self.assert_source()

    def test_kitty_font_sizes_with_pane_offsets_and_floats(self):
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.tmux('set-option', '-g', 'status', 'on')
        self.tmux('set-option', '-g', 'status-position', 'top')
        self.render(['BEFORE', '', '# Heading', '', 'BODY', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.core.typography').tmux=nil; "
                 "require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(400); vim.cmd('redraw!')")
        self.pump(.4)

        def enlarged():
            return [(row, col) for row in range(24) for col, cell in enumerate(self.screen.cpu_cells(row))
                    if cell.get('mcd') and cell['mcd']['scale'] == 2]

        self.assertTrue(enlarged(), self.visible_text())
        self.assertTrue(all(row >= 3 for row, _ in enlarged()), enlarged())
        self.lua("_G.cover=vim.api.nvim_open_win(vim.api.nvim_create_buf(false,true),false,"
                 "{relative='editor',row=1,col=0,width=40,height=4,style='minimal',border='single'}); "
                 "vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(_G.cover),0,-1,false,{'POPUP'}); vim.cmd('redraw!')")
        self.pump(.4)
        self.assertIn('POPUP', self.visible_text())
        self.assertFalse(enlarged(), self.visible_text())
        self.lua("vim.api.nvim_win_close(_G.cover,true); vim.cmd('redraw!')")
        self.pump(.4)
        self.assertTrue(enlarged(), self.visible_text())
        self.tmux('split-window', '-h', '-b', '-l', '35', 'sleep 30')
        self.pump(.8)
        self.lua("require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); vim.wait(300); vim.cmd('redraw!')")
        self.pump(.4)
        self.assertTrue(enlarged(), self.visible_text())
        self.assertTrue(all(col >= 35 for _, col in enlarged()), enlarged())
        self.assert_source()

    def test_old_kitty_keeps_native_text(self):
        self.terminal_version = b'kitty(0.39.0)'
        self.tmux('set-option', '-g', 'allow-passthrough', 'on')
        self.render(['BEFORE', '', '# Old kitty', '', 'AFTER'])
        self.lua("vim.env.KITTY_WINDOW_ID='1'; require('inkstone.api').render({buf=vim.api.nvim_get_current_buf()}); "
                 "vim.wait(250); vim.cmd('redraw!')")
        self.pump(.4)
        self.assertIn('Old kitty', self.visible_text())
        self.assertNotIn(b'\x1b]66;', self.output)
        self.assert_source()



if __name__ == '__main__':
    unittest.main(argv=[str(__file__)], verbosity=2)
