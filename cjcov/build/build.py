#!/usr/bin/env python3
import os
import pathlib
import sys
os.execvp("node", ["node", str(pathlib.Path(__file__).with_suffix(".mjs")), *sys.argv[1:]])
