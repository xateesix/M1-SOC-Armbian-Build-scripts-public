# Serial console (UART debug)

Required for boot logs, login, and troubleshooting when display or network are not enough.

## Adapter

Use a **USB to TTL serial adapter** with a genuine **FTDI FT232RL** chip (stable drivers on Windows).

Example (tested): [DSD TECH SH-U09C on Amazon](https://www.amazon.com/DSD-TECH-Adapter-FT232RL-Compatible/dp/B07BBPX8B8) (model SH-U09C, FT232RL, includes Dupont cable).

| Requirement | Detail |
|-------------|--------|
| Chip | FTDI FT232RL (or FT232RNL) recommended over CP2102/CH340 |
| Logic level | **3.3 V TTL**  -  set the adapter VCC jumper to **3.3V** (not 5V) |
| Pins used | **GND**, **TXD** (adapter  ->  board RX), **RXD** (adapter  ->  board TX) |
| Cable | Female-to-female Dupont jumpers (often included with the adapter) |

Do **not** connect adapter **VCC** to the board unless you intentionally need to power something; GND + TX + RX are enough for console.

## Board settings

| Setting | Value |
|---------|--------|
| Header | UART3 on the S1-SOC control board |
| Baud rate | **1500000** (not 115200) |
| Linux console | **`ttyS3`** at 1500000 baud (older factory notes mention `ttyFIQ0`) |
| Data | 8N1, no flow control |

## PC terminal

| OS | Examples |
|----|----------|
| Windows | PuTTY, Tera Term, or `putty -serial COMx -sercfg 1500000` |
| Linux / WSL | `picocom -b 1500000 /dev/ttyUSB0` or `minicom` |

Select the COM port assigned to the FTDI adapter. If the port does not appear, install drivers from [FTDI](https://ftdichip.com/drivers/vcp-drivers/).

## Safety

Printer mains and 24 V may be present on the board. Prefer debugging with **USB/network disconnected from the printer** when probing headers, or work only when qualified.