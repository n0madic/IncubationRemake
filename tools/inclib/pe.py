"""Minimal PE reader: sections, the resource directory, and virtual addressing.

Written for reading Blue Byte's 32-bit release builds.  Two kinds of consumer
exist in this repository:

* :mod:`tools.pe_resources` walks the resource directory for dialog templates
  and string tables;
* :mod:`tools.trace_names` and :mod:`tools.combat_tables` read ``.text`` and
  ``.data`` by **virtual address**, because every address quoted in the
  documentation is a virtual one (``0x0046B450``), never a file offset.

Hence both the RVA-relative :meth:`PEFile.rva_to_off` and the absolute
:meth:`PEFile.va_to_off`.
"""

from __future__ import annotations

import struct
from pathlib import Path


class PEError(Exception):
    pass


class PEFile:
    """Minimal PE reader: sections and the resource directory."""

    def __init__(self, path: Path):
        self.path = path
        self.data = Path(path).read_bytes()
        d = self.data
        if d[:2] != b"MZ":
            raise PEError(f"{path}: not a DOS/PE image")
        pe_off = struct.unpack_from("<I", d, 0x3C)[0]
        if d[pe_off:pe_off + 4] != b"PE\0\0":
            raise PEError(f"{path}: no PE signature at {pe_off:#x}")
        coff = pe_off + 4
        (self.machine, nsec, self.timestamp, _symptr, _nsym,
         opt_size, _chars) = struct.unpack_from("<HHIIIHH", d, coff)
        opt = coff + 20
        magic = struct.unpack_from("<H", d, opt)[0]
        if magic == 0x10B:      # PE32
            self.image_base = struct.unpack_from("<I", d, opt + 28)[0]
            dd = opt + 96
        elif magic == 0x20B:    # PE32+
            self.image_base = struct.unpack_from("<Q", d, opt + 24)[0]
            dd = opt + 112
        else:
            raise PEError(f"{path}: unknown optional header magic {magic:#x}")
        ndd = struct.unpack_from("<I", d, dd - 4)[0]
        self.dirs = [struct.unpack_from("<II", d, dd + 8 * i)
                     for i in range(min(ndd, 16))]
        sec = opt + opt_size
        self.sections = []
        for i in range(nsec):
            o = sec + 40 * i
            name = d[o:o + 8].rstrip(b"\0").decode("latin-1")
            vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", d, o + 8)
            self.sections.append((name, vaddr, vsize, rawptr, rawsize))

    # --- addressing ---------------------------------------------------------

    def rva_to_off(self, rva: int) -> int | None:
        for _name, vaddr, vsize, rawptr, rawsize in self.sections:
            if vaddr <= rva < vaddr + max(vsize, rawsize):
                delta = rva - vaddr
                if delta < rawsize:
                    return rawptr + delta
                return None
        return None

    def va_to_off(self, va: int) -> int | None:
        """File offset of an absolute virtual address, or ``None`` if unmapped."""
        return self.rva_to_off(va - self.image_base)

    def off_to_va(self, off: int) -> int | None:
        for _name, vaddr, _vsize, rawptr, rawsize in self.sections:
            if rawptr <= off < rawptr + rawsize:
                return self.image_base + vaddr + (off - rawptr)
        return None

    def section(self, name: str):
        """Return ``(vaddr, vsize, rawptr, rawsize)`` of a section, VAs absolute."""
        for sname, vaddr, vsize, rawptr, rawsize in self.sections:
            if sname == name:
                return (self.image_base + vaddr, vsize, rawptr, rawsize)
        raise PEError(f"{self.path}: no {name} section")

    # --- typed reads by virtual address -------------------------------------

    def _at(self, va: int, size: int) -> int:
        off = self.va_to_off(va)
        if off is None or off + size > len(self.data):
            raise PEError(f"{self.path}: virtual address {va:#010x} is not mapped")
        return off

    def u8(self, va: int) -> int:
        return self.data[self._at(va, 1)]

    def u32(self, va: int) -> int:
        return struct.unpack_from("<I", self.data, self._at(va, 4))[0]

    def i32(self, va: int) -> int:
        return struct.unpack_from("<i", self.data, self._at(va, 4))[0]

    def f64(self, va: int) -> float:
        return struct.unpack_from("<d", self.data, self._at(va, 8))[0]

    def bytes_at(self, va: int, size: int) -> bytes:
        off = self._at(va, size)
        return self.data[off:off + size]

    def cstring(self, va: int, limit: int = 512) -> str | None:
        """NUL-terminated ASCII string at *va*, or ``None`` if unmapped/non-ASCII."""
        off = self.va_to_off(va)
        if off is None:
            return None
        end = self.data.find(b"\0", off, off + limit)
        if end < 0:
            return None
        try:
            return self.data[off:end].decode("ascii")
        except UnicodeDecodeError:
            return None

    # --- resource directory -------------------------------------------------

    def resources(self):
        """Yield ``(type_id, name_id, lang_id, bytes)`` for every resource."""
        if len(self.dirs) < 3:
            return
        base_rva, size = self.dirs[2]
        if not base_rva or not size:
            return
        base = self.rva_to_off(base_rva)
        if base is None:
            return
        for t, toff in self._entries(base, base):
            for n, noff in self._entries(base + noff_of(toff), base):
                for lang, loff in self._entries(base + noff_of(noff), base):
                    o = base + (loff & 0x7FFFFFFF)
                    data_rva, data_size = struct.unpack_from("<II", self.data, o)
                    off = self.rva_to_off(data_rva)
                    if off is None:
                        continue
                    yield t, n, lang, self.data[off:off + data_size]

    def _entries(self, off: int, base: int):
        """Yield ``(id_or_name, raw_offset_field)`` for one directory node."""
        (_c, _t, _maj, _min, nnamed, nid) = struct.unpack_from("<IIHHHH", self.data, off)
        out = []
        for i in range(nnamed + nid):
            e = off + 16 + 8 * i
            ident, sub = struct.unpack_from("<II", self.data, e)
            if ident & 0x80000000:
                so = base + (ident & 0x7FFFFFFF)
                ln = struct.unpack_from("<H", self.data, so)[0]
                ident = self.data[so + 2:so + 2 + 2 * ln].decode("utf-16-le", "replace")
            out.append((ident, sub))
        return out


def noff_of(field: int) -> int:
    return field & 0x7FFFFFFF
