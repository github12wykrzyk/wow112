import subprocess
import sys
import unittest
from pathlib import Path


class OperatorConsoleFinalAcceptanceTests(unittest.TestCase):
    def test_operator_console_full_suite(self):
        root = Path(__file__).resolve().parents[1]
        proc = subprocess.run(
            [sys.executable, str(root / 'tools' / 'operator_console' / 'ci.py')],
            cwd=root / 'tools' / 'operator_console',
            text=True,
            capture_output=True,
        )
        if proc.returncode:
            self.fail('operator console ci failed\nSTDOUT:\n%s\nSTDERR:\n%s' % (proc.stdout, proc.stderr))


if __name__ == '__main__':
    unittest.main()
