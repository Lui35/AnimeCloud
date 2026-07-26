#!/usr/bin/env python3
"""Annotate otool output with Objective-C constant strings from a Mach-O binary."""

from __future__ import annotations

import re
import struct
import subprocess
import sys
from pathlib import Path


LC_SEGMENT_64 = 0x19


def cstr(blob: bytes) -> str:
    return blob.split(b"\0", 1)[0].decode("utf-8", "replace")


def sections_and_segments(blob: bytes):
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", blob, 0)
    if magic != 0xFEEDFACF:
        raise ValueError("expected a little-endian 64-bit Mach-O")
    sections = {}
    segments = []
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", blob, off)
        if cmd == LC_SEGMENT_64:
            segname, vmaddr, vmsize, fileoff, filesize, _, _, nsects, _ = struct.unpack_from(
                "<16sQQQQiiii", blob, off + 8
            )
            segname_s = cstr(segname)
            segments.append((vmaddr, vmsize, fileoff, filesize))
            sectoff = off + 72
            for _ in range(nsects):
                sectname, section_segname, addr, size, offset = struct.unpack_from(
                    "<16s16sQQI", blob, sectoff
                )
                sections[(cstr(section_segname), cstr(sectname))] = (addr, size, offset)
                sectoff += 80
        off += cmdsize
    return sections, segments


def vm_to_file(address: int, segments) -> int:
    for vmaddr, vmsize, fileoff, filesize in segments:
        delta = address - vmaddr
        if 0 <= delta < min(vmsize, filesize):
            return fileoff + delta
    raise KeyError(hex(address))


def cfstrings(blob: bytes):
    sections, segments = sections_and_segments(blob)
    addr, size, offset = sections[("__DATA", "__cfstring")]
    result = {}
    for delta in range(0, size, 32):
        _, _, string_address, length = struct.unpack_from("<QQQQ", blob, offset + delta)
        try:
            string_offset = vm_to_file(string_address, segments)
        except KeyError:
            continue
        result[addr + delta] = blob[string_offset : string_offset + length].decode(
            "utf-8", "replace"
        )
    return result


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(f"usage: {Path(sys.argv[0]).name} MACH_O [--network]", file=sys.stderr)
        return 2
    binary = Path(sys.argv[1])
    mapping = cfstrings(binary.read_bytes())
    output = subprocess.check_output(["otool", "-tvV", str(binary)], text=True)
    direct_pattern = re.compile(r"\b(0x[0-9a-f]+)\s+; Objc cfstring ref: .*$")
    adrp_pattern = re.compile(r"\badrp\s+(x\d+),.*;\s*(0x[0-9a-f]+)")
    add_pattern = re.compile(
        r"\badd\s+(x\d+),\s*(x\d+),\s*#(0x[0-9a-f]+).*; Objc cfstring ref: .*$"
    )
    pages = {}
    annotated = []
    for line in output.splitlines():
        page_match = adrp_pattern.search(line)
        if page_match:
            pages[page_match.group(1)] = int(page_match.group(2), 16)
        if "Objc cfstring ref:" in line:
            add_match = add_pattern.search(line)
            if add_match and add_match.group(2) in pages:
                address = pages[add_match.group(2)] + int(add_match.group(3), 16)
                value = mapping.get(address)
                if value is not None:
                    line = re.sub(
                        r"Objc cfstring ref: .*$",
                        lambda _: f'Objc cfstring ref: @"{value}"',
                        line,
                    )
            else:
                match = direct_pattern.search(line)
                if match:
                    value = mapping.get(int(match.group(1), 16))
                    if value is not None:
                        line = direct_pattern.sub(
                            lambda m: f'{m.group(1)} ; Objc cfstring ref: @"{value}"', line
                        )
        annotated.append(line)
    if len(sys.argv) == 3 and sys.argv[2] == "--network":
        literal_pattern = re.compile(r'Objc cfstring ref: @"(.*)"$')
        for index, line in enumerate(annotated):
            if not re.search(r"Objc message: -\[x0 (?:POST|GET):parameters:", line):
                continue
            values = []
            for prior in annotated[max(0, index - 150) : index + 1]:
                match = literal_pattern.search(prior)
                if match and match.group(1) not in values:
                    values.append(match.group(1))
            print(line.split("\t", 1)[0], " | ".join(values), sep="\t")
    else:
        print("\n".join(annotated))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
