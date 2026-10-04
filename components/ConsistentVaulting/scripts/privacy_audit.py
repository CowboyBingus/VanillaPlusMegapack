"""Audit an explicit publication inventory without printing sensitive matches."""
import argparse
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
SOURCE_FILES = (
    'publication-files.json',
    'CHANGELOG.md',
    '.gitattributes', '.gitignore', 'CONTRIBUTING.md', 'INSTALL.txt', 'README.md',
    'docs/MIGRATION_VALIDATION.md', 'docs/RELEASE_NOTES.md', 'tests/frame_budget.lua', 'tests/test_raised_approach.lua', 'LICENSE', 'THIRD_PARTY.md', 'dependencies.json',
    'assets/ARTWORK.md', 'assets/banner.png', 'assets/thumbnail.png',
    'docs/PRIVACY.md', 'docs/TECHNICAL.md',
    'scripts/archive.py', 'scripts/build.py', 'scripts/module.py',
    'scripts/package.py', 'scripts/privacy_audit.py',
    'src/archive_loader.lua', 'src/bingus_memory.lua', 'src/bingus_runtime.lua', 'src/bingus_write.lua', 'src/slope_assist.lua', 'src/vault_data.lua',
    'src/windows_api.lua',
    'tests/test_geometry.lua', 'tests/test_loader.lua', 'tests/test_package.py',
    'tests/test_slope.lua', 'tests/test_vault.lua',
)
PATTERNS = {
    'research_session': r'(?i)\bPID\s*[:=]?\s*\d{2,}\b',
    'personal_home_path': r'(?i)(?:[a-z]:[\\/]Users[\\/][^\s\\/]+|/(?:home|Users)/[a-z0-9_.-]+)',
    'unc_path': r'\\\\[a-zA-Z0-9][a-zA-Z0-9_.-]+\\[a-zA-Z0-9_$-]+',
    'email': r'\b[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b',
    'account_id': r'\b(?:7656119\d{10}|S-1-5-21-(?:\d+-){2}\d+(?:-\d+)?)\b',
    'private_key': r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    'credential_token': r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-)?[A-Za-z0-9_-]{24,}|AKIA[A-Z0-9]{16})\b',
    'credential_assignment': r'''(?i)\b(?:api_key|password|access_token|client_secret)\s*[:=]\s*["'][^"'\s]{8,}["']''',
    'international_phone': r'(?<![\w.])\+[1-9]\d{9,14}(?![\w.])',
}


def inspect_png(data):
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'Invalid PNG signature'
    offset, chunks, dimensions = 8, [], None
    while offset < len(data):
        length, kind = struct.unpack_from('>I4s', data, offset)
        end = offset + 12 + length
        assert end <= len(data), 'Truncated PNG'
        assert zlib.crc32(data[offset+4:end-4]) & 0xffffffff == struct.unpack_from('>I', data, end-4)[0], 'PNG CRC'
        assert kind in (b'IHDR', b'PLTE', b'tRNS', b'IDAT', b'IEND'), 'PNG contains ancillary metadata'
        if kind == b'IHDR': dimensions = struct.unpack_from('>II', data, offset+8)
        chunks.append(kind.decode('ascii'));offset = end
    assert chunks[0] == 'IHDR' and chunks[-1] == 'IEND' and 'IDAT' in chunks
    return {'dimensions': dimensions, 'chunks': sorted(set(chunks))}


def scan_text(data, label):
    findings = set()
    identities = {getpass.getuser(), os.environ.get('USERNAME', ''), os.environ.get('COMPUTERNAME', '')}
    for encoding in ('utf-8', 'utf-16-le', 'utf-16-be'):
        text = data.decode(encoding, errors='ignore')
        for name, pattern in PATTERNS.items():
            if re.search(pattern, text): findings.add(name)
        for identity in identities:
            if len(identity) > 3 and re.search(r'(?i)(?<!\w)'+re.escape(identity)+r'(?!\w)', text):
                findings.add('local_identity')
        for match in re.finditer(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])', text):
            try: address = ipaddress.ip_address(match[0])
            except ValueError: continue
            if not address.is_unspecified: findings.add('network_address')
    return [{'file': label, 'category': category} for category in sorted(findings)]


