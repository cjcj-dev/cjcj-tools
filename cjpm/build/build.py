#!/usr/bin/env python3
# Compatibility process adapter; the sole build implementation is build.mjs.
import os
import sys
os.execvp("node", ["node", os.path.join(os.path.dirname(os.path.abspath(__file__)), "build.mjs"), *sys.argv[1:]])
