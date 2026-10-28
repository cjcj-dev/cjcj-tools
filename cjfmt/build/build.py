#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
# This source file is part of the Cangjie project, licensed under Apache-2.0
# with Runtime Library Exception.
#
# See https://cangjie-lang.cn/pages/LICENSE for license information.

"""Compatibility process adapter; build logic lives in build.mjs."""
import os
import sys

os.execvp("node", ["node", os.path.join(os.path.dirname(os.path.abspath(__file__)), "build.mjs"), *sys.argv[1:]])
