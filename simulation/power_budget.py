#!/usr/bin/env python3
"""Averaged transient model for the NFC-harvested namecard power path.

This is intentionally an energy-domain model, not a switching model.  It models
the two storage nodes, the TPS63900 input-current limit and efficiency, the U5
supervisor delay, the U4/PWR_HOLD latch, and a firmware-controlled EPD update.
It has no third-party Python dependencies.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
from typing import Optional


@dataclass(frozen=True)
class Params:
    harvest_current_a: float = 2.5e-3
    # Pixel 9 Pro observation at V_EH. This is a compliance voltage; available
    # current remains a separate assumption and is swept for sensitivity.
    harvest_clamp_v: float = 2.50
    converter_input_limit_a: float = 2.5e-3
    converter_efficiency: float = 0.85
    converter_setpoint_v: float = 3.30
    converter_uvlo_on_v: float = 1.75
    converter_uvlo_off_v: float = 1.65
    converter_regulation_tau_s: float = 0.020
    vraw_cap_f: float = 231.2e-6
    # C33-C38 removed; C46 adds one populated VRES reservoir capacitor:
    # C14-C17/C46 (5 x 220 uF), C29-C32/C42 (5 x 22 uF), and
    # C28/C43-C45 (4 x 100 nF).
    vres_cap_f: float = 1.2104e-3
    u5_falling_v: float = 2.93
    u5_rising_v: float = 2.959
    u5_delay_s: float = 0.200
    hold_assert_delay_s: float = 0.005
    firmware_start_v: float = 3.20
    firmware_start_stable_s: float = 0.100
    # Use the high ends of the PVD4/BOR3 falling-threshold ranges for sign-off.
    pvd_v: float = 2.77
    bor_v: float = 2.58
    boot_current_a: float = 1.50e-3
    boot_time_s: float = 0.020
    charge_sleep_current_a: float = 0.12e-3
    epd_init_current_a: float = 2.00e-3
    epd_init_time_s: float = 0.050
    epd_partial_current_a: float = 2.73e-3
    epd_partial_time_s: float = 0.300
    shutdown_time_s: float = 0.010
    dt_s: float = 0.0001
    timeout_s: float = 20.0


@dataclass(frozen=True)
class Result:
    success: bool
    reason: str
    boot_s: Optional[float]
    update_start_s: Optional[float]
    done_s: Optional[float]
    min_vres_update_v: Optional[float]
    min_vraw_update_v: Optional[float]
    max_vres_v: float
    converter_restarts: int


def simulate(p: Params) -> Result:
    vraw = 0.0
    vres = 0.0
    max_vres = 0.0
    converter_on = False
    converter_restarts = 0

    u5_timer = 0.0
    u5_high = False
    system_on = False
    hold_high = False
    boot_at: Optional[float] = None
    update_at: Optional[float] = None
    done_at: Optional[float] = None
    phase = "off"
    phase_at = 0.0
    start_timer = 0.0
    min_vres_update = float("inf")
    min_vraw_update = float("inf")
    reason = "timeout before a completed partial update"

    steps = int(p.timeout_s / p.dt_s) + 1
    for step in range(steps):
        t = step * p.dt_s

        # TPS3839K33: fast falling response, 200 ms typical rising delay.
        if vres < p.u5_falling_v:
            u5_high = False
            u5_timer = 0.0
        elif not u5_high:
            if vres >= p.u5_rising_v:
                u5_timer += p.dt_s
                if u5_timer >= p.u5_delay_s:
                    u5_high = True
            else:
                u5_timer = 0.0

        if not system_on and u5_high:
            system_on = True
            boot_at = t
            phase = "boot"
            phase_at = t

        if system_on:
            if not hold_high and boot_at is not None and t - boot_at >= p.hold_assert_delay_s:
                hold_high = True

            if not (u5_high or hold_high):
                reason = "U5 dropped before firmware asserted PWR_HOLD"
                break

            if phase == "boot" and t - phase_at >= p.boot_time_s:
                phase = "wait"
                phase_at = t
            elif phase == "wait":
                if vres >= p.firmware_start_v:
                    start_timer += p.dt_s
                    if start_timer >= p.firmware_start_stable_s:
                        phase = "epd_init"
                        phase_at = t
                        update_at = t
                else:
                    start_timer = 0.0
            elif phase == "epd_init" and t - phase_at >= p.epd_init_time_s:
                phase = "partial"
                phase_at = t
            elif phase == "partial" and t - phase_at >= p.epd_partial_time_s:
                phase = "shutdown"
                phase_at = t
            elif phase == "shutdown" and t - phase_at >= p.shutdown_time_s:
                done_at = t
                reason = "completed"
                return Result(
                    True,
                    reason,
                    boot_at,
                    update_at,
                    done_at,
                    min_vres_update,
                    min_vraw_update,
                    max_vres,
                    converter_restarts,
                )

            if phase in ("epd_init", "partial", "shutdown"):
                min_vres_update = min(min_vres_update, vres)
                min_vraw_update = min(min_vraw_update, vraw)
                if vres < p.pvd_v:
                    reason = "PVD threshold crossed during EPD update"
                    break
            elif vres < p.bor_v:
                reason = "BOR threshold crossed before EPD update"
                break

        if phase == "off":
            load_a = 0.0
        elif phase == "boot":
            load_a = p.boot_current_a
        elif phase == "wait":
            load_a = p.charge_sleep_current_a
        elif phase == "epd_init":
            load_a = p.epd_init_current_a
        elif phase == "partial":
            load_a = p.charge_sleep_current_a + p.epd_partial_current_a
        else:
            load_a = p.charge_sleep_current_a

        # TPS63900 UVLO hysteresis.
        if converter_on and vraw <= p.converter_uvlo_off_v:
            converter_on = False
        elif not converter_on and vraw >= p.converter_uvlo_on_v:
            converter_on = True
            converter_restarts += 1

        converter_out_a = 0.0
        converter_in_a = 0.0
        if converter_on and vraw > 0.0:
            power_voltage_v = max(vres, 0.50)
            output_limit_a = (
                p.converter_input_limit_a
                * vraw
                * p.converter_efficiency
                / power_voltage_v
            )
            charge_request_a = max(
                0.0,
                (p.converter_setpoint_v - vres)
                * p.vres_cap_f
                / p.converter_regulation_tau_s,
            )
            converter_out_a = min(output_limit_a, load_a + charge_request_a)
            converter_in_a = min(
                p.converter_input_limit_a,
                converter_out_a
                * power_voltage_v
                / (p.converter_efficiency * max(vraw, 0.10)),
            )

        # ST25DV EH is represented as a current source with an open-voltage clamp.
        source_a = p.harvest_current_a
        if vraw >= p.harvest_clamp_v and source_a > converter_in_a:
            source_a = converter_in_a

        vraw += (source_a - converter_in_a) * p.dt_s / p.vraw_cap_f
        vres += (converter_out_a - load_a) * p.dt_s / p.vres_cap_f
        vraw = min(max(vraw, 0.0), p.harvest_clamp_v)
        vres = min(max(vres, 0.0), p.converter_setpoint_v)
        max_vres = max(max_vres, vres)

    return Result(
        False,
        reason,
        boot_at,
        update_at,
        done_at,
        None if min_vres_update == float("inf") else min_vres_update,
        None if min_vraw_update == float("inf") else min_vraw_update,
        max_vres,
        converter_restarts,
    )


def fmt_time(value: Optional[float]) -> str:
    return "-" if value is None else f"{value:.2f}"


def fmt_voltage(value: Optional[float]) -> str:
    return "-" if value is None else f"{value:.3f}"


def print_result(p: Params, result: Result) -> None:
    print(f"result: {'PASS' if result.success else 'FAIL'} ({result.reason})")
    print(f"V_EH compliance voltage: {p.harvest_clamp_v:.2f} V")
    print(f"harvest current: {p.harvest_current_a * 1e3:.2f} mA")
    print(f"TPS63900 input limit: {p.converter_input_limit_a * 1e3:.2f} mA")
    print(f"VRES effective capacitance: {p.vres_cap_f * 1e3:.3f} mF")
    print(f"firmware execute threshold: {p.firmware_start_v:.2f} V")
    print(f"boot: {fmt_time(result.boot_s)} s")
    print(f"update start: {fmt_time(result.update_start_s)} s")
    print(f"done: {fmt_time(result.done_s)} s")
    print(f"minimum VRES during update: {fmt_voltage(result.min_vres_update_v)} V")
    print(f"minimum VRAW during update: {fmt_voltage(result.min_vraw_update_v)} V")
    print(f"converter starts/restarts: {result.converter_restarts}")


def run_sweep(base: Params) -> None:
    caps_mf = (0.55, 0.88, 0.99, 1.43, 2.31)
    harvest_ma = (0.7, 1.5, 2.5, 3.5)
    print("| EH mA | VRES mF | Result | Boot s | Update s | Min VRES V | Restarts |")
    print("|---:|---:|:---:|---:|---:|---:|---:|")
    for current_ma in harvest_ma:
        for cap_mf in caps_mf:
            p = replace(
                base,
                harvest_current_a=current_ma * 1e-3,
                vres_cap_f=cap_mf * 1e-3,
            )
            result = simulate(p)
            print(
                f"| {current_ma:.1f} | {cap_mf:.2f} | "
                f"{'PASS' if result.success else 'FAIL'} | "
                f"{fmt_time(result.boot_s)} | {fmt_time(result.update_start_s)} | "
                f"{fmt_voltage(result.min_vres_update_v)} | {result.converter_restarts} |"
            )


def run_pixel_sweep(base: Params) -> None:
    veh_volts = (2.3, 2.5, 2.7)
    harvest_ma = (1.0, 1.5, 2.0, 2.5, 3.0)
    print("| V_EH V | EH mA assumption | Result | Update s | Min VRES V | Min VRAW V | Restarts |")
    print("|---:|---:|:---:|---:|---:|---:|---:|")
    for veh_v in veh_volts:
        for current_ma in harvest_ma:
            p = replace(
                base,
                harvest_clamp_v=veh_v,
                harvest_current_a=current_ma * 1e-3,
            )
            result = simulate(p)
            print(
                f"| {veh_v:.1f} | {current_ma:.1f} | "
                f"{'PASS' if result.success else 'FAIL'} | "
                f"{fmt_time(result.update_start_s)} | "
                f"{fmt_voltage(result.min_vres_update_v)} | "
                f"{fmt_voltage(result.min_vraw_update_v)} | "
                f"{result.converter_restarts} |"
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sweep", action="store_true", help="sweep EH current and VRES capacitance")
    parser.add_argument(
        "--pixel-sweep",
        action="store_true",
        help="sweep Pixel 9 Pro V_EH observations and assumed available current",
    )
    parser.add_argument("--harvest-ma", type=float, default=2.5)
    parser.add_argument("--veh-v", type=float, default=2.5)
    parser.add_argument("--icl-ma", type=float, default=2.5)
    parser.add_argument("--cap-mf", type=float, default=1.2104)
    parser.add_argument("--start-v", type=float, default=3.20)
    parser.add_argument("--epd-ma", type=float, default=2.73)
    parser.add_argument("--efficiency", type=float, default=0.85)
    parser.add_argument("--pvd-v", type=float, default=2.77)
    parser.add_argument("--bor-v", type=float, default=2.58)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    params = Params(
        harvest_current_a=args.harvest_ma * 1e-3,
        harvest_clamp_v=args.veh_v,
        converter_input_limit_a=args.icl_ma * 1e-3,
        vres_cap_f=args.cap_mf * 1e-3,
        firmware_start_v=args.start_v,
        epd_partial_current_a=args.epd_ma * 1e-3,
        converter_efficiency=args.efficiency,
        pvd_v=args.pvd_v,
        bor_v=args.bor_v,
    )
    if args.sweep:
        run_sweep(params)
        return 0
    if args.pixel_sweep:
        run_pixel_sweep(params)
        return 0
    result = simulate(params)
    print_result(params, result)
    return 0 if result.success else 1


if __name__ == "__main__":
    raise SystemExit(main())
