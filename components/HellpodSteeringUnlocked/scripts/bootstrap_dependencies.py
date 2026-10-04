"""Fetch pinned source dependencies without replacing existing working copies."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def git(path, *args):
    return subprocess.run(['git', '-C', str(path), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Verify existing commits without network access')
    args = parser.parse_args()
    for dependency in json.loads((ROOT / 'dependencies.json').read_text())['dependencies']:
        path = ROOT / dependency['path']
        if not path.exists():
            if args.check:
                raise RuntimeError(f'Missing dependency: {dependency["path"]}')
            path.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['git', 'clone', '--no-checkout', '--filter=blob:none',
                            dependency['url'], str(path)], check=True)
            git(path, 'fetch', '--depth', '1', 'origin', dependency['commit'])
            git(path, 'checkout', '--detach', dependency['commit'])
        if not (path / '.git').exists():
            raise RuntimeError(f'Expected a Git checkout at {path}; existing files were preserved.')
        if git(path, 'rev-parse', 'HEAD') != dependency['commit']:
            raise RuntimeError(f'Unexpected revision at {path}; existing checkout was preserved.')
        print(f'{dependency["name"]}: {dependency["commit"]}')


if __name__ == '__main__':
    main()
