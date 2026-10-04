"""Audit the explicit public source inventory, install ZIPs and Git history.

The package check accepts an entry with or without generated artwork: this mod
ships no banner or cover, so its manager ZIP carries no thumbnail.png.
"""
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
PATTERNS = {
    'personal_home_path': r'(?i)(?:[a-z]:[\\/]Users[\\/][^\s\\/]+|/(?:home|Users)/[a-z0-9_.-]+)',
    'unc_path': r'\\\\[a-zA-Z0-9][a-zA-Z0-9_.-]+\\[a-zA-Z0-9_$-]+',
    'email': r'\b[A-Za-z0-9_.+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b',
    'account_id': r'\b(?:7656119\d{10}|S-1-5-21-(?:\d+-){2}\d+(?:-\d+)?)\b',
    'hardware_detail': r'(?i)\b(?:nvid[i]a|gefor[c]e|rade[o]n|ryz[e]n|rtx\s*\d|gtx\s*\d|intel\s+(?:core|xeon)|\d+\s*(?:GB|GiB)\s+(?:RAM|VRAM)|(?:cpu|gpu|motherboard|monitor)\s*model|serial\s*(?:number|no[.]))',
    'private_key': r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    'credential_token': r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-)?[A-Za-z0-9_-]{24,}|AKIA[A-Z0-9]{16})\b',
    'credential_assignment': r"""(?i)\b(?:api_key|password|access_token|client_secret)\s*[:=]\s*["'][^"'\s]{8,}["']""",
    'international_phone': r'(?<![\w.])\+[1-9]\d{9,14}(?![\w.])',
    'private_session': r'(?i)\bPID\s*[:=]?\s*\d{2,}\b',
}

def sha(data):
    return hashlib.sha256(data).hexdigest().upper()

def scan(data, label, encoded=True):
    findings = set()
    identities = {getpass.getuser(), os.environ.get('USERNAME', ''), os.environ.get('COMPUTERNAME', '')}
    for encoding in ('utf-8', 'utf-16-le', 'utf-16-be'):
        text = data.decode(encoding, errors='ignore')
        for name, pattern in PATTERNS.items():
            if re.search(pattern, text): findings.add(name)
        for identity in identities:
            if len(identity) > 3 and re.search(r'(?i)(?<!\w)' + re.escape(identity) + r'(?!\w)', text):
                findings.add('local_identity')
        for match in re.finditer(r'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])', text):
            try: address = ipaddress.ip_address(match[0])
            except ValueError: continue
            if not address.is_unspecified: findings.add('network_address')
    if encoded:
        text = data.decode('utf-8', errors='ignore')
        for match in re.finditer(r'(?<![0-9a-fA-F])[0-9a-fA-F]{32,}(?![0-9a-fA-F])', text):
            if len(match[0]) % 2 == 0:
                for finding in scan(bytes.fromhex(match[0]), label, False): findings.add(finding['category'])
        for match in re.finditer(r'(?:\\\d{1,3}){4,}', text):
            values = list(map(int, re.findall(r'\d+', match[0])))
            if max(values) < 256:
                for finding in scan(bytes(values), label, False): findings.add(finding['category'])
    return [{'file': label, 'category': category} for category in sorted(findings)]

def png(data):
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    offset, kinds = 8, []
    while offset < len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        end = offset + 12 + size
        assert end <= len(data)
        assert zlib.crc32(data[offset+4:end-4]) & 0xffffffff == struct.unpack_from('>I', data, end-4)[0]
        assert kind in (b'IHDR', b'PLTE', b'tRNS', b'IDAT', b'IEND'), 'Unreviewed PNG metadata'
        kinds.append(kind);offset = end
    assert offset == len(data) and kinds[0] == b'IHDR' and kinds[-1] == b'IEND'
    return struct.unpack_from('>II', data, 16)

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def audit(packages=(), history=False):
    allowed = json.loads((ROOT / 'publication-files.json').read_text(encoding='utf-8'))
    assert len(allowed) == len(set(allowed)) and 'publication-files.json' in allowed
    findings, inventory, archives = [], [], []
    def inspect(data, label):
        if label.endswith('.png'): png(data)
        else: findings.extend(scan(data, label))
    for name in allowed:
        path = ROOT / name
        assert not path.is_symlink() and path.resolve().is_relative_to(ROOT)
        assert path.suffix not in ('.exe', '.dll', '.dmp', '.i64', '.idb', '.zip', '.log')
        data = path.read_bytes();inspect(data, name)
        inventory.append({'path': name, 'bytes': len(data), 'sha256': sha(data)})
    if history:
        assert Path(git('rev-parse', '--show-toplevel').decode().strip()).resolve() == ROOT
        indexed = git('ls-files', '-z').decode().split('\0')[:-1]
        assert set(indexed) == set(allowed), 'Unexpected Git inventory'
        for name in allowed:
            assert git('show', ':' + name) == (ROOT / name).read_bytes(), 'Index differs from audit: ' + name
        for commit in git('rev-list', '--all').decode().splitlines():
            names = git('ls-tree', '-r', '--name-only', commit).decode().splitlines()
            historical = (json.loads(git('show', commit + ':publication-files.json'))
                          if 'publication-files.json' in names else names)
            assert len(historical) == len(set(historical))
            assert set(names) == set(historical), 'Unexpected historical tree'
            assert set(historical) <= set(allowed), 'Unreviewed historical file'
            for name in names: inspect(git('show', commit + ':' + name), 'history/' + name)
            fields = git('show', '-s', '--format=%an%x00%ae%x00%cn%x00%ce%x00%B', commit).split(b'\0')
            assert fields[0] == fields[2] == b'CowboyBingus'
            for email in (fields[1], fields[3]):
                assert re.fullmatch(rb'(?:\d+\+)?CowboyBingus@users\.noreply\.github\.com', email)
            findings.extend(scan(fields[4], 'commit-message'))
    for path in packages:
        with zipfile.ZipFile(path) as archive:
            assert archive.comment == b'' and archive.testzip() is None
            names = archive.namelist();assert len(names) == len(set(names))
            provenance_name = next(n for n in names if n.endswith('-manifest.json'))
            slug = provenance_name.removesuffix('-manifest.json')
            expected = {'manifest.json', provenance_name, slug + '-README.txt'}
            if 'thumbnail.png' in names:
                expected.add('thumbnail.png')
            expected |= {'data/9ba626afa44a3aa3.patch_0' + s for s in ('', '.stream', '.gpu_resources')}
            assert set(names) == expected
            provenance = json.loads(archive.read(provenance_name))
            for name, digest in provenance['files'].items(): assert sha(archive.read(name)) == digest
            for item in archive.infolist():
                assert not item.extra and not item.comment and item.date_time == (1980, 1, 1, 0, 0, 0)
                assert item.external_attr >> 16 == 0o100644
                inspect(archive.read(item), 'ZIP/' + item.filename)
        archives.append({'file': path.name, 'sha256': sha(path.read_bytes())})
    result = {'source': inventory, 'archives': archives, 'git_history_verified': history, 'findings': findings}
    output = ROOT / 'build/privacy-audit.json';output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    if findings:
        print(json.dumps(findings, indent=2))
        raise SystemExit('Privacy audit failed; matching values are intentionally omitted.')
    print(f'PASS: {len(inventory)} allowlisted source files, {len(archives)} install ZIPs; no identifying-pattern matches; PNG metadata and optional Git history checked')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zip', action='append', type=Path, default=[])
    parser.add_argument('--git', action='store_true')
    args = parser.parse_args();audit(args.zip, args.git)
