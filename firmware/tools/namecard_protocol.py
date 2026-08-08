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

START, DATA, COMMIT, STATUS, EXECUTE = range(1, 6)


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
    args = parser.parse_args()
    args.handler(args)


if __name__ == "__main__":
    main()
