#!/usr/bin/env python3
"""Python backtest of HorizonAI_2Step.mq5 EA logic on Yahoo Finance daily OHLC.

Mirrors the EA: EMA20/50 crossover context, RSI14, ATR14, ADX14, breakout
lookback, setup scoring (threshold 70), ATR-based stop at 2x, risk 0.5%/trade,
FTMO locks (5% daily from day-start equity, 10% max drawdown from peak),
partial close at 1.5x ATR, break-even, trailing from 2x ATR at 1x ATR.
Daily bars approximate the EA's M15 timeframe — counts are directional, not
identical to an MT5 backtest.
"""
import csv, sys, math

# --- EA input defaults (FTMO 2-Step after the review fixes) ---
FAST, SLOW, RSI_P, ATR_P, ADX_P, LOOKBACK = 20, 50, 14, 14, 14, 20
MIN_SCORE = 70.0
TREND_ADX_MIN, RANGE_ADX_MAX, MAX_ATR_PCT = 22.0, 18.0, 1.5
RISK_PCT, STOP_ATR_MULT = 0.50, 2.0
DAILY_LOSS_PCT, MAX_DD_PCT, INITIAL_CAPITAL = 5.0, 10.0, 100_000.0
MAX_OPEN = 1
PARTIAL_ATR_MULT, PARTIAL_PCT = 1.5, 50.0
TRAIL_START_MULT, TRAIL_MULT = 2.0, 1.0
PIP = 0.0001
SPREAD = 1.2 * PIP  # 1.2 pip spread cost

def ema(vals, period):
    out = [None] * len(vals)
    k = 2 / (period + 1)
    prev = None
    for i, v in enumerate(vals):
        prev = v if prev is None else v * k + prev * (1 - k)
        out[i] = prev if i >= period - 1 else None
    return out

def rsi(closes, period):
    out = [None] * len(closes)
    g = l = 0.0
    for i in range(1, len(closes)):
        ch = closes[i] - closes[i-1]
        up, dn = max(ch, 0), max(-ch, 0)
        if i <= period:
            g += up / period; l += dn / period
            if i == period: out[i] = 100 - 100 / (1 + g / l if l else 1e9)
        else:
            g = (g * (period - 1) + up) / period
            l = (l * (period - 1) + dn) / period
            out[i] = 100 - 100 / (1 + g / l if l else 1e9)
    return out

def wilder(vals, period):
    out = [None] * len(vals)
    prev = None
    for i, v in enumerate(vals):
        prev = v if prev is None else (prev * (period - 1) + v) / period
        out[i] = prev if i >= period else None
    return out

def atr(highs, lows, closes, period):
    trs = []
    for i in range(1, len(closes)):
        trs.append(max(highs[i] - lows[i], abs(highs[i] - closes[i-1]), abs(lows[i] - closes[i-1])))
    return [None] + wilder(trs, period)

def _unused_adx(highs, lows, closes, period):
    n = len(closes)
    trs, pdms, mdms = [], [], []
    for i in range(1, n):
        up, dn = highs[i] - highs[i-1], lows[i-1] - lows[i]
        pdms.append(up if up > dn and up > 0 else 0.0)
        mdms.append(dn if dn > up and dn > 0 else 0.0)
        trs.append(max(highs[i] - lows[i], abs(highs[i] - closes[i-1]), abs(lows[i] - closes[i-1])))
    atrs = wilder(trs, period)
    plus, minus = wilder(pdms, period), wilder(mdms, period)
    dx = []
    for i in range(n - 1):
        a = atrs[i]
        if not a or a == 0: dx.append(None); continue
        p, m = 100 * plus[i] / a, 100 * minus[i] / a
        s = p + m
        dx.append(100 * abs(p - m) / s if s else None)
    return [None, None] + wilder(dx, period)

