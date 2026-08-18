#!/usr/bin/env python3
"""Launcher. Kept outside the package so PyInstaller (and `python
rsyncronizer.py`) get a plain top-level entry point while the package
keeps its relative imports."""

from app.main import main

raise SystemExit(main())
