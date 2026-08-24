"""Little-endian binary reading helpers shared by the format parsers."""

from __future__ import annotations

import struct
from typing import BinaryIO


class ParseError(Exception):
    """Raised when a file does not match the documented layout."""


class Reader:
    """Cursor over an in-memory byte buffer with little-endian primitives."""

    def __init__(self, data: bytes, pos: int = 0) -> None:
        self.data = data
        self.pos = pos

    def __len__(self) -> int:
        return len(self.data)

    @property
    def remaining(self) -> int:
        return len(self.data) - self.pos

    def eof(self) -> bool:
        return self.pos >= len(self.data)

    def take(self, n: int) -> bytes:
        if n < 0 or self.pos + n > len(self.data):
            raise ParseError(f"read of {n} bytes at 0x{self.pos:x} exceeds buffer")
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def _unpack(self, fmt: str) -> tuple:
        size = struct.calcsize(fmt)
        return struct.unpack_from(fmt, self.data, self._advance(size))

    def _advance(self, size: int) -> int:
        if self.pos + size > len(self.data):
            raise ParseError(f"read of {size} bytes at 0x{self.pos:x} exceeds buffer")
        pos = self.pos
        self.pos += size
        return pos

    def u8(self) -> int:
        return self._unpack("<B")[0]

    def i8(self) -> int:
        return self._unpack("<b")[0]

    def u16(self) -> int:
        return self._unpack("<H")[0]

    def i16(self) -> int:
        return self._unpack("<h")[0]

    def u32(self) -> int:
        return self._unpack("<I")[0]

    def i32(self) -> int:
        return self._unpack("<i")[0]

    def f32(self) -> float:
        return self._unpack("<f")[0]

    def vec3(self) -> tuple[float, float, float]:
        return self._unpack("<3f")

    def quat(self) -> tuple[float, float, float, float]:
        return self._unpack("<4f")

    def lpstring(self) -> str:
        """u32 length followed by exactly that many bytes, no NUL terminator."""
        n = self.u32()
        if n > self.remaining:
            raise ParseError(f"string length {n} at 0x{self.pos:x} exceeds buffer")
        return self.take(n).decode("cp1252", errors="replace")

    def cstring(self, size: int) -> str:
        """Fixed-size field holding a NUL-padded string."""
        raw = self.take(size)
        return raw.split(b"\x00", 1)[0].decode("cp1252", errors="replace")


def read_file(path: str) -> bytes:
    with open(path, "rb") as fh:
        return fh.read()


def open_reader(path: str) -> Reader:
    return Reader(read_file(path))
