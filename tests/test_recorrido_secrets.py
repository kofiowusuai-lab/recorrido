from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

SECRET_PATTERNS = (
    re.compile(r"sk_(?:live|test)_[A-Za-z0-9]{16,}"),
    re.compile(r"sb_secret_[A-Za-z0-9._-]{16,}"),
    re.compile(r"EA[A-Za-z0-9]{40,}"),
)


def test_local_secret_files_are_ignored_and_example_exists():
    gitignore = (ROOT / ".gitignore").read_text()
    assert ".env" in gitignore
    assert ".env.local" in gitignore
    assert ".env.*" in gitignore
    assert "!.env.example" in gitignore
    assert "supabase/.temp/" in gitignore
    assert (ROOT / ".env.example").is_file()


def test_tracked_source_contains_no_obvious_live_credentials():
    excluded_parts = {".git", ".worktrees", "production", "media", "accounts"}
    text_suffixes = {".py", ".ts", ".tsx", ".js", ".json", ".toml", ".sql", ".md", ".env", ""}

    for path in ROOT.rglob("*"):
        if not path.is_file() or any(part in excluded_parts for part in path.parts):
            continue
        if path.suffix not in text_suffixes and path.name != ".env.example":
            continue
        try:
            content = path.read_text(errors="ignore")
        except OSError:
            continue
        for pattern in SECRET_PATTERNS:
            assert pattern.search(content) is None, f"possible live credential in {path.relative_to(ROOT)}"
