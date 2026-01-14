"""Utility for discovering and editing bash-style array definitions in scripts.

Provides a small class that can:
- declare inline static lists to be used later (class attributes)
- search the workspace for script files containing bash array definitions
- add or remove entries from those array definitions while preserving style

Usage examples:
 from mods.customize_build import BuildCustomizer
 bc = BuildCustomizer(repo_root='.')
 files = bc.find_files_with_array('FEDORA_PACKAGES')
 bc.add_entries_to_array(files[0], 'FEDORA_PACKAGES', ['firefox', 'chromium'])
 bc.remove_entries_from_array(files[0], 'FEDORA_PACKAGES', ['firefox'])

This is safe for CI usage: files are updated via an atomic replace and a backup is kept.
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import shutil
import time
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

LOG = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)


@dataclass
class ArrayEditResult:
    path: Path
    changed: bool
    before_count: int
    after_count: int


class BuildCustomizer:
    """Find and modify bash array definitions in repository files.

    Behaviors & guarantees:
    - Edits are atomic: write to a temp file then os.replace
    - Tries to preserve indentation and quoting style of entries
    - Matching of entries is done on the unquoted token string
    """


    # Inline static defaults for convenience (can be overridden or extended).
    # Map array name -> list of default entries to add (ADDITION_LIST) or
    # remove (REMOVAL_LIST).
    ADDITION_LIST = {
        "FEDORA_PACKAGES": [
            "firefox",
            "firefox-langpacks",
            "fedora-chromium-config",
            "gnome-terminal",
            "gdk-pixbuf2-modules-extra",
            "chromium",
            "gstreamer1-plugin-openh264",
            "mozilla-openh264",
            "nmstate",
            "openh264",
            "remmina",
            "snapd",
            "solaar",
            "subversion",
            "subversion-gnome",
            "subversion-javahl",
            "unclutter",
            "xdotool",
            "openssl-pkcs11"
        ],
    }
    
    REMOVAL_LIST = {
        "EXCLUDED_PACKAGES": [
            "fedora-bookmarks",
            "fedora-chromium-config",
            "fedora-chromium-config-gnome",
            "firefox",
            "firefox-langpacks",
        ],
        "UNWANTED_PACKAGES": [
            "firefox",
            "firefox-langpacks",
        ],
    }

    # Default array names to look for when scanning files (derived from the
    # per-array ADDITION_LIST and REMOVAL_LIST mappings). This keeps any
    # per-array defaults in one place and avoids duplication.
    DEFAULT_ARRAY_NAMES: List[str] = list(
        dict.fromkeys(list(ADDITION_LIST.keys()) + list(REMOVAL_LIST.keys()))
    )


    # Default glob patterns used by find_files_with_array when no patterns are supplied
    DEFAULT_SEARCH_PATTERNS: List[str] = ["build_files/**/*.sh"]


    ARRAY_START_RE = re.compile(r"^\s*([A-Za-z0-9_]+)\s*=\s*\(")

    def __init__(self, repo_root: Optional[str] = None, backup_dir: Optional[str] = None):
        self.repo_root = Path(repo_root or os.getcwd()).resolve()
        self.backup_dir = Path(backup_dir).resolve() if backup_dir else None

    def find_files_with_array(self, array_name: Optional[str] = None, patterns: Optional[List[str]] = None) -> List[Path]:
        """Search repository for files containing a bash array definition.

        If array_name is provided, only files that declare that array are returned.
        `patterns` is a list of glob patterns (relative to repo root) to search;
        defaults to common script locations.
        """
        patterns = patterns or self.DEFAULT_SEARCH_PATTERNS
        matches: List[Path] = []

        for pattern in patterns:
            for p in self.repo_root.glob(pattern):
                if not p.is_file():
                    continue
                try:
                    text = p.read_text(encoding="utf-8")
                except Exception:
                    continue
                if array_name:
                    if re.search(rf"^\s*{re.escape(array_name)}\s*=\s*\(", text, flags=re.M):
                        matches.append(p)
                else:
                    if self.ARRAY_START_RE.search(text):
                        matches.append(p)
        LOG.info("Found %d files matching array=%s", len(matches), array_name)
        return matches

    def find_files_for_default_arrays(self, patterns: Optional[List[str]] = None) -> dict:
        """Scan repository and return a mapping of default array name -> list[Path].

        Uses `DEFAULT_ARRAY_NAMES` to look for specific array declarations. This is
        more precise than scanning for any array and is useful when you only care
        about known arrays used by the build scripts.
        """
        patterns = patterns or self.DEFAULT_SEARCH_PATTERNS
        result = {name: [] for name in self.DEFAULT_ARRAY_NAMES}
        for pattern in patterns:
            for p in self.repo_root.glob(pattern):
                if not p.is_file():
                    continue
                try:
                    text = p.read_text(encoding="utf-8")
                except Exception:
                    continue
                for name in self.DEFAULT_ARRAY_NAMES:
                    if re.search(rf"^\s*{re.escape(name)}\s*=\s*\(", text, flags=re.M):
                        result[name].append(p)
        LOG.info("Scanned defaults, found arrays: %s", {k: len(v) for k, v in result.items()})
        return result

    def find_files_with_any_default(self, patterns: Optional[List[str]] = None) -> List[Path]:
        """Return a deduplicated list of files that contain any of DEFAULT_ARRAY_NAMES."""
        mapping = self.find_files_for_default_arrays(patterns=patterns)
        files = []
        seen = set()
        for lst in mapping.values():
            for p in lst:
                if p not in seen:
                    files.append(p)
                    seen.add(p)
        LOG.info("Found %d files containing any default arrays", len(files))
        for f in files:
            LOG.info(" - %s", f)
        return files

    def _parse_array_block(self, lines: List[str], start_idx: int) -> Tuple[int, List[str], str]:
        """Given file lines and index of array start (line with NAME=( ), return:
        - end index (index of line containing closing ')')
        - list of entries as raw lines (preserve comments on those lines)
        - indentation (leading whitespace) used for entries
        """
        entries: List[str] = []
        indent = ""

        # Handle single-line forms like NAME=() or NAME=(a b "c d") or
        # NAME=("${new_array[@]}") by detecting a closing paren on the same
        # line as the opening. In such cases we parse the inner tokens (if any)
        # and return immediately without scanning subsequent lines.
        start_line = lines[start_idx]
        m_inline = re.search(r"\((.*)\)", start_line)
        if m_inline:
            inner = m_inline.group(1).strip()
            if inner:
                # find tokens: quoted or unquoted
                token_re = re.compile(r'"[^"]*"|\'[^\']*\'|[^\s]+')
                tokens = token_re.findall(inner)
                # preserve raw token text as array entry lines
                entries = [t for t in (tok.strip() for tok in tokens) if t]
            return start_idx, entries, indent

        # Multi-line array: entries start on the following lines until a line
        # containing only a closing paren is found.
        i = start_idx + 1
        while i < len(lines):
            line = lines[i]
            if re.match(r"^\s*\)", line):
                return i, entries, indent
            # capture indentation from first non-empty line
            if indent == "":
                m = re.match(r"^(\s*)", line)
                indent = m.group(1) if m else ""
            entries.append(line.rstrip('\n'))
            i += 1
        raise RuntimeError("Array block not closed with )")

    @staticmethod
    def _normalize_entry(line: str) -> Optional[str]:
        """Return the core token for comparison, or None for comments/empty.

        Strips surrounding quotes and trailing comments.
        """
        s = line.strip()
        if not s:
            return None
        if s.lstrip().startswith('#'):
            return None
        # remove trailing inline comment
        s = re.sub(r"\s+#.*$", "", s)
        # remove trailing backslash continuation markers
        s = s.rstrip(' \\')
        # strip quotes
        if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
            s = s[1:-1]
        return s.strip()

    def _write_atomic(self, path: Path, content: str, backup: bool = True) -> None:
        tmp = Path(tempfile.mktemp(dir=str(path.parent)))
        tmp.write_text(content, encoding="utf-8")
        # preserve mode
        try:
            st = path.stat()
            os.chmod(tmp, st.st_mode)
        except Exception:
            # ignore
            pass
        # Optionally write a backup copy into self.backup_dir if configured.
        if self.backup_dir and path.exists():
            try:
                self.backup_dir.mkdir(parents=True, exist_ok=True)
                ts = int(time.time())
                bak_name = f"{path.name}.{ts}.bak"
                bak_path = self.backup_dir / bak_name
                shutil.copy2(path, bak_path)
                LOG.info("Wrote backup %s", bak_path)
            except Exception:
                LOG.exception("Failed to write backup to %s", self.backup_dir)
        os.replace(str(tmp), str(path))

    def add_entries_to_array(self, file_path: Path, array_name: str, entries: List[str], write: bool = True) -> ArrayEditResult:
        """Add entries to the named array in file_path.

        If `write` is False the function performs a dry-run and does not
        modify the file; it still returns an ArrayEditResult reporting what
        would have changed.

        Returns ArrayEditResult.
        """
        file_path = Path(file_path)
        text = file_path.read_text(encoding="utf-8")
        lines = text.splitlines()

        # find start
        start_idx = None
        for idx, line in enumerate(lines):
            if re.match(rf"^\s*{re.escape(array_name)}\s*=\s*\(", line):
                start_idx = idx
                break
        if start_idx is None:
            raise ValueError(f"Array {array_name} not found in {file_path}")

        end_idx, current_lines, indent = self._parse_array_block(lines, start_idx)
        current_entries = [self._normalize_entry(l) for l in current_lines]
        current_entries_clean = [e for e in current_entries if e]
        before_count = len(current_entries_clean)

        # prepare additions, avoid duplicates
        additions = []
        for ent in entries:
            if ent not in current_entries_clean:
                additions.append(ent)

        if not additions:
            LOG.info("No entries to add for %s in %s", array_name, file_path)
            return ArrayEditResult(file_path, changed=False, before_count=before_count, after_count=before_count)

        # Construct new block
        new_block_lines = list(current_lines)
        # Append additions before the closing paren
        for ent in additions:
            # preserve simple quoting style: use unquoted token if original entries unquoted, else use double quotes
            new_block_lines.append(f"{indent}{ent}")

        # rebuild file content
        new_lines = lines[: start_idx + 1] + new_block_lines + lines[end_idx:]
        new_text = "\n".join(new_lines) + "\n"

        if write:
            self._write_atomic(file_path, new_text)
        else:
            LOG.info("Dry-run: would add %d entries to %s:%s", len(additions), file_path, array_name)
        after_count = before_count + len(additions)
        LOG.info("Added %d entries to %s:%s", len(additions), file_path, array_name)
        return ArrayEditResult(file_path, changed=True, before_count=before_count, after_count=after_count)

    def remove_entries_from_array(self, file_path: Path, array_name: str, entries: List[str], write: bool = True) -> ArrayEditResult:
        """Remove entries from the named array in file_path.

        If `write` is False the function performs a dry-run and does not
        modify the file; it still returns an ArrayEditResult reporting what
        would have changed.

        Returns ArrayEditResult.
        """
        file_path = Path(file_path)
        text = file_path.read_text(encoding="utf-8")
        lines = text.splitlines()

        # find start
        start_idx = None
        for idx, line in enumerate(lines):
            if re.match(rf"^\s*{re.escape(array_name)}\s*=\s*\(", line):
                start_idx = idx
                break
        if start_idx is None:
            raise ValueError(f"Array {array_name} not found in {file_path}")

        end_idx, current_lines, indent = self._parse_array_block(lines, start_idx)
        current_entries = [self._normalize_entry(l) for l in current_lines]
        current_entries_clean = [e for e in current_entries if e]
        before_count = len(current_entries_clean)

        to_remove = set(entries)
        new_block_lines: List[str] = []
        removed = 0
        for raw in current_lines:
            norm = self._normalize_entry(raw)
            if norm and norm in to_remove:
                removed += 1
                continue
            new_block_lines.append(raw)

        if removed == 0:
            LOG.info("No matching entries to remove for %s in %s", array_name, file_path)
            return ArrayEditResult(file_path, changed=False, before_count=before_count, after_count=before_count)

        new_lines = lines[: start_idx + 1] + new_block_lines + lines[end_idx:]
        new_text = "\n".join(new_lines) + "\n"
        if write:
            self._write_atomic(file_path, new_text)
        else:
            LOG.info("Dry-run: would remove %d entries from %s:%s", removed, file_path, array_name)
        after_count = before_count - removed
        LOG.info("Removed %d entries from %s:%s", removed, file_path, array_name)
        return ArrayEditResult(file_path, changed=True, before_count=before_count, after_count=after_count)

    def apply_defaults(self, patterns: Optional[List[str]] = None, dry_run: bool = True) -> dict:
        """Find files containing the default arrays and apply additions/removals.

        - `patterns` restricts the glob search (defaults to DEFAULT_SEARCH_PATTERNS)
        - `dry_run` when True will not write changes, only report what would happen

        Returns a mapping: { Path(str): [ArrayEditResult, ...], ... }
        """
        patterns = patterns or self.DEFAULT_SEARCH_PATTERNS
        mapping = self.find_files_for_default_arrays(patterns=patterns)
        results: dict = {}

        # For each array name, process its list of files
        for array_name, files in mapping.items():
            for fp in files:
                results.setdefault(str(fp), [])
                # removals first (if any)
                if array_name in self.REMOVAL_LIST:
                    try:
                        res = self.remove_entries_from_array(fp, array_name, list(self.REMOVAL_LIST[array_name]), write=not dry_run)
                        results[str(fp)].append(res)
                    except Exception as e:
                        LOG.exception("Error removing entries for %s in %s: %s", array_name, fp, e)
                # additions next (if any)
                if array_name in self.ADDITION_LIST:
                    try:
                        res = self.add_entries_to_array(fp, array_name, list(self.ADDITION_LIST[array_name]), write=not dry_run)
                        results[str(fp)].append(res)
                    except Exception as e:
                        LOG.exception("Error adding entries for %s in %s: %s", array_name, fp, e)

        LOG.info("apply_defaults completed (dry_run=%s). Processed %d files.", dry_run, len(results))
        return results


def _cli():
    p = argparse.ArgumentParser(description="Script array editing helper")
    p.add_argument(
        "repo_root",
        nargs='?',
        default=os.environ.get('GITHUB_WORKSPACE', '.'),
        help="Path to repository root (defaults to $GITHUB_WORKSPACE or current dir)",
    )
    p.add_argument(
        "--apply-defaults",
        action="store_true",
        help="Apply configured additions/removals to files containing the default arrays (dry-run by default)",
    )
    p.add_argument(
        "--write",
        action="store_true",
        help="If set with --apply-defaults, write changes to files. Otherwise perform a dry-run.",
    )
    p.add_argument(
        "--patterns",
        help="Optional comma-separated glob patterns to limit files (e.g. 'build_files/**/*.sh,mods/**/*.sh')",
        default=None,
    )
    p.add_argument(
        "--backup-dir",
        help="Optional directory where timestamped backups will be written before changes are applied",
        default=None,
    )

    args = p.parse_args()

    bc = BuildCustomizer(repo_root=args.repo_root, backup_dir=args.backup_dir)

    # If requested, apply the configured defaults (removals then additions).
    if args.apply_defaults:
        patterns = None
        if args.patterns:
            patterns = [x.strip() for x in args.patterns.split(',') if x.strip()]
        results = bc.apply_defaults(patterns=patterns, dry_run=not args.write)

        # Print a concise summary to stdout
        for path, edits in results.items():
            print(path)
            for e in edits:
                # e is an ArrayEditResult
                print(f"  - changed={e.changed} before={e.before_count} after={e.after_count}")
        return

    # Default interactive action: list files containing any default arrays
    bc.find_files_with_any_default()


if __name__ == '__main__':
    _cli()
