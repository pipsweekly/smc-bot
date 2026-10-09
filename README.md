# SMC MTF Strict RRR Expert Advisor for Synthetic Indices

This project contains a MetaTrader 5 Expert Advisor built from the original trading logic in `smc code.txt`, tuned for synthetic indices such as Volatility 10/25/50/75/100, Crash 500/1000, Boom 500/1000, and similar 24/7 synthetic instruments.

## File

- `SMC_MTF_StrictRRR.mq5` — the EA source file.

## Recommended usage

1. Install MetaTrader 5 on this machine.
2. Open or create an EA project and paste the source from `SMC_MTF_StrictRRR.mq5`.
3. Compile the EA in MetaEditor.
4. Attach it to a Weltrade synthetic index chart such as `VOL75`, `VOL100`, `CRASH500`, `BOOM500`, `STEP`, or your broker's equivalent symbol name.
5. Leave the synthetic index settings enabled.
6. Use a demo account first and optimize the inputs before live use.

## Compilation requirements

This project cannot be compiled in a plain Python environment. To compile the Expert Advisor here, you need:

- Windows 10 or 11
- MetaTrader 5 installed with MetaEditor
- MQL5 compiler included with the MT5 installation
- A broker account or demo account with synthetic indices enabled

See `COMPILATION_REQUIREMENTS.txt` for the full list.

## Synthetic-index tuning included

- spread filter to avoid poor-quality executions
- lower minimum FVG threshold for synthetic volatility behavior
- extra safety cap on risk sizing for synthetic instruments
- support and resistance trendline confirmation
- continuation flag detection for impulsive moves followed by consolidation
- chart visual toggles for SMC zones, pivot levels, and trendlines
- persistent object naming by symbol/timeframe for cleaner chart reloads
- no dependency on normal session open/close logic
- M5/M1 entry confirmation optimized for continuous synthetic index flow

## Notes

- This is a strategy EA designed for discretionary testing and optimization.
- It has strict risk-to-reward enforcement (`InpMinRRR`) and a volatility-based lot-size calculator.
- It checks higher-timeframe SMC/FVG zones and validates with M5/M1 confirmation.
- Because this is a trading system, backtest and forward-test it thoroughly before using it in a live account.
