#!/usr/bin/env python3
"""Run a SPICE deck with the libngspice bundled inside KiCad on macOS."""

from __future__ import annotations

import argparse
import ctypes
import pathlib
import re
import tempfile


LIBNGSPICE = pathlib.Path(
    "/Applications/KiCad/KiCad.app/Contents/PlugIns/sim/libngspice.dylib"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("deck", nargs="?", type=pathlib.Path)
    parser.add_argument("--veh-v", type=float, help="V_EH at the assumed harvested current")
    parser.add_argument(
        "--calibration-ma",
        type=float,
        help="current in mA at which --veh-v was observed (default deck: 2.5)",
    )
    parser.add_argument(
        "--update-s",
        type=float,
        help="EPD update start time in seconds (default deck: 2.00)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    deck = (args.deck or pathlib.Path(__file__).with_name("namecard_power.cir")).resolve()
    if not LIBNGSPICE.exists():
        print(f"KiCad libngspice not found: {LIBNGSPICE}", file=sys.stderr)
        return 2
    if not deck.exists():
        print(f"SPICE deck not found: {deck}", file=sys.stderr)
        return 2

    lib = ctypes.CDLL(str(LIBNGSPICE))
    send_char_type = ctypes.CFUNCTYPE(
        ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p
    )
    send_stat_type = send_char_type
    controlled_exit_type = ctypes.CFUNCTYPE(
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_bool,
        ctypes.c_bool,
        ctypes.c_int,
        ctypes.c_void_p,
    )
    send_data_type = ctypes.CFUNCTYPE(
        ctypes.c_int, ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p
    )
    send_init_type = ctypes.CFUNCTYPE(
        ctypes.c_int, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p
    )
    bg_type = ctypes.CFUNCTYPE(
        ctypes.c_int, ctypes.c_bool, ctypes.c_int, ctypes.c_void_p
    )

    @send_char_type
    def send_char(message: bytes, _ident: int, _user: int) -> int:
        text = message.decode("utf-8", errors="replace")
        if text.startswith("stdout "):
            text = text[7:]
        elif text.startswith("stderr "):
            text = text[7:]
        print(text)
        return 0

    @send_stat_type
    def send_stat(_message: bytes, _ident: int, _user: int) -> int:
        return 0

    @controlled_exit_type
    def controlled_exit(
        status: int, _immediate: bool, _quit: bool, _ident: int, _user: int
    ) -> int:
        return status

    @send_data_type
    def send_data(_values: int, _count: int, _ident: int, _user: int) -> int:
        return 0

    @send_init_type
    def send_init(_values: int, _ident: int, _user: int) -> int:
        return 0

    @bg_type
    def bg(_running: bool, _ident: int, _user: int) -> int:
        return 0

    lib.ngSpice_Init.argtypes = [
        send_char_type,
        send_stat_type,
        controlled_exit_type,
        send_data_type,
        send_init_type,
        bg_type,
        ctypes.c_void_p,
    ]
    lib.ngSpice_Init.restype = ctypes.c_int
    lib.ngSpice_Command.argtypes = [ctypes.c_char_p]
    lib.ngSpice_Command.restype = ctypes.c_int

    status = lib.ngSpice_Init(
        send_char, send_stat, controlled_exit, send_data, send_init, bg, None
    )
    if status != 0:
        print(f"ngSpice_Init failed: {status}", file=sys.stderr)
        return 1
    temporary_deck: pathlib.Path | None = None
    if (
        args.veh_v is not None
        or args.calibration_ma is not None
        or args.update_s is not None
    ):
        deck_text = deck.read_text()
        if args.veh_v is not None:
            deck_text = re.sub(
                r"^\.param VEH_LOAD=.*$",
                f".param VEH_LOAD={args.veh_v:.6g}",
                deck_text,
                flags=re.MULTILINE,
            )
        if args.calibration_ma is not None:
            deck_text = re.sub(
                r"^\.param IHARV=.*$",
                f".param IHARV={args.calibration_ma:.6g}m",
                deck_text,
                flags=re.MULTILINE,
            )
        if args.update_s is not None:
            update_s = args.update_s
            end_s = update_s + 0.36
            deck_text = re.sub(
                r"^\.param TUPDATE=.*$",
                f".param TUPDATE={update_s:.6g}",
                deck_text,
                flags=re.MULTILINE,
            )
            deck_text = re.sub(
                r"^meas tran vres_at_update .*$",
                f"meas tran vres_at_update find v(vres) at={update_s:.6g}",
                deck_text,
                flags=re.MULTILINE,
            )
            for measurement, vector in (
                ("vres_min", "v(vres)"),
                ("vraw_min", "v(vraw)"),
                ("veh_min", "v(veh)"),
            ):
                deck_text = re.sub(
                    rf"^meas tran {measurement} .*$",
                    f"meas tran {measurement} min {vector} "
                    f"from={update_s:.6g} to={end_s:.6g}",
                    deck_text,
                    flags=re.MULTILINE,
                )
        with tempfile.NamedTemporaryFile("w", suffix=".cir", delete=False) as handle:
            handle.write(deck_text)
            temporary_deck = pathlib.Path(handle.name)
        deck = temporary_deck

    try:
        command = f"source {deck}".encode("utf-8")
        return int(lib.ngSpice_Command(command) != 0)
    finally:
        if temporary_deck is not None:
            temporary_deck.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
