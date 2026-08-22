#!/usr/bin/env python3
"""Build and inspect namecard mailbox frames without third-party packages."""

from __future__ import annotations

import argparse
import json
import struct
import zlib
from pathlib import Path

MAGIC = b"NC"
VERSION = 1
HEADER = struct.Struct("<2sBBHHHHHH")
IMAGE_SIZE = 4736
MAX_PAYLOAD = 240

START, DATA, COMMIT, STATUS, EXECUTE, PATTERN = range(1, 7)
PATTERNS = {"checker": 1, "nfc-ok": 2}


def crc16(data: bytes, initial: int = 0xFFFF) -> int:
    value = initial
    for byte in data:
        value ^= byte << 8
        for _ in range(8):
            value = ((value << 1) ^ 0x1021) & 0xFFFF if value & 0x8000 else (value << 1) & 0xFFFF
    return value


def build_frame(kind: int, transfer_id: int, sequence: int, offset: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("payload exceeds 240 bytes")
    payload_crc = crc16(payload)
    header = bytearray(HEADER.pack(MAGIC, VERSION, kind, transfer_id, sequence,
                                   offset, len(payload), 0, payload_crc))
    header_crc = crc16(header[:12] + header[14:16])
    struct.pack_into("<H", header, 12, header_crc)
    return bytes(header) + payload


def parse_frame(frame: bytes) -> dict[str, int | bytes]:
    if len(frame) < HEADER.size:
        raise ValueError("short frame")
    magic, version, kind, tid, seq, offset, length, header_crc, payload_crc = HEADER.unpack_from(frame)
    if magic != MAGIC or version != VERSION or len(frame) != HEADER.size + length:
        raise ValueError("invalid header or length")
    if crc16(frame[:12] + frame[14:16]) != header_crc:
        raise ValueError("header CRC mismatch")
    payload = frame[HEADER.size:]
    if crc16(payload) != payload_crc:
        raise ValueError("payload CRC mismatch")
    return {"type": kind, "transfer_id": tid, "sequence": seq, "offset": offset,
            "payload_length": length, "payload": payload}


def test_image() -> bytes:
    data = bytearray([0xFF] * IMAGE_SIZE)
    for y in range(296):
        for x_byte in range(16):
            border = y < 4 or y >= 292 or x_byte in (0, 15)
            if border:
                value = 0
            elif ((y // 24) + (x_byte // 2)) % 2 == 0:
                value = 0xAA
            else:
                value = 0xFF
            data[y * 16 + x_byte] = value
    return bytes(data)


def nfc_ok_image() -> bytes:
    data = bytearray([0xFF] * IMAGE_SIZE)
    glyphs = (
        (0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11),
        (0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10),
        (0x0F, 0x10, 0x10, 0x10, 0x10, 0x10, 0x0F),
        (0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
        (0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11),
    )
    scale = 6

    def black(long_axis: int, short_axis: int) -> None:
        if 0 <= long_axis < 296 and 0 <= short_axis < 128:
            index = long_axis * 16 + short_axis // 8
            data[index] &= ~(0x80 >> (short_axis % 8))

    for long_axis in range(296):
        black(long_axis, 1)
        black(long_axis, 126)
    for short_axis in range(128):
        black(1, short_axis)
        black(294, short_axis)

    cursor = (296 - 34 * scale) // 2
    top = (128 - 7 * scale) // 2
    for index, rows in enumerate(glyphs):
        if index == 3:
            cursor += 5 * scale
        for row, bits in enumerate(rows):
            for column in range(5):
                if not bits & (0x10 >> column):
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        black(cursor + column * scale + dx,
                              top + row * scale + dy)
        cursor += 6 * scale
    return bytes(data)


def make_transfer(image: bytes, transfer_id: int) -> list[bytes]:
    if len(image) != IMAGE_SIZE:
        raise ValueError(f"native image must be exactly {IMAGE_SIZE} bytes")
    metadata = struct.pack("<HHHBBI4x", 296, 128, IMAGE_SIZE, 1, 1,
                           zlib.crc32(image) & 0xFFFFFFFF)
    frames = [build_frame(START, transfer_id, 0, 0, metadata)]
    sequence = 1
    for offset in range(0, IMAGE_SIZE, MAX_PAYLOAD):
        frames.append(build_frame(DATA, transfer_id, sequence, offset,
                                  image[offset:offset + MAX_PAYLOAD]))
        sequence += 1
    frames.append(build_frame(COMMIT, transfer_id, sequence, IMAGE_SIZE))
    frames.append(build_frame(STATUS, transfer_id, sequence + 1, IMAGE_SIZE))
    frames.append(build_frame(EXECUTE, transfer_id, sequence + 1, IMAGE_SIZE))
    return frames


def command_generate(args: argparse.Namespace) -> None:
    image = test_image() if args.test_pattern else Path(args.image).read_bytes()
    destination = Path(args.output)
    destination.mkdir(parents=True, exist_ok=True)
    frames = make_transfer(image, args.transfer_id)
    manifest = []
    names = ["start"] + [f"data-{i:02d}" for i in range(1, 21)] + ["commit", "status", "execute"]
    if len(names) != len(frames):
        raise AssertionError("frame manifest is out of sync")
    for index, (name, frame) in enumerate(zip(names, frames)):
        filename = f"{index:02d}-{name}.bin"
        (destination / filename).write_bytes(frame)
        parsed = parse_frame(frame)
        manifest.append({key: value for key, value in parsed.items() if key != "payload"} | {"file": filename})
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def command_decode(args: argparse.Namespace) -> None:
    parsed = parse_frame(Path(args.frame).read_bytes())
    parsed["payload"] = parsed["payload"].hex()
    print(json.dumps(parsed, indent=2))


def command_pattern(args: argparse.Namespace) -> None:
    frame = build_frame(PATTERN, args.transfer_id, 0, 0,
                        bytes((PATTERNS[args.pattern],)))
    Path(args.output).write_bytes(frame)


def command_make_image(args: argparse.Namespace) -> None:
    image = test_image() if args.pattern == "checker" else nfc_ok_image()
    Path(args.output).write_bytes(image)


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(required=True)
    generate = commands.add_parser("generate", help="generate a complete mailbox transfer")
    source = generate.add_mutually_exclusive_group(required=True)
    source.add_argument("--image", help="4736-byte EPD_NATIVE_1BPP file")
    source.add_argument("--test-pattern", action="store_true")
    generate.add_argument("--transfer-id", type=lambda value: int(value, 0), default=1)
    generate.add_argument("--output", required=True)
    generate.set_defaults(handler=command_generate)
    decode = commands.add_parser("decode")
    decode.add_argument("frame")
    decode.set_defaults(handler=command_decode)
    pattern = commands.add_parser("pattern", help="generate one built-in-pattern command")
    pattern.add_argument("--pattern", choices=PATTERNS, default="nfc-ok")
    pattern.add_argument("--transfer-id", type=lambda value: int(value, 0), default=1)
    pattern.add_argument("--output", required=True)
    pattern.set_defaults(handler=command_pattern)
    make_image = commands.add_parser("make-image", help="generate a 4736-byte native test image")
    make_image.add_argument("--pattern", choices=PATTERNS, default="nfc-ok")
    make_image.add_argument("--output", required=True)
    make_image.set_defaults(handler=command_make_image)
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