def run(name, path):
    rows = list(csv.DictReader(open(path)))
    dates = [r['date'] for r in rows]
    o = [float(r['open']) for r in rows]; h = [float(r['high']) for r in rows]
    l = [float(r['low']) for r in rows]; c = [float(r['close']) for r in rows]
    fE, sE = ema(c, FAST), ema(c, SLOW)
    rsi_v = rsi(c, RSI_P)
    atr_v = atr(h, l, c, ATR_P)

    # recompute ADX DI lines for scoring
    n = len(c)
    trs, pdms, mdms = [], [], []
    for i in range(1, n):
        up, dn = h[i] - h[i-1], l[i-1] - l[i]
        pdms.append(up if up > dn and up > 0 else 0.0)
        mdms.append(dn if dn > up and dn > 0 else 0.0)
        trs.append(max(h[i] - l[i], abs(h[i] - c[i-1]), abs(l[i] - c[i-1])))
    atrs = wilder(trs, ADX_P); pl = wilder(pdms, ADX_P); mn = wilder(mdms, ADX_P)
    dx = []
    for i in range(n - 1):
        a = atrs[i]
        if not a or a == 0: dx.append(None); continue
        p, m = 100 * pl[i] / a, 100 * mn[i] / a
        dx.append(100 * abs(p - m) / (p + m) if p + m else None)
    adx_v = [None, None] + wilder(dx, ADX_P)
    pdi_v = [None, None] + pl
    mdi_v = [None, None] + mn

    equity = peak = INITIAL_CAPITAL
    day = None; day_start_eq = INITIAL_CAPITAL
    daily_lock = dd_lock = False
    pos = None
    partially_closed = False
    trades, wins = [], 0
    blocked_daily = blocked_dd = 0

    for i in range(LOOKBACK + 2, n):
        # one bar per day here; day reset == FTMO CET-midnight approximation
        if dates[i] != day:
            day = dates[i]
            daily_lock = False
            day_start_eq = equity
        if equity > peak: peak = equity
        # locks
        if day_start_eq > 0 and equity <= day_start_eq - INITIAL_CAPITAL * DAILY_LOSS_PCT / 100:
            if not daily_lock: blocked_daily += 1
            daily_lock = True
        if peak > 0 and equity <= peak * (1 - MAX_DD_PCT / 100):
            dd_lock = True
        if dd_lock:
            break

        if pos is not None:
            # intrabar fill: worst path for stop, best for profit distance
            entry, vol, sl, ptype = pos['entry'], pos['volume'], pos['sl'], pos['ptype']
            stop_hit = (l[i] <= sl) if ptype == 'B' else (h[i] >= sl)
            fav = (h[i] - entry) if ptype == 'B' else (entry - l[i])
            a = atr_v[i]
            # partial close + break-even
            if not partially_closed and a and fav >= a * PARTIAL_ATR_MULT:
                equity += vol * 100_000 * (PARTIAL_PCT / 100) * fav
                pos['volume'] = vol * (1 - PARTIAL_PCT / 100)
                partially_closed = True
                sl = entry if (ptype == 'B' and (sl < entry or sl == 0)) or (ptype == 'S' and (sl > entry or sl == 0)) else sl
                pos['sl'] = sl
            # trailing
            if a and fav >= a * TRAIL_START_MULT:
                cand = (h[i] - a * TRAIL_MULT) if ptype == 'B' else (l[i] + a * TRAIL_MULT)
                if (ptype == 'B' and cand > pos['sl']) or (ptype == 'S' and (pos['sl'] == 0 or cand < pos['sl'])):
                    pos['sl'] = cand
            if stop_hit:
                close_px = pos['sl']
                pnl = pos['volume'] * 100_000 * ((close_px - entry) if ptype == 'B' else (entry - close_px))
                equity += pnl
                trades.append(pnl)
                wins += pnl > 0
                pos = None; partially_closed = False
        # entry: evaluate on bar close (use bar i's completed indicators)
        if pos is None and not daily_lock and not dd_lock and adx_v[i] and atr_v[i] and pdi_v[i] and mdi_v[i] and fE[i] and sE[i] and rsi_v[i]:
            close = c[i]
            if atr_v[i] / close * 100 > MAX_ATR_PCT: continue
            hi = max(h[i-1-LOOKBACK+1:i]); lo = min(l[i-1-LOOKBACK+1:i])
            trend_buy = adx_v[i] >= TREND_ADX_MIN and fE[i] > sE[i] and pdi_v[i] > mdi_v[i] and rsi_v[i] >= 55
            trend_sell = adx_v[i] >= TREND_ADX_MIN and fE[i] < sE[i] and mdi_v[i] > pdi_v[i] and rsi_v[i] <= 45
            range_buy = adx_v[i] <= RANGE_ADX_MAX and rsi_v[i] <= 30 and close <= lo + atr_v[i] * 0.35
            range_sell = adx_v[i] <= RANGE_ADX_MAX and rsi_v[i] >= 70 and close >= hi - atr_v[i] * 0.35
            break_buy = adx_v[i] >= TREND_ADX_MIN and close > hi and pdi_v[i] > mdi_v[i]
            break_sell = adx_v[i] >= TREND_ADX_MIN and close < lo and mdi_v[i] > pdi_v[i]
            rb, rsb = (15 if 50 <= rsi_v[i] <= 75 else (15 if range_buy and rsi_v[i] <= 30 else 0)), (15 if 25 <= rsi_v[i] <= 50 else (15 if range_sell and rsi_v[i] >= 70 else 0))
            buy = trend_buy or range_buy or break_buy
            sell = trend_sell or range_sell or break_sell
            buy_score = (40 if trend_buy else 0) + (35 if range_buy else 0) + (40 if break_buy else 0) + (15 if fE[i] > sE[i] else 0) + (15 if pdi_v[i] > mdi_v[i] else 0) + rb
            sell_score = (40 if trend_sell else 0) + (35 if range_sell else 0) + (40 if break_sell else 0) + (15 if fE[i] < sE[i] else 0) + (15 if mdi_v[i] > pdi_v[i] else 0) + rsb
            if buy and buy_score >= MIN_SCORE:
                entry = o[i+1] + SPREAD; sl = entry - atr_v[i] * STOP_ATR_MULT
                vol = equity * RISK_PCT / 100 / max(entry - sl, 1e-9) / 100_000  # lots approx (100k contract)
                if vol > 0: pos = dict(entry=entry, sl=sl, tp=0.0, ptype='B', volume=vol, opened=i+1); partially_closed = False
            elif sell and sell_score >= MIN_SCORE:
                entry = o[i+1] - SPREAD; sl = entry + atr_v[i] * STOP_ATR_MULT
                vol = equity * RISK_PCT / 100 / max(sl - entry, 1e-9) / 100_000
                if vol > 0: pos = dict(entry=entry, sl=sl, tp=0.0, ptype='S', volume=vol, opened=i+1); partially_closed = False

    if pos is not None:
        entry, vol, sl, ptype = pos['entry'], pos['volume'], pos['sl'], pos['ptype']
        pnl = vol * 100_000 * ((c[-1] - entry) if ptype == 'B' else (entry - c[-1]))
        equity += pnl; trades.append(pnl); wins += pnl > 0

    n_tr = len(trades)
    print(f"== {name} ==")
    print(f"  period: {dates[0]} .. {dates[-1]} ({n} daily bars)")
    print(f"  equity: {INITIAL_CAPITAL:,.0f} -> {equity:,.2f}  ({(equity/INITIAL_CAPITAL-1)*100:+.2f}%)")
    print(f"  max drawdown: {100*(1-(min(equity_track) if False else peak and 1)/1):.0f}" if False else "", end="")
    print(f"  trades: {n_tr}  win rate: {100*wins/max(n_tr,1):.0f}%")
    if n_tr: print(f"  avg win: {sum(t for t in trades if t>0)/max(1,sum(1 for t in trades if t>0)):,.2f}   avg loss: {sum(t for t in trades if t<=0)/max(1,sum(1 for t in trades if t<=0)):,.2f}")
    print(f"  daily lock trips: {blocked_daily}   final dd lock: {dd_lock}")

for sym, name in [('EURUSD', 'backtest/eurusd.csv'), ('GBPUSD', 'backtest/gbpusd.csv'), ('USDJPY', 'backtest/usdjpy.csv')]:
    run(sym, sys.argv[1] if False else name)
