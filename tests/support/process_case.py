import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(os.environ['NVIM_ZH_ROOT'])
NVIM = os.environ.get('NVIM_BIN', 'nvim')

class TempNeovimCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='dsh-nvim-zh-integration-')
        self.base = Path(self.tmp.name)
        self.env = dict(os.environ, TERM='xterm-256color')
        for kind in ('DATA', 'CONFIG', 'STATE', 'CACHE'):
            self.env[f'XDG_{kind}_HOME'] = str(self.base / kind.lower())
            (self.base / kind.lower()).mkdir()
        self.env['NVIM_LOG_FILE'] = str(self.base / 'state' / 'nvim.log')

    def tearDown(self):
        self.tmp.cleanup()

    def script(self, source):
        path = self.base / 'spec.lua'
        path.write_text(source)
        self.env['NVIM_ZH_SPEC'] = str(path)
        return path
