# Maker Faire product design (Android-first)

## Supported user flow

The product protocol remains platform-neutral ISO 15693/ST25DV FTM, but the
supported September release client is Android only. The phone must keep the RF
field present while deliberately pausing RF commands during VRES charge and EPD
refresh. Generic NDEF writers and Web NFC are not compatible with this timing.

iPhone is not an electrical incompatibility: an entitled Core NFC application
can open an ISO 15693 tag-reader session and the prototype showed that it can
maintain enough field for EH. It is outside the supported release because an
NFC entitlement, signing, session lifecycle, and another full phone validation
matrix are required. Do not put an “iPhone cannot power it” claim on the product.

## Final firmware state machine

```text
RF boot -> RECEIVE -> COMMIT/CRC OK -> CHARGE (3.20 V/100 ms)
        -> STAGE target in inactive Flash slot -> RECHARGE
        -> READY -> EXECUTE ACK read -> 100 ms RF-quiet guard
        -> EPD previous RAM <- committed Flash image
        -> EPD current RAM  <- target RAM image
        -> full-screen Partial/BUSY -> COMMIT Flash marker -> COMPLETE
```

- RAM contains one 4,736-byte target image and one 256-byte mailbox buffer.
- Flash pages 0–9 (20 KiB) contain firmware.
- Flash pages 10–12 and 13–15 are two 6-KiB display-image slots.
- A slot is valid only when its metadata CRC32 and image CRC32 pass.
- PREPARED and COMMITTED are separate 64-bit Flash words. The target slot is
  prepared before EPD power-on and committed only after BUSY completes.
- If power is removed during DATA, Android restarts from START.
- If power is removed after Flash staging, the original transfer ID/sequence
  and target survive. The next tap can resume charging and EXECUTE.
- If power is removed during Partial, the next EXECUTE repeats old->target.
  This may need one extra cleanup update visually, but it avoids declaring a
  partly-updated panel as a known target.
- If neither slot is valid, firmware assumes the factory physical display is
  white. Therefore every board must pass the factory sequence below.

The ST25DV EEPROM is not used for frame storage. This keeps the same firmware
compatible with ST25DV04KC/16KC/64KC and avoids making the 64-Kbit part a supply
requirement.

## Factory sequence for every assembled board

Use external regulated 3.3 V and SWD. Do not depend on NFC EH during factory
provisioning.

1. Program BOR3 once.
2. Flash `prepare-white` and let it finish.
   - Presents the factory-default all-zero ST25 I2C password.
   - Writes static `EH_MODE=0`, authorizes FTM with `FTM.MB_MODE=1`, and
     verifies both values.
   - Performs a Full refresh to white.
   - Commits the matching white frame to internal Flash.
3. Flash `release` without a mass erase.
4. Remove ST-Link/external power and run one Android PATTERN update.
5. Remove the phone completely, wait for power-off, then run a different
   PATTERN. This is the required persistent-baseline test.

The normal programming tasks write only the HEX address range and do not ask
for mass erase. Verify this sequence on one board before applying it to all 30.
Any mass erase or option-byte operation that erases main Flash invalidates the
stored display baseline; rerun `prepare-white` afterward.

## Ghosting policy

Correctly persisting the previous frame removes the major avoidable source of
partial-update artifacts. It does not remove electrophoretic panel ghosting.

- Normal update: one old->target Partial.
- User-visible “clean” operation: Android performs white -> black -> white ->
  target as separate updates, with recharge between each. Keep this manual
  because it is slow and alignment-sensitive.
- Factory/maintenance clean: external 3.3 V Full refresh to white, then restore
  the target.
- Record the Partial count in the Android app; suggest cleaning after about
  five high-contrast updates until real panels establish a better interval.

## Product hardware and mechanical boundary

### Transparent appearance

Standard FR-4 is not transparent and JLCPCB's normal solder-mask choices are
opaque colors. Use a transparent acrylic or polycarbonate carrier/cover and
show the PCB/EPD as part of the visual design. Keep the material above the NFC
coil thin and metal-free, and validate with the complete EPD + adhesive + cover
stack.

### Badge slot and customization holes

The proven antenna occupies x=96.15..174.35 mm and y=68.35..117.10 mm, with
five top-edge tracks at y=68.35..70.55 mm. A top-center PCB slot cuts several
turns and is an RF redesign, not a cosmetic edit.

For the 30-board September run, put the horizontal lanyard slot and decorative
holes in a transparent carrier that extends beyond the PCB. Use a plastic
lanyard clip; metal rings/grommets near the coil reduce Q and EH margin.

If a future PCB revision puts the slot in FR-4, reroute every antenna turn as a
smooth U around the slot, preserve width/spacing/turn count, maintain at least
0.2 mm copper-to-routed-edge clearance (use more mechanically), then remeasure
L/Q/resonance and repeat both-phone 10/10 EH tests before quantity production.

### FPC protection

Prefer a rounded channel/notch in the transparent carrier instead of changing
the proven PCB outline. The FPC must leave J1 straight, bend outside its
stiffener with a generous radius, and be held with Kapton or a soft retainer.
Do not put a sharp internal corner or clamp load at the connector. A PCB-side
notch also intersects the right antenna turns and requires the same RF
revalidation as the badge slot.

## Developer interface retained on the current board

| Interface | Location | Safe intended use |
|---|---|---|
| SWD header J2 | pin 1..5 | SYS_VDD, SWDIO, SWCLK, NRST, GND; firmware/debug |
| TP4 / TP5 | MCU PA11/PA12 package pins | spare GPIO; UART/I2C experiments only after checking AF/remap |
| TP3 | V_EH_RAW | EH measurement; never inject power blindly |
| TP10 | VRAW | post-ideal-diode raw reservoir measurement |
| TP1 / TP11 | VRES_3V3 | reservoir measurement/external-cap experiments |
| TP8 | SYS_VDD | MCU rail measurement |
| TP6 | EPD_SW | switched EPD rail measurement |
| TP7 | GND | probe reference |
| TP9 / TP12 | PWR_REQ / EN_3V3 | power-state diagnosis, not general GPIO |
| J3 (DNP) | VRES_3V3 + GND | optional external reservoir capacitor |

For a later revision, group TP4, TP5, SYS_VDD and GND into a clearly labelled
2.54-mm expansion header. Do not expose V_EH_RAW as “3.3 V out”, and document
that externally powering SYS_VDD while a phone is present is a development
operation with the EPD disconnected unless the reverse-current path has been
reviewed.

## Release gates

- Android image transfer + update: 10/10 on the primary phone and 10/10 on a
  second Android model, with the final mechanical stack installed.
- Power removal after DATA, after Flash staging, and during Partial recovers
  without losing the last committed display baseline.
- Five alternating black/white/high-detail Partial updates remain legible; the
  cleanup flow restores contrast.
- Firmware build stays below 20 KiB code and 7 KiB static RAM.
- `prepare-white` reads back `EH_MODE=0` and `FTM.MB_MODE=1` on every
  production unit.
- No 30-piece order with a changed PCB slot/notch/antenna geometry unless a
  prototype of that exact geometry passes the RF/EH gate.

Primary references:

- ST25DVxxKC datasheet: https://www.st.com/resource/en/datasheet/st25dv64kc.pdf
- STM32G031K6 datasheet: https://www.st.com/resource/en/datasheet/stm32g031k6.pdf
- JLCPCB routed-edge capability: https://jlcpcb.com/capabilities/Capabilities
- Apple Core NFC tag reader setup: https://developer.apple.com/documentation/corenfc/building-an-nfc-tag-reader-app
