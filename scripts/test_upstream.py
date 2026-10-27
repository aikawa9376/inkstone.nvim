"""Run inherited Plenary tests and propagate child assertion failures reliably."""
import os
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
suite = sys.argv[1] if len(sys.argv) > 1 else 'tests/unit'
init = 'tests/minimal_unit.lua' if suite == 'tests/unit' else 'tests/minimal_init.lua'
command = 'PlenaryBustedDirectory ' + suite + " { minimal_init = '" + init + "', sequential = true }"
result = subprocess.run([os.environ.get('NVIM', 'nvim'), '--headless', '--noplugin', '-u', init, '-c', command], cwd=root, text=True, capture_output=True)
output = result.stdout + result.stderr
sys.stdout.write(output)
plain = re.sub(r'\x1b\[[0-9;]*m', '', output)
passed = sum(map(int, re.findall(r'Success:\s+(\d+)', plain)))
failed = sum(map(int, re.findall(r'Failed :\s+(\d+)', plain)))
errors = sum(map(int, re.findall(r'Errors :\s+(\d+)', plain)))
print(f'Inkstone inherited checks: {passed} passed, {failed} failed, {errors} errors')
sys.exit(1 if result.returncode or failed or errors or not passed else 0)
