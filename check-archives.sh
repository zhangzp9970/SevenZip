#!/bin/bash
# Exercise real compound-archive decoding and the AppModel's nested-open handoff.
set -euo pipefail
ARCHIVE_APP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_BUILD_ROOT="$ARCHIVE_APP_ROOT/.build/archive-browser-check"
ARCHIVE_LIBRARY="${SEVENZIP_LIBRARY:-$ARCHIVE_APP_ROOT/dist/SevenZip.app/Contents/Frameworks/libSevenZip.dylib}"
if [[ ! -f "$ARCHIVE_LIBRARY" ]]; then
    echo "Missing dynamic library: $ARCHIVE_LIBRARY. Run ./build.sh first." >&2
    exit 1
fi
mkdir -p "$ARCHIVE_BUILD_ROOT/module-cache"
ARCHIVE_TEMP_PARENT="${TMPDIR:-/tmp}"
ARCHIVE_FIXTURES="$(mktemp -d "${ARCHIVE_TEMP_PARENT%/}/SevenZip-ArchiveChecks.XXXXXX")"
trap 'rm -rf -- "$ARCHIVE_FIXTURES"' EXIT
python3 - "$ARCHIVE_FIXTURES" <<'PY'
from pathlib import Path
import bz2, gzip, io, lzma, sys, tarfile, zipfile
root = Path(sys.argv[1])
samples = {'Read Me.txt': b'Hello from compressed TAR.\n',
           'Docs/notes.txt': 'Unicode notes: 中文\n'.encode(),
           'Docs/script.py': b'print("view source, never execute")\n'}
for path, data in samples.items():
    target = root / 'expected' / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode='w', format=tarfile.USTAR_FORMAT) as archive:
    directory = tarfile.TarInfo('Docs/')
    directory.type = tarfile.DIRTYPE
    directory.mode = 0o755
    archive.addfile(directory)
    for name, data in samples.items():
        entry = tarfile.TarInfo(name)
        entry.size = len(data)
        entry.mode = 0o755 if name.endswith('.py') else 0o644
        entry.mtime = 1_700_000_000
        archive.addfile(entry, io.BytesIO(data))
tar = buffer.getvalue()
(root / 'inner.tar').write_bytes(tar)
# gzip.compress omits the original filename: aliases must not depend on it.
gz = gzip.compress(tar, mtime=0)
for name in ['bundle.tar.gz', 'bundle.tgz', 'UpperCase.TAR.GZ']:
    (root / name).write_bytes(gz)
for name in ['bundle.tar.bz2', 'bundle.tbz', 'bundle.tbz2']:
    (root / name).write_bytes(bz2.compress(tar))
for name in ['bundle.tar.xz', 'bundle.txz']:
    (root / name).write_bytes(lzma.compress(tar, format=lzma.FORMAT_XZ))
(root / 'bundle.tar.lzma').write_bytes(lzma.compress(tar, format=lzma.FORMAT_ALONE))
# An unsafe original gzip filename must never select the temporary output path.
header = bytearray(gz[:10]); header[3] |= 8
(root / 'unsafe-name.tar.gz').write_bytes(header + str(root / 'escaped.tar').encode() + b'\0' + gz[10:])
(root / 'plain.txt.gz').write_bytes(gzip.compress(b'Plain gzip document.\n', mtime=0))
corrupt = bytearray(gz); corrupt[-8] ^= 0xff
(root / 'corrupt.tar.gz').write_bytes(corrupt)
(root / 'truncated.tar.gz').write_bytes(gz[:-10])
(root / 'not-a-tar.tar.gz').write_bytes(gzip.compress(b'not a tar archive', mtime=0))
empty = io.BytesIO()
with tarfile.open(fileobj=empty, mode='w'):
    pass
(root / 'empty.tar.gz').write_bytes(gzip.compress(empty.getvalue(), mtime=0))
unsafe = io.BytesIO()
with tarfile.open(fileobj=unsafe, mode='w', format=tarfile.USTAR_FORMAT) as archive:
    entry = tarfile.TarInfo('../escaped.txt'); entry.size = 1
    archive.addfile(entry, io.BytesIO(b'x'))
(root / 'unsafe-path.tar.gz').write_bytes(gzip.compress(unsafe.getvalue(), mtime=0))
with zipfile.ZipFile(root / 'inner.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('Nested.txt', b'Nested ZIP document.\n')
with zipfile.ZipFile(root / 'container.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in ['inner.tar', 'inner.zip', 'bundle.tar.gz']:
        archive.write(root / name, name)
# The actual handler, rather than only the suffix, must decide whether to unwrap.
(root / 'zip-disguised.tar.gz').write_bytes((root / 'container.zip').read_bytes())
PY
xcrun swiftc -target arm64-apple-macosx13.0 -parse-as-library -emit-library -emit-module \
    -module-name ArchiveCore -emit-module-path "$ARCHIVE_BUILD_ROOT/ArchiveCore.swiftmodule" \
    -I "$ARCHIVE_APP_ROOT/BridgeAPI/include" -module-cache-path "$ARCHIVE_BUILD_ROOT/module-cache" \
    "$ARCHIVE_APP_ROOT/Sources/ArchiveCore/ArchiveEngine.swift" \
    -Xlinker -install_name -Xlinker '@rpath/libArchiveCore.dylib' \
    -o "$ARCHIVE_BUILD_ROOT/libArchiveCore.dylib"
xcrun swiftc -target arm64-apple-macosx13.0 \
    -I "$ARCHIVE_BUILD_ROOT" -I "$ARCHIVE_APP_ROOT/BridgeAPI/include" \
    -L "$ARCHIVE_BUILD_ROOT" -lArchiveCore -Xlinker -rpath -Xlinker "$ARCHIVE_BUILD_ROOT" \
    -module-cache-path "$ARCHIVE_BUILD_ROOT/module-cache" \
    "$ARCHIVE_APP_ROOT/Sources/SevenZip/AppModel.swift" \
    "$ARCHIVE_APP_ROOT/Sources/SevenZip/BrowserHistory.swift" \
    "$ARCHIVE_APP_ROOT/Sources/SevenZip/BrowserSorting.swift" \
    "$ARCHIVE_APP_ROOT/Sources/SevenZip/TemporaryDocument.swift" \
    "$ARCHIVE_APP_ROOT/Sources/SevenZip/Localization.swift" \
    "$ARCHIVE_APP_ROOT/Checks/ArchiveBrowserSmoke.swift" \
    -o "$ARCHIVE_BUILD_ROOT/ArchiveBrowserSmoke"
"$ARCHIVE_BUILD_ROOT/ArchiveBrowserSmoke" "$ARCHIVE_LIBRARY" "$ARCHIVE_FIXTURES"
