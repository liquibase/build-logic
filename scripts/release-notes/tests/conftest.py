"""Add the parent directory (scripts/release-notes/) to sys.path so
`import aggregate_release_notes` works when pytest is invoked from any cwd."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
