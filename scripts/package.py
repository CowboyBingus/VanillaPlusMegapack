"""Create a reproducible mod-manager ZIP from verified build outputs."""
import hashlib
import json
from pathlib import Path
import zipfile


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def release_directory(root: Path) -> Path:
    base = root.parent if (root.parent / 'scripts/archive.py').is_file() else root
    return base / 'releases'


def package_release(root: Path, build: Path, report: dict) -> Path:
    files = {}
    for destination, source in report['deployment_files'].items():
        data = (root / source).read_bytes()
        if digest(data) != report['files'][source]:
            raise ValueError('Build output changed before packaging: ' + source)
        files[destination] = data
    slug = report['slug']
    # Public names share one format; provenance keeps the internal build revision.
    release_version = 'v' + str(report.get('version') or report['revision']).rsplit('v', 1)[-1]
    display_name = report['name'] + ' - ' + release_version
    release_stem = report['name'].replace(' ', '-') + '-' + release_version
    files[slug + '-README.txt'] = (root / report.get('install_instructions', 'INSTALL.txt')).read_bytes()
    thumbnail = root / 'assets/thumbnail.png'
    if thumbnail.is_file():
        files['thumbnail.png'] = thumbnail.read_bytes()
    provenance = {
        'name': report['name'], 'revision': report['revision'], 'display_version': release_version,
        'steam_build': 25480438, 'exe_version': '1.8.46015.0',
        'game_exe_sha256': report['game_exe_sha256'],
        'game_dll_sha256': report['game_dll_sha256'],
        'runtime_verified': report.get('runtime_verified', False),
        'files': {name: digest(data) for name, data in files.items()},
    }
    for key in ('requires', 'components', 'resource_sha256', 'loader_bundled', 'boot_replaced'):
        if key in report:
            provenance[key] = report[key]
    files[slug + '-manifest.json'] = (json.dumps(provenance, indent=2) + '\n').encode()
    options = [dict(option) for option in report['options']]
    manager = {'Version': 1, 'Guid': report['guid'], 'Name': display_name,
               'Description': report['description'], 'Options': options}
    if thumbnail.is_file():
        manager['IconPath'] = 'thumbnail.png'
        for option in options:
            option['Image'] = 'thumbnail.png'
    files['manifest.json'] = (json.dumps(manager, indent=2) + '\n').encode()
    release = release_directory(root) / (release_stem + '.zip')
    release.parent.mkdir(exist_ok=True)
    temporary = build / 'release.pending.zip'
    with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data)
    temporary.replace(release)
    (build / (release.name + '.sha256')).write_text(digest(release.read_bytes()) + '  ' + release.name + '\n')
    return release
