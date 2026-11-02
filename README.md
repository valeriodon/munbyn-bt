# MunbynBT

Print from a Mac to the **MUNBYN ITPP130B** thermal label printer over **Bluetooth**.

MUNBYN only ships a Bluetooth driver for Windows. On macOS the ITPP130B can print over Bluetooth only from MUNBYN Editor in Chrome. MunbynBT adds a regular **"MUNBYN ITPP130B (Bluetooth)"** printer to Printers & Scanners, so you can print from Preview, Safari, Chrome or any other app. A menu bar panel holds the settings.

![Menu bar panel](docs/menu.png)

> Unofficial project, not affiliated with or endorsed by MUNBYN. It has been written for the ITPP130B; other MUNBYN Bluetooth models that MUNBYN Editor handles the same way (ITPP941B, RW411B) may work if you pick them under *Bluetooth Printer* in the panel, but they are untested.

## Install

You need the Xcode command line tools (`xcode-select --install` if you don't have Xcode).

```bash
git clone https://github.com/valeriodon/munbyn-bt.git
cd munbyn-bt
./install.sh
```

The installer:
1. builds the app;
2. installs it in `~/Applications` with a login item;
3. adds the printer queue, which asks for your password.

On first launch macOS asks whether MunbynBT may use Bluetooth: click **Allow**. If you had paired the printer in System Settings › Bluetooth, remove it there; the driver connects on its own.

## Use

- **From any app:** File › Print › *MUNBYN ITPP130B (Bluetooth)*.
  - Pick your **label size** (100x150 mm, 4x6 in, …) to print the page as it is.
  - Pick **A4** or **Letter** for shipping labels that come on a full sheet. MunbynBT crops the white margins, rotates the label if needed and fits it to the label size chosen in the panel.
- **Menu bar panel:**
  - status, last print and connected printer;
  - label size, density (1-15), speed (1-6), margin cropping, dithering for photos;
  - print a PDF or image, a test label or the printer's self-test page;
  - check the connection, search for and pick a printer, open the log.
- **Command line:** `munbyn-bt print label.pdf`, `munbyn-bt test`, `munbyn-bt scan`. See `munbyn-bt help` for the options.

The log is in `~/Library/Logs/munbyn-bt.log`.

## How it works

The CUPS queue uses a pass-through PPD and the `socket://127.0.0.1:9100` backend, so the PDF reaches the MunbynBT app unchanged. MunbynBT then:

1. renders each page at 203 dpi in black and white (crop, rotate and fit as needed);
2. sends it over Bluetooth LE with the same commands MUNBYN Editor uses:
   - TSPL: `SIZE`, `GAP`, `SPEED`, `DENSITY`, `BITMAP`, `PRINT`, where a 1 bit in the bitmap is white;
   - written without response to the ISSC "transparent UART" service `49535343-FE7D-4AE5-8FA9-9FAFD205E455`, characteristic `49535343-8841-…`;
   - in 180-byte chunks, one every 8 ms.

![A label placed sideways on an A4 sheet, after cropping, rotation and fitting](docs/a4-fit.png)

## Uninstall

```bash
./uninstall.sh
```

## License

MIT, see [LICENSE](LICENSE).
