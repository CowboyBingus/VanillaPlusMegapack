"""Turns every vanilla_plus_megapack.dll+0x... in a log into the function and source line it points at.

Usage: python scripts/symbolize.py <log file | lines...> [--symbols <dll or pdb>] [--dir <symbols folder>]
       python scripts/symbolize.py --list --symbols <dll or pdb> [<function name>...]
       python scripts/symbolize.py --check <release dll> --symbols <symbols dll>

Reads stdin when given no log ("-" also means stdin). The offsets are RVAs in the shipped (stripped) DLL. The symbols
are the unstripped build of the same commit: scripts/build.ps1 writes build/symbols/vanilla_plus_megapack-<commit>.dll
and its .pdb, and scripts/package.ps1 zips them beside the release. By default the commit comes from the log's
identity line, "[core] Vanilla Plus Megapack <version> (commit <hash>, built <date>)", and the symbols from --dir
(build/symbols/ by default); --symbols names them outright.

Zig 0.17 (x86_64-windows-gnu, -g) links with lld-link and writes CodeView into a PDB beside the DLL, not DWARF in the
PE. No PDB reader is installed on the build machine (no llvm-symbolizer, llvm-addr2line or llvm-pdbutil), so this file
reads the PDB with the standard library only: the MSF container, the DBI stream's modules, each module's procedure
records (S_GPROC32/S_LPROC32 and their _ID forms) and C13 line tables, the file checksums with the /names string
table, the section headers stream, and the publics (S_PUB32) for code without line info. An offset inside a function
another was inlined into gives the line of the call in the outer function.

The symbols build compiles with -gline-tables-only: full -g changes clang's code generation in places (Better Lobby
Management's Apply grows by 0x40 bytes), line tables alone do not. Its link keeps more of Zig's C runtime than the
stripped one, so the pack's own code sits at the same offsets in both, while the C runtime after it does not, and
rip-relative references to the data sections differ by how far those moved. --check verifies exactly that.
"""
from __future__ import annotations

import argparse
import bisect
import os
import re
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

MSF_MAGIC = b"Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0"
S_PUB32 = 0x110E
PROC_KINDS = {0x110F, 0x1110, 0x1146, 0x1147}  # S_LPROC32, S_GPROC32, S_LPROC32_ID, S_GPROC32_ID
DEBUG_S_LINES = 0xF2
DEBUG_S_FILECHKSMS = 0xF4
OFFSET_PATTERN = re.compile(r"vanilla_plus_megapack\.dll\+0x([0-9A-Fa-f]+)")
COMMIT_PATTERN = re.compile(r"Vanilla Plus Megapack \S+ \(commit ([0-9A-Za-z]+(?:-dirty)?)")
# The pack's own sources, as their paths end in the PDB (absolute paths of the machine that built it).
PACK_SOURCES = ("/src/core/", "/src/components/", "/src/components.c")


class PdbError(Exception):
    pass


@dataclass
class Function:
    rva: int
    size: int
    name: str
    # (rva, line, file) of each line-table row, sorted by rva.
    lines: list[tuple[int, int, str]] = field(default_factory=list)

    @property
    def source(self) -> str:
        return self.lines[0][2].replace("\\", "/") if self.lines else ""


def _cstr(data: bytes, offset: int) -> str:
    end = data.index(b"\0", offset)
    return data[offset:end].decode("utf-8", "replace")


def _short(source: str) -> str:
    normal = source.replace("\\", "/")
    for marker in ("/src/", "/lib/"):
        at = normal.rfind(marker)
        if at >= 0:
            return normal[at + 1:]
    return normal


