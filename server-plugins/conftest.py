import sys
from pathlib import Path

# Tests import the shared library the way the build scripts see it.
sys.path.insert(0, str(Path(__file__).resolve().parent / "common"))
