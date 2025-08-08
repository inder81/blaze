SupertrendEA.mq5

Overview:
- Expert Advisor implementing a Supertrend strategy (ATR-based bands) with risk-based position sizing, spread filter, SL/TP, session filter, and optional trailing on the Supertrend line.

Install:
1) Close MetaTrader 5.
2) Copy SupertrendEA.mq5 to your terminal's MQL5/Experts/ folder.
   - In MT5: File -> Open Data Folder -> MQL5 -> Experts
3) Open MetaEditor, load SupertrendEA.mq5 and press F7 to compile.
4) In MT5, refresh the Navigator (or restart), then drag the EA onto a chart and enable Algo Trading.

Inputs (key):
- InpSignalTimeframe: timeframe used for the Supertrend signal (default H1)
- InpATRPeriod, InpATRMultiplier: ATR settings for bands
- InpTradeLong, InpTradeShort: enable/disable direction
- InpUseRiskPercent, InpRiskPercent: risk-based lot sizing; or use InpFixedLot
- InpEnableTP, InpRiskReward: TP multiple of risk (SL distance)
- InpEnableTrailing: trail SL on the live Supertrend line
- InpMaxSpreadPoints: max allowed spread for new entries
- InpSessionStart, InpSessionEnd: broker-time session window
- InpMagic: magic number for trade identification

Logic:
- Enters on trend flip confirmed on the last closed bar.
- Initial SL at Supertrend line; optional TP = risk distance * InpRiskReward.
- Trailing (if enabled) moves SL along Supertrend while respecting broker stop levels.
- One position per symbol (per this EA).

Notes:
- If you see an error like "'(' - expressions are not allowed on a global scope" for a different file (e.g., cursor.mq5), remove/fix that file or compile SupertrendEA.mq5 only.
- Test on demo before live. Adjust ATR/TF per symbol characteristics.