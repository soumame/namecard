# Namecard harvested-power simulation

This directory contains an averaged transient/energy model for the following
power path:

`ST25DV V_EH -> LM66100 -> VRAW -> TPS63900 -> VRES_3V3 -> U5/U4 -> SYS_VDD`

It is intended to answer two board-level questions before ordering a prototype:

1. How long does the storage bank take to reach a safe EPD-start voltage?
2. Does `VRES_3V3` remain above the STM32 PVD threshold during a partial update?

Run the nominal current-board case:

```sh
python3 simulation/power_budget.py
```

Run a sweep of harvested current and storage capacitance:

```sh
python3 simulation/power_budget.py --sweep
```

Run the Pixel 9 Pro voltage/current sensitivity sweep:

```sh
python3 simulation/power_budget.py --pixel-sweep
```

Run the companion averaged SPICE deck with KiCad's bundled libngspice:

```sh
python3 simulation/run_ngspice.py
```

Run the SPICE cross-check at each observed Pixel 9 Pro voltage:

```sh
python3 simulation/run_ngspice.py --veh-v 2.3
python3 simulation/run_ngspice.py --veh-v 2.5
python3 simulation/run_ngspice.py --veh-v 2.7
```

`namecard_power.cir` can also be opened in a standalone ngspice-compatible
simulator. The Python sweep is the more useful model for U5/PWR_HOLD/PVD firmware
state transitions; the SPICE deck is a cross-check of the two capacitor nodes
and averaged converter/load currents.

Example stress cases:

```sh
# Twice the published average EPD current
python3 simulation/power_budget.py --epd-ma 5.46

# Weak coupling and a smaller capacitor bank
python3 simulation/power_budget.py --harvest-ma 1.5 --cap-mf 0.99

# Candidate 5 mA TPS63900 input-current-limit setting
python3 simulation/power_budget.py --harvest-ma 3.5 --icl-ma 5
```

## Defaults and their origin

- `VRES_3V3 = 1.2104 mF`: nominal total after deleting C33-C38 and adding
  C46. It is C14-C17/C46 (5 x 220 uF), C29-C32/C42 (5 x 22 uF), and
  C28/C43-C45 (4 x 100 nF). The U4 CT capacitor is excluded.
- `VRAW = 231.2 uF`: current schematic nominal total, including C39 = 220 uF.
- Pixel 9 Pro `V_EH = 2.3--2.7 V`: measured observation supplied for this
  analysis. Available current is not known from this voltage measurement, so
  the Python model sweeps 1.0--3.0 mA independently.
- TPS63900 input current limit: 2.5 mA (`R10 = 5.11 kohm`).
- Converter efficiency: 85%, deliberately below the typical curves.
- U5 falling/rising points: 2.930 V / 2.959 V typical, followed by the typical
  200 ms reset delay.
- Firmware starts the EPD only after 3.20 V has been maintained for 100 ms.
- Partial-refresh load: 2.73 mA for 300 ms, derived from 9 mW / 3.3 V.
- MCU/system charge-wait current: 0.12 mA. This assumes STOP/WFI and EPD power
  off; it must be checked on hardware.
- STM32G031 PVD4/BOR3 guard levels: 2.77 V / 2.58 V. These are the high
  ends of the falling-threshold ranges, not the typical 2.64 V / 2.52 V values.
  This makes a simulated pass meaningful across MCU threshold variation.

## Limits

This is an averaged model. It does not model the 13.56 MHz antenna, rectifier,
TPS63900 switching ripple/control-loop stability, SSD1680 charge-pump pulses,
capacitor DC-bias/tolerance, PCB resistance, or phone-specific field geometry.
Use it to reject bad energy budgets and choose test points; do not use it as the
final production sign-off. Hardware measurements of `V_EH_RAW`, `VRAW`, and
`VRES_3V3` remain required on the next prototype.

## Results after removing C33-C38

The table below uses 85% converter efficiency, a 3.20 V / 100 ms firmware start
gate, and the conservative 2.77 V PVD4 falling threshold.

The averaged SPICE model treats each measured voltage as the V_EH operating
point at an assumed 2.5 mA, with an assumed 240 ohm local source slope. For the
table below, the EPD starts 100 ms after VRES first crosses 3.20 V.

| Pixel 9 Pro V_EH | VRES reaches 3.20 V | Minimum VRES during update | Result |
|---:|---:|---:|:---:|
| 2.3 V | 1.363 s | 2.962 V | PASS |
| 2.5 V | 1.258 s | 2.994 V | PASS |
| 2.7 V | 1.168 s | 3.026 V | PASS |

The conservative current-source/state-machine model starts only 100 ms after
VRES reaches 3.20 V. With 2.5 mA available it passes at 2.846 V minimum. The
extra 220 uF also moves the modeled pass boundary from about 2.5 mA to about
2.2 mA, although 2.3 mA is still the minimum modeled case that remains above
the separate 2.80 V board acceptance target.

| Available EH current assumption | Result at V_EH 2.3--2.7 V |
|---:|:---|
| 1.0--2.1 mA | FAIL; repeated TPS63900 UVLO cycling or PVD reached |
| 2.2 mA | PASS against 2.77 V PVD, but below the 2.80 V board target |
| 2.3 mA | PASS at 2.801 V minimum |
| 2.5 mA | PASS at 2.846 V minimum |
| 3.0 mA | PASS |

An EPD partial-load assumption of 3.5 mA instead of the published 2.73 mA also
fails the conservative model. The actual phone/antenna load curve and EPD
current therefore remain mandatory prototype measurements.

Design implications:

- Do not start the EPD at the old 2.95 V gate. The revised model uses a 3.20 V
  gate held for 100 ms while the MCU is in a low-current sleep state. The
  production firmware still has to implement and validate this gate.
- The 1.2104 mF bank is viable only if Pixel 9 Pro coupling sustains
  at least about 2.3 mA for the 2.80 V board target and the real
  partial-refresh load stays near 2.73 mA.
- Keep C39 (220 uF) on VRAW. Both models assume it is populated; removing it
  invalidates these transient results.
- Keep 2.5 mA as the initial R10 setting, but make R10 easy to replace. A 1 mA
  setting avoids VRAW UVLO cycling when the phone can only sustain around
  1.5 mA; a 5 mA default can make a weak source collapse faster.
- The most important missing input is the real phone/antenna load curve. A
  measured 2.3--2.7 V without a known load does not establish available power.
