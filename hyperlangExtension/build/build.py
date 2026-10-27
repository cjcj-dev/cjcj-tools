#!/usr/bin/env python3
# Compatibility entry; the single producer is the adjacent zx/ESM script.
import os
import pathlib
import subprocess
import sys

if __name__ == '__main__':
    sys.exit(subprocess.call([os.environ.get('NODE', 'node'),
                             str(pathlib.Path(__file__).with_suffix('.mjs')), *sys.argv[1:]]))
