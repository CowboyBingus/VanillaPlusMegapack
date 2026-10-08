"""Package only the audited public source inventory, without workspace history."""
import hashlib
import json
import zipfile
from privacy_audit import ROOT, SOURCE_FILES, audit
from package import release_directory
from build import VERSION


def main():
    audit(release_directory(ROOT)/f'Sentry-Aim-Retention-v{VERSION}.zip')
    destination=release_directory(ROOT)/f'Sentry-Aim-Retention-v{VERSION}-source.zip'
    destination.parent.mkdir(exist_ok=True)
    pending=ROOT/'build/source.pending.zip'
    with zipfile.ZipFile(pending,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for name in sorted(SOURCE_FILES):
            path=ROOT/name
            assert not path.is_symlink() and path.resolve().is_relative_to(ROOT)
            info=zipfile.ZipInfo('SentryAimRetention/'+name,date_time=(1980,1,1,0,0,0))
            info.compress_type=zipfile.ZIP_DEFLATED
            info.external_attr=0o100644<<16
            archive.writestr(info,path.read_bytes())
    with zipfile.ZipFile(pending) as archive:
        assert len(archive.namelist())==len(SOURCE_FILES)
        for name in SOURCE_FILES:
            assert archive.read('SentryAimRetention/'+name)==(ROOT/name).read_bytes()
    pending.replace(destination)
    digest=hashlib.sha256(destination.read_bytes()).hexdigest().upper()
    (ROOT/'build/source-release.json').write_text(json.dumps({
        'name':destination.name,'sha256':digest,'source_files':len(SOURCE_FILES),
        'includes_git_metadata':False},indent=2)+'\n',encoding='utf-8')
    print('PASS: audited source ZIP with '+str(len(SOURCE_FILES))+' files; no workspace or Git metadata')


if __name__=='__main__':
    main()