class Msf:
    """The MSF 7.0 container: numbered streams made of fixed-size blocks."""

    def __init__(self, data: bytes):
        if not data.startswith(MSF_MAGIC):
            raise PdbError("not an MSF 7.0 PDB")
        self.data = data
        self.block_size, _, _, directory_bytes, _, block_map = struct.unpack_from("<6I", data, len(MSF_MAGIC))
        count = -(-directory_bytes // self.block_size)
        directory_blocks = struct.unpack_from(f"<{count}I", data, block_map * self.block_size)
        directory = b"".join(self._block(b) for b in directory_blocks)[:directory_bytes]
        streams = struct.unpack_from("<I", directory)[0]
        sizes = struct.unpack_from(f"<{streams}I", directory, 4)
        cursor = 4 + 4 * streams
        self.streams: list[tuple[int, tuple[int, ...]]] = []
        for size in sizes:
            if size == 0xFFFFFFFF:
                self.streams.append((0, ()))
                continue
            n = -(-size // self.block_size)
            self.streams.append((size, struct.unpack_from(f"<{n}I", directory, cursor)))
            cursor += 4 * n

    def _block(self, index: int) -> bytes:
        return self.data[index * self.block_size:(index + 1) * self.block_size]

    def stream(self, index: int) -> bytes:
        if index >= len(self.streams):
            raise PdbError(f"no stream {index}")
        size, blocks = self.streams[index]
        return b"".join(self._block(b) for b in blocks)[:size]


def _subsections(data: bytes, start: int, end: int) -> list[tuple[int, bytes]]:
    found = []
    while start + 8 <= end:
        kind, length = struct.unpack_from("<2I", data, start)
        found.append((kind & 0x7FFFFFFF, data[start + 8:start + 8 + length]))
        start += 8 + ((length + 3) & ~3)
    return found


class Pdb:
    def __init__(self, path: Path):
        self.path = path
        self.msf = Msf(path.read_bytes())
        self.guid, named = self._info()
        self.names = self._names(named.get("/names"))
        self.sections: list[tuple[int, int]] = []  # (rva, virtual size), section numbers from 1
        self.functions: list[Function] = []
        self.publics: list[tuple[int, str]] = []
        self._dbi()
        self.functions.sort(key=lambda f: f.rva)
        self.publics.sort()
        self._starts = [f.rva for f in self.functions]
        self._public_starts = [p[0] for p in self.publics]
        pack = [f.rva + f.size for f in self.functions if any(m in f.source for m in PACK_SOURCES)]
        # Where the pack's own code ends and the C runtime's begins (the linker puts the pack's objects first).
        self.pack_end = max(pack) if pack else 0

    def _info(self) -> tuple[bytes, dict[str, int]]:
        info = self.msf.stream(1)
        guid = info[12:28]
        cursor = 28
        buffer_size = struct.unpack_from("<I", info, cursor)[0]
        buffer = info[cursor + 4:cursor + 4 + buffer_size]
        cursor += 4 + buffer_size
        size = struct.unpack_from("<I", info, cursor)[0]
        cursor += 8
        for _ in range(2):  # the present and deleted bit vectors
            cursor += 4 + 4 * struct.unpack_from("<I", info, cursor)[0]
        named = {}
        for _ in range(size):
            key, value = struct.unpack_from("<2I", info, cursor)
            cursor += 8
            named[_cstr(buffer, key)] = value
        return guid, named

    def _names(self, index: int | None) -> bytes:
        if index is None:
            return b""
        data = self.msf.stream(index)
        signature, _, size = struct.unpack_from("<3I", data)
        if signature != 0xEFFEEFFE:
            raise PdbError("bad /names stream")
        return data[12:12 + size]

    def _dbi(self) -> None:
        dbi = self.msf.stream(3)
        (_, _, _, _, _, _, _, sym_records, _, modinfo_size, contrib_size, map_size, source_size, server_size, _,
         optional_size, ec_size, _, _, _) = struct.unpack_from("<iIIHHHHHHiiiiiIiiHHI", dbi)
        optional_at = 64 + modinfo_size + contrib_size + map_size + source_size + server_size + ec_size
        optional = struct.unpack_from(f"<{optional_size // 2}H", dbi, optional_at)
        if len(optional) > 5 and optional[5] != 0xFFFF:
            headers = self.msf.stream(optional[5])
            for at in range(0, len(headers) - 39, 40):
                virtual_size, rva = struct.unpack_from("<2I", headers, at + 8)
                self.sections.append((rva, virtual_size))
        modules = dbi[64:64 + modinfo_size]
        cursor = 0
        while cursor + 64 <= len(modules):
            stream, sym_bytes, c11_bytes, c13_bytes = struct.unpack_from("<HIII", modules, cursor + 34)
            name_end = modules.index(b"\0", cursor + 64)
            object_end = modules.index(b"\0", name_end + 1)
            cursor = (object_end + 1 + 3) & ~3
            if stream != 0xFFFF:
                data = self.msf.stream(stream)
                lines_at = sym_bytes + c11_bytes  # the C13 line tables follow the symbols and any old C11 lines
                self._module(data, sym_bytes, _subsections(data, lines_at, lines_at + c13_bytes))
        if sym_records != 0xFFFF:
            self._publics(self.msf.stream(sym_records))

    def rva(self, segment: int, offset: int) -> int | None:
        if 1 <= segment <= len(self.sections):
            return self.sections[segment - 1][0] + offset
        return None

    def _procedures(self, data: bytes, sym_bytes: int) -> list[Function]:
        procs = []
        cursor = 4
        while cursor + 4 <= sym_bytes:
            length, kind = struct.unpack_from("<2H", data, cursor)
            if kind in PROC_KINDS:
                code_size = struct.unpack_from("<I", data, cursor + 16)[0]
                offset, segment = struct.unpack_from("<IH", data, cursor + 32)
                rva = self.rva(segment, offset)
                if rva is not None:
                    procs.append(Function(rva, code_size, _cstr(data, cursor + 39)))
            cursor += 2 + length
        return procs

    def _files(self, body: bytes) -> dict[int, str]:
        files = {}
        at = 0
        while at + 6 <= len(body):
            name, checksum_size = struct.unpack_from("<IB", body, at)
            files[at] = _cstr(self.names, name) if name < len(self.names) else "?"
            at = (at + 6 + checksum_size + 3) & ~3
        return files

    def _line_rows(self, body: bytes, files: dict[int, str]) -> list[tuple[int, int, str]]:
        offset, segment, _, _ = struct.unpack_from("<IHHI", body)
        base = self.rva(segment, offset)
        if base is None:
            return []
        rows = []
        at = 12
        while at + 12 <= len(body):
            checksum_at, count, block_size = struct.unpack_from("<3I", body, at)
            source = files.get(checksum_at, "?")
            for row in range(count):
                line_offset, packed = struct.unpack_from("<2I", body, at + 12 + 8 * row)
                rows.append((base + line_offset, packed & 0xFFFFFF, source))
            at += max(block_size, 12)
        return rows

    def _module(self, data: bytes, sym_bytes: int, subsections: list[tuple[int, bytes]]) -> None:
        procs = self._procedures(data, sym_bytes)
        files: dict[int, str] = {}
        for kind, body in subsections:
            if kind == DEBUG_S_FILECHKSMS:
                files.update(self._files(body))
        rows: list[tuple[int, int, str]] = []
        for kind, body in subsections:
            if kind == DEBUG_S_LINES:
                rows.extend(self._line_rows(body, files))
        rows.sort()
        starts = [r[0] for r in rows]
        for proc in procs:
            proc.lines = rows[bisect.bisect_left(starts, proc.rva):bisect.bisect_left(starts, proc.rva + proc.size)]
        self.functions.extend(procs)

    def _publics(self, data: bytes) -> None:
        cursor = 0
        while cursor + 4 <= len(data):
            length, kind = struct.unpack_from("<2H", data, cursor)
            if kind == S_PUB32:
                flags, offset, segment = struct.unpack_from("<IIH", data, cursor + 4)
                rva = self.rva(segment, offset)
                if rva is not None and flags & 2:  # cvpsfFunction
                    self.publics.append((rva, _cstr(data, cursor + 14)))
            cursor += 2 + length

    def lookup(self, rva: int) -> str:
        """The function and line at rva, for an offset in the stripped DLL."""
        if rva >= self.pack_end and self.sections and rva < self.sections[0][0] + self.sections[0][1]:
            return "the C runtime (its code is laid out differently in the stripped DLL)"
        at = bisect.bisect_right(self._starts, rva) - 1
        if at >= 0 and rva < self.functions[at].rva + self.functions[at].size:
            function = self.functions[at]
            rows = [r[0] for r in function.lines]
            row = bisect.bisect_right(rows, rva) - 1
            where = f" ({_short(function.lines[row][2])}:{function.lines[row][1]})" if row >= 0 else ""
            return f"{function.name}+0x{rva - function.rva:X}{where}"
        at = bisect.bisect_right(self._public_starts, rva) - 1
        if at >= 0 and rva < self.pack_end:
            start, name = self.publics[at]
            return f"{name}+0x{rva - start:X} (no line info)"
        return "not in the pack's code"


def pdb_for(path: Path) -> Path:
    """A .pdb as is; for a .dll the PDB beside it with the same stem."""
    if path.suffix.lower() == ".pdb":
        return path
    candidate = path.with_suffix(".pdb")
    if not candidate.exists():
        raise PdbError(f"no {candidate.name} beside {path}")
    return candidate


class Pe:
    """The few parts of a PE image the checks need: sections, the exception table and the CodeView record."""

    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        pe = struct.unpack_from("<I", self.data, 0x3C)[0]
        if self.data[pe:pe + 4] != b"PE\0\0":
            raise PdbError(f"{path.name} is not a PE image")
        count, _, _, _, optional_size = struct.unpack_from("<HIIIH", self.data, pe + 6)
        self.directories = pe + 24 + 112  # PE32+ data directories
        self.sections: dict[str, tuple[int, int, int, int]] = {}  # name: (rva, virtual size, file offset, raw size)
        headers = pe + 24 + optional_size
        for at in range(headers, headers + 40 * count, 40):
            name = self.data[at:at + 8].rstrip(b"\0").decode("ascii", "replace")
            virtual_size, rva, raw_size, raw_offset = struct.unpack_from("<4I", self.data, at + 8)
            self.sections[name] = (rva, virtual_size, raw_offset, raw_size)

    def bytes_at(self, rva: int, size: int) -> bytes:
        for start, virtual_size, raw_offset, raw_size in self.sections.values():
            if start <= rva < start + virtual_size:
                at = raw_offset + rva - start
                return self.data[at:at + max(0, min(size, start + raw_size - rva))]
        return b""

    def section_of(self, rva: int) -> tuple[str, int] | None:
        for name, (start, virtual_size, _, _) in self.sections.items():
            if start <= rva < start + virtual_size:
                return name, rva - start
        return None

    def functions(self) -> list[tuple[int, int]]:
        """(start, end) of every .pdata entry."""
        rva, size = struct.unpack_from("<2I", self.data, self.directories + 3 * 8)
        table = self.bytes_at(rva, size)
        return [struct.unpack_from("<2I", table, at) for at in range(0, len(table) - 11, 12)]

    def debug_id(self) -> bytes | None:
        """The PDB GUID the CodeView debug record names (None for a stripped DLL)."""
        rva, size = struct.unpack_from("<2I", self.data, self.directories + 6 * 8)
        table = self.bytes_at(rva, size)
        for at in range(0, len(table) - 27, 28):
            kind, _, record_rva = struct.unpack_from("<3I", table, at + 12)
            record = self.bytes_at(record_rva, 24)
            if kind == 2 and record[:4] == b"RSDS":
                return record[4:20]
        return None


def load_symbols(path: Path) -> Pdb:
    pdb = Pdb(pdb_for(path))
    if path.suffix.lower() == ".dll":
        debug_id = Pe(path).debug_id()
        if debug_id is not None and debug_id != pdb.guid:
            raise PdbError(f"{path.name} and {pdb.path.name} are from different builds")
    return pdb


def _reference(release: Pe, symbols: Pe, rva: int, pack_end: int) -> tuple[str, int, int] | None:
    """The 4 bytes at rva read as a rip-relative displacement (or a rel32 call or jump) in both images: (section,
    offset in the release, offset in the symbols build) when both reach the same section, the pack's code at the same
    offset, or the C runtime's code (which the two links lay out differently); None otherwise. The instruction's end is
    unknown, but it is the same in both images, so the two offsets compare the same either way."""
    old = release.bytes_at(rva, 4)
    new = symbols.bytes_at(rva, 4)
    if len(old) < 4 or len(new) < 4:
        return None
    old_target = rva + 4 + struct.unpack("<i", old)[0]
    new_target = rva + 4 + struct.unpack("<i", new)[0]
    old_place = release.section_of(old_target)
    new_place = symbols.section_of(new_target)
    if old_place is None or new_place is None or old_place[0] != new_place[0]:
        return None
    if old_place[0] == ".text":
        if old_target >= pack_end and new_target >= pack_end:
            return ".text (C runtime)", 0, 0
        if old_target != new_target:
            return None
    return old_place[0], old_place[1], new_place[1]


def _consistent(places: dict[str, dict[int, int]]) -> list[str]:
    """Every data item referenced must move as one: each release offset maps to one offset in the symbols build, and
    the order of items in each section is kept."""
    problems = []
    for section, moves in places.items():
        pairs = sorted(moves.items())
        if any(b[1] <= a[1] for a, b in zip(pairs, pairs[1:])):
            problems.append(f"the references into {section} do not keep their order")
    return problems


def check_same_code(release_path: Path, symbols_path: Path) -> tuple[list[str], dict[str, int]]:
    """Compares the pack's code in the shipped DLL with the symbols build: every function at the same offsets, and every
    differing byte part of a reference that reaches the same place. Returns the problems (none when they agree) and
    counts of what differs."""
    pdb = load_symbols(symbols_path)
    release = Pe(release_path)
    symbols = Pe(symbols_path)
    end = pdb.pack_end
    ours = [f for f in release.functions() if f[0] < end]
    theirs = [f for f in symbols.functions() if f[0] < end]
    counts = {"functions": len(theirs), "bytes": end - symbols.sections[".text"][0], "references": 0}
    if not theirs or ours != theirs:
        first = next((a for a, b in zip(ours, theirs) if a != b), (end, end))
        return [f"function bounds differ from 0x{first[0]:X} ({pdb.lookup(first[0])})"], counts
    start = symbols.sections[".text"][0]
    old = release.bytes_at(start, end - start)
    new = symbols.bytes_at(start, end - start)
    def candidates(at: int) -> list[tuple[int, tuple[str, int, int]]]:
        found = []
        for window in range(max(0, at - 3), at + 1):
            reference = _reference(release, symbols, start + window, end)
            if reference is not None:
                found.append((window, reference))
        return found

    # Which 4 bytes hold the displacement is not known without decoding the instruction, and a wrong guess can still
    # land in the large .data section. Pass 1 learns how far each section's items moved from the differing bytes with
    # one reading only; pass 2 prefers, for each, the reading that moved the most common way.
    differing = [at for at in range(len(old)) if old[at] != new[at]]
    moved: dict[tuple[str, int], int] = {}
    for at in differing:
        found = candidates(at)
        if len(found) == 1:
            section, old_offset, new_offset = found[0][1]
            key = (section, new_offset - old_offset)
            moved[key] = moved.get(key, 0) + 1
    problems: list[str] = []
    places: dict[str, dict[int, int]] = {}
    covered = -1
    for at in differing:
        if at <= covered:
            continue
        found = candidates(at)
        if not found:
            problems.append(f"code differs at 0x{start + at:X} ({pdb.lookup(start + at)})")
            if len(problems) >= 10:
                break
            continue
        window, (section, old_offset, new_offset) = max(
            found, key=lambda c: moved.get((c[1][0], c[1][2] - c[1][1]), 0))
        moves = places.setdefault(section, {})
        if moves.setdefault(old_offset, new_offset) != new_offset:
            problems.append(f"0x{start + window:X} reaches {section}+0x{old_offset:X} in the release, "
                            f"elsewhere than the other references to it ({pdb.lookup(start + window)})")
        counts["references"] += 1
        covered = window + 3
    return problems + _consistent(places), counts


def find_commit(lines: list[str]) -> str | None:
    for line in lines:
        match = COMMIT_PATTERN.search(line)
        if match:
            return match.group(1)
    return None


def symbolize(lines: list[str], pdb: Pdb) -> list[str]:
    def replace(match: re.Match[str]) -> str:
        return f"{match.group(0)} [{pdb.lookup(int(match.group(1), 16))}]"

    return [OFFSET_PATTERN.sub(replace, line) for line in lines]


def read_input(sources: list[str]) -> list[str]:
    if not sources or sources == ["-"]:
        return sys.stdin.read().splitlines()
    if len(sources) == 1 and os.path.isfile(sources[0]):
        return Path(sources[0]).read_text(encoding="utf-8", errors="replace").splitlines()
    return sources


def symbols_for_log(lines: list[str], folder: Path) -> Path:
    commit = find_commit(lines)
    if commit is None:
        raise PdbError("the log has no identity line with a commit; pass --symbols")
    dll = folder / f"vanilla_plus_megapack-{commit}.dll"
    for candidate in (dll, dll.with_suffix(".pdb")):
        if candidate.exists():
            return candidate
    raise PdbError(f"no symbols for commit {commit} in {folder}; pass --symbols")


def list_functions(pdb: Pdb, wanted: list[str]) -> None:
    for function in pdb.functions:
        if not wanted or function.name in wanted:
            first = function.lines[0] if function.lines else None
            where = f" {_short(first[2])}:{first[1]}" if first else ""
            print(f"0x{function.rva:X} 0x{function.size:X} {function.name}{where}")


def run_check(release: Path, symbols: Path) -> int:
    problems, counts = check_same_code(release, symbols)
    for problem in problems:
        print(f"symbolize: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"{release.name} and {symbols.name}: the pack's {counts['functions']} functions "
          f"(0x{counts['bytes']:X} bytes) at the same offsets; {counts['references']} references differ only by where "
          f"the data sections and the C runtime moved")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("input", nargs="*", help="a log file, log lines, or nothing for stdin (with --list: names)")
    parser.add_argument("--symbols", type=Path, help="the unstripped DLL (its .pdb beside it) or the .pdb")
    parser.add_argument("--dir", type=Path, default=Path(__file__).resolve().parent.parent / "build" / "symbols",
                        help="the folder of vanilla_plus_megapack-<commit>.dll/.pdb (default build/symbols)")
    parser.add_argument("--list", action="store_true", help="list the functions of --symbols")
    parser.add_argument("--check", type=Path, metavar="RELEASE_DLL",
                        help="check that RELEASE_DLL's code sits at the same offsets as the --symbols DLL's")
    args = parser.parse_args(argv)
    if (args.check is not None or args.list) and args.symbols is None:
        parser.error("--check and --list need --symbols")
    try:
        if args.check is not None:
            return run_check(args.check, args.symbols)
        if args.list:
            list_functions(load_symbols(args.symbols), args.input)
            return 0
        lines = read_input(args.input)
        pdb = load_symbols(args.symbols or symbols_for_log(lines, args.dir))
    except (OSError, PdbError, struct.error, ValueError) as error:
        print(f"symbolize: {error}", file=sys.stderr)
        return 2
    for line in symbolize(lines, pdb):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