def audit(package=None, staged=False, git_inventory=False, history=False):
    entries, findings = [], []
    for name in SOURCE_FILES:
        data = (ROOT/name).read_bytes()
        entry = {'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
        if name.endswith('.png'): entry['png'] = inspect_png(data)
        else: findings.extend(scan_text(data, name))
        entries.append(entry)
    if staged:
        indexed = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')[:-1]
        assert set(indexed) == set(SOURCE_FILES), 'Git inventory differs from the reviewed source allowlist'
        for name in indexed:
            data = subprocess.check_output(['git', 'show', ':'+name], cwd=ROOT)
            assert data == (ROOT/name).read_bytes(), 'Staged file differs from reviewed source: '+name
    if git_inventory:
        tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')[:-1]
        untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')[:-1]
        assert set(tracked + untracked) == set(SOURCE_FILES), 'Git working inventory differs from reviewed source allowlist'
    history_commits = 0
    if history:
        commits = subprocess.check_output(['git', 'rev-list', '--all'], cwd=ROOT).decode().splitlines()
        for commit in commits:
            history_commits += 1
            names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', commit], cwd=ROOT).decode().splitlines()
            for name in names:
                assert name in SOURCE_FILES, 'Unreviewed historical source path: ' + name
                data = subprocess.check_output(['git', 'show', commit + ':' + name], cwd=ROOT)
                if name.endswith('.png'): inspect_png(data)
                else: findings.extend(scan_text(data, 'history:' + commit[:8] + ':' + name))
            metadata = subprocess.check_output(['git', 'show', '-s', '--format=%an%x00%ae%x00%cn%x00%ce%x00%B', commit], cwd=ROOT)
            for index, field in enumerate(metadata.split(b'\0')):
                if index in (1, 3) and re.fullmatch(rb'[A-Za-z0-9+_.-]+@users\.noreply\.github\.com', field):
                    continue
                findings.extend(scan_text(field, 'commit:' + commit[:8]))
    zip_entries = []
    if package:
        with zipfile.ZipFile(package) as archive:
            assert archive.comment == b''
            names = archive.namelist();assert len(names) == len(set(names))
            expected = {'manifest.json', 'ConsistentVaulting-manifest.json', 'ConsistentVaulting-README.txt', 'thumbnail.png'}
            expected |= {'data/9ba626afa44a3aa3.patch_0'+s for s in ('', '.stream', '.gpu_resources')}
            assert set(names) == expected, 'Unreviewed package entry'
            for item in archive.infolist():
                assert not item.extra and not item.comment and item.date_time == (1980,1,1,0,0,0)
                assert item.external_attr >> 16 == 0o100644
                data = archive.read(item)
                if item.filename.endswith('.png'): inspect_png(data)
                else: findings.extend(scan_text(data, 'ZIP:'+item.filename))
                zip_entries.append({'path':item.filename, 'bytes':len(data), 'sha256':hashlib.sha256(data).hexdigest()})
    report = {'source_files':entries, 'zip_entries':zip_entries, 'git_index_verified':staged, 'git_working_inventory_verified':git_inventory,
              'history_commits_reviewed':history_commits, 'findings':findings,
              'scope':'Explicit source inventory and supplied installable ZIP; surrounding workspace and private research excluded.'}
    output = ROOT/'build/privacy-audit.json';output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    if findings:
        print(json.dumps(findings, indent=2));raise SystemExit('Privacy review failed; matching values were not printed.')
    print(f'PASS: {len(entries)} source files, {len(zip_entries)} ZIP entries; no privacy-pattern matches; PNG metadata checked')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zip', type=Path)
    parser.add_argument('--staged', action='store_true')
    parser.add_argument('--git', action='store_true', help='Check tracked and untracked publication inventory')
    parser.add_argument('--history', action='store_true', help='Scan reachable source history and commit identities')
    args = parser.parse_args();audit(args.zip, args.staged, args.git, args.history)
