# Primary references and vendored components

- Good Display GDEY029T94 product/sample page:
  <https://www.good-display.com/product/386.html>
- GDEY029T94 / SSD1680 specification used for command table and timing:
  <https://www.laskakit.cz/user/related_files/gdey029t94.pdf>
- ST25DV04K datasheet, DS10925:
  <https://www.st.com/resource/en/datasheet/st25dv04k.pdf>
- ST25DVxxK errata ES0616 (FTM 256-byte read and watchdog workarounds):
  <https://www.st.com/resource/en/errata_sheet/es0616-st25dv04k-st25dv16k-and-st25dv64k-device-limitations-stmicroelectronics.pdf>
- AN4913, EH delivery impact during RF communication:
  <https://www.st.com/resource/en/application_note/an4913-energy-harvesting-delivery-impact-on-st25dvi2c-series-behaviour-during-rf-communication-stmicroelectronics.pdf>
- TPS22917 datasheet:
  <https://www.ti.com/lit/ds/symlink/tps22917.pdf>

Vendored under `Drivers/`:

- STM32G0xx HAL Driver v1.4.7
- CMSIS Device G0 v1.4.5
- CMSIS Core 5.6.0

Each vendor subtree contains its upstream license. Application code in `Core/` is project code.
