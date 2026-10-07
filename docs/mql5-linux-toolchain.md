# MQL5 compilation on Linux

MetaTrader 5 does not ship a native Linux `mql5` compiler binary. On Linux, the practical toolchain is Wine plus the Windows MetaEditor executable that is installed with MetaTrader 5.

## Install

```bash
scripts/install_mql5_linux.sh
```

The installer script:

1. Installs Wine runtime dependencies when `apt-get` is available.
2. Downloads the official MetaTrader 5 Linux installer script.
3. Runs the installer so MetaEditor is available inside the Wine prefix.

If MetaEditor is already installed somewhere non-standard, skip installation and set `METAEDITOR_PATH` before compiling.

## Compile the EA

```bash
scripts/compile_mql5.sh Experts/HorizonAI_2Step.mq5
```

Optional environment variables:

- `METAEDITOR_PATH`: absolute path to `metaeditor64.exe` or `metaeditor.exe`.
- `MQL5_COMPILE_LOG`: output path for the MetaEditor compile log.
- `MT5_INSTALLER_URL`: override URL for the MetaTrader 5 Linux installer script.

The compile script exits non-zero if Wine or MetaEditor is missing, if the source file is missing, or if MetaEditor does not produce the expected `.ex5` output.
