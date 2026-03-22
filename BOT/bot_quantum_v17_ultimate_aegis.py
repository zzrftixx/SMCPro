import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

# ==============================================================================
# BOT QUANTUM V17 — ULTIMATE AEGIS
# ==============================================================================
# CHANGELOG vs V16:
#   FIX-1  : equity_at_start null-safety (crash saat MT5 belum siap)
#   FIX-2  : Guard sl=0 di manage_defenses (trailing/breakeven salah trigger)
#   FIX-3  : H4 bias filter (blokir entry yang melawan trend H4)
#   FIX-4  : Trailing BUY tidak akan turunkan SL (new_sl > current_sl guard)
#   FIX-5  : Trailing SELL tidak akan naikkan SL (new_sl < current_sl guard)
#   NEW-1  : Threading multi-symbol (scan paralel, bukan serial)
#   NEW-2  : M5 OB sebagai fallback zona jika M15 tidak ada zona aktif
#   NEW-3  : Partial close Layer 1 saat TP1 tercapai (lock profit otomatis)
#   NEW-4  : Daily trade log ke file .txt untuk audit
#   NEW-5  : Cooldown anti-overtrading per symbol (1 trade per 15 menit)
#   NEW-6  : Normalisasi SL ke tick_size broker (cegah rejected order)
# ==============================================================================

# ==========================================
# 1. KONFIGURASI MASTER
# ==========================================
POSSIBLE_SYMBOLS = ["XAUUSDc", "BTCUSDc", "BTCUSDm", "XAUUSDm", "BTCUSD", "XAUUSD"]
TARGET_SYMBOLS   = []

RISK_PERCENT          = 0.5   # Risk per trade (% dari equity)
MAX_DAILY_LOSS_PERCENT = 3.0  # Circuit breaker: stop jika equity turun 3% hari ini
MAGIC_NUMBER          = 171717
DEVIATION             = 10
COOLDOWN_SECONDS      = 900   # Anti-overtrading: minimal 15 menit antar trade per symbol

START_HOUR = 0
END_HOUR   = 23

# Parameter Indikator
ST_PERIOD, ST_FACTOR = 10, 3.0
RSI_LEN              = 14
SL_MULT              = 1.5

# ==========================================
# 2. DYNAMIC SPREAD LIMITS
# ==========================================
SPREAD_LIMITS = {"XAU": 80, "BTC": 200, "DEFAULT": 50}

def get_spread_limit(symbol):
    if "XAU" in symbol: return SPREAD_LIMITS["XAU"]
    if "BTC" in symbol: return SPREAD_LIMITS["BTC"]
    return SPREAD_LIMITS["DEFAULT"]

# ==========================================
# 3. DAILY TRADE LOGGER
# ==========================================
LOG_FILE = f"trade_log_{datetime.now().strftime('%Y%m%d')}.txt"

def write_log(msg):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass  # Jangan sampai log error menghentikan bot

# ==========================================
# 4. CACHING ENGINE (ULTRA-SPEED 0.2s)
# ==========================================
data_cache = {}

def get_cached_data(symbol, timeframe, num_bars):
    cache_key = f"{symbol}_{timeframe}"
    now = time.time()
    ttl = 60 if timeframe == mt5.TIMEFRAME_H4 else \
          60 if timeframe == mt5.TIMEFRAME_H1 else \
          30 if timeframe == mt5.TIMEFRAME_M15 else \
          15 if timeframe == mt5.TIMEFRAME_M5 else 0

    if cache_key in data_cache and (now - data_cache[cache_key][0] < ttl):
        return data_cache[cache_key][1]

    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_bars)
    if rates is None: return None
    df = pd.DataFrame(rates)
    if ttl > 0:
        data_cache[cache_key] = (now, df)
    return df

# ==========================================
# 5. MATH & INDICATOR ENGINE (CLOSED-CANDLE)
# ==========================================
def calc_ema(series, length):
    return series.ewm(span=length, adjust=False).mean()

def calc_atr(df, length=14):
    high_low   = df['high'] - df['low']
    high_close = np.abs(df['high'] - df['close'].shift())
    low_close  = np.abs(df['low']  - df['close'].shift())
    tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    return tr.rolling(window=length).mean()

def calc_rsi(series, length=14):
    delta = series.diff()
    gain  = (delta.where(delta > 0, 0)).rolling(window=length).mean()
    loss  = (-delta.where(delta < 0, 0)).rolling(window=length).mean()
    rs    = gain / loss
    return 100 - (100 / (1 + rs))

def calc_supertrend(df, period=10, multiplier=3.0):
    atr      = calc_atr(df, period)
    hl2      = (df['high'] + df['low']) / 2
    final_ub = hl2 + (multiplier * atr)
    final_lb = hl2 - (multiplier * atr)
    st       = [True] * len(df)
    for i in range(1, len(df)):
        c = df['close'].iloc[i]
        if   c > final_ub.iloc[i-1]: st[i] = True
        elif c < final_lb.iloc[i-1]: st[i] = False
        else:
            st[i] = st[i-1]
            if st[i]     and final_lb.iloc[i] < final_lb.iloc[i-1]: final_lb.iloc[i] = final_lb.iloc[i-1]
            if not st[i] and final_ub.iloc[i] > final_ub.iloc[i-1]: final_ub.iloc[i] = final_ub.iloc[i-1]
    return st

# ==========================================
# 6. REGIME & BIAS ENGINE (ANTI-REPAINT)
# ==========================================
def detect_bias_h4(df_h4):
    """FIX-3: H4 filter — blokir entry yang melawan trend H4."""
    if df_h4 is None or len(df_h4) < 55: return "UNKNOWN"
    ema50  = calc_ema(df_h4['close'], 50).iloc[-2]
    close  = df_h4['close'].iloc[-2]
    return "BULL" if close > ema50 else "BEAR"

def detect_regime_h1(df_h1):
    """H1 regime: BULL / BEAR / CHOPPY menggunakan candle tertutup."""
    if df_h1 is None or len(df_h1) < 50: return "UNKNOWN"
    ema20 = calc_ema(df_h1['close'], 20).iloc[-2]
    ema50 = calc_ema(df_h1['close'], 50).iloc[-2]
    atr   = calc_atr(df_h1, 14).iloc[-2]
    if abs(ema20 - ema50) < (atr * 0.35): return "CHOPPY"
    return "BULL" if ema20 > ema50 else "BEAR"

# ==========================================
# 7. SMC ENGINE: OB + FVG (ANTI-REPAINT)
# ==========================================
def detect_fvg(df, label="M15"):
    """Fair Value Gap — scan dari candle ke-3 dari akhir (exclude running)."""
    bull_fvg = bear_fvg = None
    for i in range(len(df)-3, 2, -1):
        if df['low'].iloc[i] > df['high'].iloc[i-2]:
            bull_fvg = {'top': df['low'].iloc[i], 'bottom': df['high'].iloc[i-2]}
            break
    for i in range(len(df)-3, 2, -1):
        if df['high'].iloc[i] < df['low'].iloc[i-2]:
            bear_fvg = {'top': df['low'].iloc[i-2], 'bottom': df['high'].iloc[i]}
            break
    return bull_fvg, bear_fvg

def detect_ob(df):
    """Volumetric Order Block — bug mitigasi sudah difix (iloc[i+1:-1])."""
    bull_ob = bear_ob = None
    atr     = calc_atr(df, 14)
    vol_sma = df['tick_volume'].rolling(20).mean()

    for i in range(len(df)-3, 10, -1):
        body         = abs(df['close'].iloc[i] - df['open'].iloc[i])
        is_imbalance = body > atr.iloc[i] * 2.0
        is_high_vol  = df['tick_volume'].iloc[i] > vol_sma.iloc[i] * 1.5
        if not (is_imbalance and is_high_vol): continue

        if df['close'].iloc[i] > df['open'].iloc[i] and bull_ob is None:
            for j in range(i-1, max(0, i-8), -1):
                if df['close'].iloc[j] < df['open'].iloc[j]:
                    top = max(df['open'].iloc[j], df['close'].iloc[j])
                    btm = df['low'].iloc[j]
                    if len(df) > i+1 and df['low'].iloc[i+1:-1].min() > top:
                        bull_ob = {'top': top, 'bottom': btm}
                        break

        if df['close'].iloc[i] < df['open'].iloc[i] and bear_ob is None:
            for j in range(i-1, max(0, i-8), -1):
                if df['close'].iloc[j] > df['open'].iloc[j]:
                    top = df['high'].iloc[j]
                    btm = min(df['open'].iloc[j], df['close'].iloc[j])
                    if len(df) > i+1 and df['high'].iloc[i+1:-1].max() < btm:
                        bear_ob = {'top': top, 'bottom': btm}
                        break
        if bull_ob and bear_ob: break
    return bull_ob, bear_ob

# ==========================================
# 8. THE 6-LAYER GATEKEEPER
# ==========================================
def calculate_ultimate_logic(symbol, df_m1, df_m5, df_m15, df_h1, df_h4):
    """
    6 Layer Confluence — semua harus lulus, tidak ada skor numerik.
    Layer 0: H4 Bias (NEW)
    Layer 1: H1 Regime
    Layer 2: M1 Supertrend searah regime
    Layer 3: RSI M1 tidak overbought/oversold di arah yang salah
    Layer 4: Harga di zona SMC (OB atau FVG dari M15, fallback M5)
    Layer 5: Micro rejection wick M1
    """
    if any(d is None for d in [df_m1, df_m5, df_m15, df_h1, df_h4]): return None

    tick = mt5.symbol_info_tick(symbol)
    if tick is None: return None

    # LAYER 0: H4 BIAS FILTER (FIX-3)
    bias_h4 = detect_bias_h4(df_h4)
    if bias_h4 == "UNKNOWN":
        return {"status": "BLOCKED", "reason": "H4_UNKNOWN"}

    # LAYER 1: H1 REGIME
    regime = detect_regime_h1(df_h1)
    if regime in ["CHOPPY", "UNKNOWN"]:
        return {"status": "BLOCKED", "reason": f"H1_REGIME={regime}"}

    # H4 dan H1 harus satu arah
    if bias_h4 != regime:
        return {"status": "BLOCKED", "reason": f"H4_CONFLICT: H4={bias_h4} H1={regime}"}

    # LAYER 2: SUPERTREND M1 SEARAH
    st      = calc_supertrend(df_m1, ST_PERIOD, ST_FACTOR)
    st_bull = st[-2]
    if regime == "BULL" and not st_bull: return {"status": "BLOCKED", "reason": "ST_COUNTER_TREND"}
    if regime == "BEAR" and st_bull:     return {"status": "BLOCKED", "reason": "ST_COUNTER_TREND"}

    # LAYER 3: RSI M1 TIDAK DI ZONA EKSTREM YANG SALAH
    rsi = calc_rsi(df_m1['close'], RSI_LEN).iloc[-2]
    if regime == "BULL" and rsi > 65: return {"status": "BLOCKED", "reason": "RSI_OVERBOUGHT"}
    if regime == "BEAR" and rsi < 35: return {"status": "BLOCKED", "reason": "RSI_OVERSOLD"}

    # LAYER 4: ZONA SMC — M15 PRIMER, M5 FALLBACK (NEW-2)
    bull_ob_m15, bear_ob_m15   = detect_ob(df_m15)
    bull_fvg_m15, bear_fvg_m15 = detect_fvg(df_m15)
    bull_ob_m5,  bear_ob_m5    = detect_ob(df_m5)
    bull_fvg_m5, bear_fvg_m5   = detect_fvg(df_m5)

    def in_zone(zones, price):
        return any(z and z['bottom'] <= price <= z['top'] for z in zones)

    bull_zones_m15 = [bull_ob_m15, bull_fvg_m15]
    bear_zones_m15 = [bear_ob_m15, bear_fvg_m15]
    bull_zones_m5  = [bull_ob_m5,  bull_fvg_m5]
    bear_zones_m5  = [bear_ob_m5,  bear_fvg_m5]

    # Cek M15 dulu, jika tidak ada zona aktif gunakan M5 sebagai fallback
    in_bull_zone = in_zone(bull_zones_m15, tick.ask) or in_zone(bull_zones_m5, tick.ask)
    in_bear_zone = in_zone(bear_zones_m15, tick.bid) or in_zone(bear_zones_m5, tick.bid)

    zone_source = "M15" if in_zone(bull_zones_m15 if regime=="BULL" else bear_zones_m15,
                                    tick.ask if regime=="BULL" else tick.bid) else "M5_FALLBACK"

    if regime == "BULL" and not in_bull_zone: return {"status": "BLOCKED", "reason": "NOT_IN_BULL_ZONE"}
    if regime == "BEAR" and not in_bear_zone: return {"status": "BLOCKED", "reason": "NOT_IN_BEAR_ZONE"}

    # LAYER 5: MICRO REJECTION WICK M1 (RELAXED)
    atr_m1    = calc_atr(df_m1, 14).iloc[-2]
    min_wick  = atr_m1 * 0.1
    close_p   = df_m1['close'].iloc[-2]
    open_p    = df_m1['open'].iloc[-2]
    wick_down = (open_p - df_m1['low'].iloc[-2])  if close_p > open_p else (close_p - df_m1['low'].iloc[-2])
    wick_up   = (df_m1['high'].iloc[-2] - close_p) if close_p > open_p else (df_m1['high'].iloc[-2] - open_p)

    if regime == "BULL" and wick_down < min_wick: return {"status": "BLOCKED", "reason": "NO_BULL_REJECTION_WICK"}
    if regime == "BEAR" and wick_up   < min_wick: return {"status": "BLOCKED", "reason": "NO_BEAR_REJECTION_WICK"}

    return {
        "status":    "VALID_SETUP",
        "direction": "BUY" if regime == "BULL" else "SELL",
        "regime":    regime,
        "bias_h4":   bias_h4,
        "zone_src":  zone_source,
        "ask":       tick.ask,
        "bid":       tick.bid,
        "atr":       atr_m1,
        "buy_sl":    tick.ask - (atr_m1 * SL_MULT),
        "sell_sl":   tick.bid + (atr_m1 * SL_MULT),
    }

# ==========================================
# 9. RUTHLESS RISK MANAGER
# ==========================================
def normalize_price(price, tick_size):
    """FIX-6: Normalisasi harga ke kelipatan tick_size agar tidak rejected broker."""
    if tick_size <= 0: return price
    return round(round(price / tick_size) * tick_size, 10)

def strict_lot_calculator(symbol, sl_dist):
    info     = mt5.account_info()
    sym_info = mt5.symbol_info(symbol)
    if info is None or sym_info is None: return 0

    min_sl = sym_info.point * 50
    if sl_dist < min_sl: sl_dist = min_sl

    risk_money   = info.equity * (RISK_PERCENT / 100.0)
    sl_ticks     = sl_dist / sym_info.trade_tick_size
    loss_per_lot = sl_ticks * sym_info.trade_tick_value
    if loss_per_lot <= 0: return 0

    raw_lot = risk_money / loss_per_lot
    if raw_lot < sym_info.volume_min: return 0  # ATURAN BESI: skip jika modal tidak cukup

    final_lot = min(raw_lot, sym_info.volume_max)
    step      = sym_info.volume_step
    return round(final_lot / step) * step

# ==========================================
# 10. ACTIVE DEFENSE: BREAKEVEN + TRAILING
# ==========================================
def manage_defenses(symbol):
    positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if not positions: return

    df = get_cached_data(symbol, mt5.TIMEFRAME_M1, 50)
    if df is None: return

    atr   = calc_atr(df, 14).iloc[-2]
    trail = atr * 2.0

    for pos in positions:
        # FIX-2: Skip posisi yang SL-nya belum diset oleh broker
        if pos.sl == 0: continue

        entry = pos.price_open
        sl    = pos.sl
        price = pos.price_current

        if pos.type == mt5.ORDER_TYPE_BUY:
            # Breakeven saat profit 1.5x risk
            if price >= entry + (entry - sl) * 1.5 and sl != entry:
                new_sl = normalize_price(entry, mt5.symbol_info(symbol).trade_tick_size)
                mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket,
                                "symbol": symbol, "sl": new_sl, "tp": pos.tp})
                write_log(f"   🔒 BREAKEVEN BUY {symbol} Tiket:{pos.ticket} SL → {new_sl:.5f}")
            # FIX-4: Trailing BUY — new_sl harus > current_sl DAN > entry
            elif price - trail > sl and price > entry:
                new_sl = normalize_price(price - trail, mt5.symbol_info(symbol).trade_tick_size)
                if new_sl > sl and new_sl > entry:
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket,
                                    "symbol": symbol, "sl": new_sl, "tp": pos.tp})

        elif pos.type == mt5.ORDER_TYPE_SELL:
            # FIX-2 lanjutan: sl != entry untuk cek breakeven
            if price <= entry - (sl - entry) * 1.5 and sl != entry:
                new_sl = normalize_price(entry, mt5.symbol_info(symbol).trade_tick_size)
                mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket,
                                "symbol": symbol, "sl": new_sl, "tp": pos.tp})
                write_log(f"   🔒 BREAKEVEN SELL {symbol} Tiket:{pos.ticket} SL → {new_sl:.5f}")
            # FIX-5: Trailing SELL — new_sl harus < current_sl DAN < entry
            elif price + trail < sl and price < entry:
                new_sl = normalize_price(price + trail, mt5.symbol_info(symbol).trade_tick_size)
                if new_sl < sl and new_sl < entry:
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket,
                                    "symbol": symbol, "sl": new_sl, "tp": pos.tp})

# ==========================================
# 11. EXECUTION ENGINE
# ==========================================
last_trade_time = {}  # NEW-5: Cooldown anti-overtrading

def execute_trade(symbol, decision):
    if decision.get("status") != "VALID_SETUP": return

    # NEW-5: Cooldown check — minimal COOLDOWN_SECONDS antar trade per symbol
    if time.time() - last_trade_time.get(symbol, 0) < COOLDOWN_SECONDS:
        remaining = int(COOLDOWN_SECONDS - (time.time() - last_trade_time.get(symbol, 0)))
        return  # Silent skip, akan log saat print cycle berikutnya

    if mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER): return

    sym_info     = mt5.symbol_info(symbol)
    tick_size    = sym_info.trade_tick_size
    limit_spread = get_spread_limit(symbol)

    if sym_info.spread > limit_spread:
        write_log(f"   ⚠️ Spread {symbol} ({sym_info.spread}) > batas {limit_spread}. Skip.")
        return

    dir_str = decision['direction']
    price   = decision['ask'] if dir_str == "BUY" else decision['bid']
    sl      = decision['buy_sl'] if dir_str == "BUY" else decision['sell_sl']

    # FIX-6: Normalisasi harga dan SL ke tick_size
    price = normalize_price(price, tick_size)
    sl    = normalize_price(sl, tick_size)

    sl_dist = abs(price - sl)
    min_sl  = sym_info.point * 50
    if sl_dist < min_sl:
        sl_dist = min_sl
        sl = normalize_price((price - sl_dist) if dir_str == "BUY" else (price + sl_dist), tick_size)

    total_lot = strict_lot_calculator(symbol, sl_dist)
    if total_lot == 0:
        acc = mt5.account_info()
        write_log(f"   ⛔ SKIPPED: Equity ${acc.equity:.2f} tidak kuat menanggung risk {RISK_PERCENT}% untuk {symbol}.")
        return

    min_lot, step = sym_info.volume_min, sym_info.volume_step
    layer_lot     = round((total_lot / 3) / step) * step

    if layer_lot < min_lot:
        layer_lot  = total_lot
        num_layers = 1
    else:
        num_layers = 3

    if dir_str == "BUY":
        order_type = mt5.ORDER_TYPE_BUY
        tps = [
            normalize_price(price + sl_dist * 2, tick_size),
            normalize_price(price + sl_dist * 3, tick_size),
            normalize_price(price + sl_dist * 5, tick_size),
        ]
    else:
        order_type = mt5.ORDER_TYPE_SELL
        tps = [
            normalize_price(price - sl_dist * 2, tick_size),
            normalize_price(price - sl_dist * 3, tick_size),
            normalize_price(price - sl_dist * 5, tick_size),
        ]

    write_log(f"\n   ⚡ V17 ULTIMATE EXECUTION! {dir_str} {symbol} | H4:{decision['bias_h4']} H1:{decision['regime']} | Zone:{decision['zone_src']} | Layers:{num_layers} | Lot/Layer:{layer_lot}")

    success_count = 0
    for i in range(num_layers):
        request = {
            "action":       mt5.TRADE_ACTION_DEAL,
            "symbol":       symbol,
            "volume":       float(layer_lot),
            "type":         order_type,
            "price":        price,
            "sl":           sl,
            "tp":           tps[i] if num_layers > 1 else tps[0],
            "deviation":    DEVIATION,
            "magic":        MAGIC_NUMBER,
            "comment":      f"V17_{dir_str[0]}_L{i+1}",
            "type_time":    mt5.ORDER_TIME_GTC,
        }
        for filling in [mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_RETURN]:
            request["type_filling"] = filling
            res = mt5.order_send(request)
            if res and res.retcode == mt5.TRADE_RETCODE_DONE:
                write_log(f"      ✅ L{i+1} MASUK! Tiket:{res.order} | TP:{tps[i]:.4f} | RR 1:{[2,3,5][i]}")
                success_count += 1
                break
            elif res:
                write_log(f"      ↩️ Filling {filling} gagal (code:{res.retcode}), coba berikutnya...")

    if success_count > 0:
        last_trade_time[symbol] = time.time()  # Catat waktu trade berhasil

# ==========================================
# 12. THREADED SYMBOL ANALYZER (NEW-1)
# ==========================================
def analyze_symbol(sym):
    """Fungsi analisis satu symbol — dipanggil paralel via ThreadPoolExecutor."""
    df_m1  = get_cached_data(sym, mt5.TIMEFRAME_M1,  300)
    df_m5  = get_cached_data(sym, mt5.TIMEFRAME_M5,  300)
    df_m15 = get_cached_data(sym, mt5.TIMEFRAME_M15, 300)
    df_h1  = get_cached_data(sym, mt5.TIMEFRAME_H1,  300)
    df_h4  = get_cached_data(sym, mt5.TIMEFRAME_H4,  300)

    decision = calculate_ultimate_logic(sym, df_m1, df_m5, df_m15, df_h1, df_h4)
    return sym, decision

def init_broker():
    return mt5.initialize()

# ==========================================
# 13. SUPER-LOOP (0.2s) — FINAL ARCHITECTURE
# ==========================================
if __name__ == "__main__":
    if not init_broker():
        print("❌ MT5 gagal terhubung."); quit()

    print("🔄 Scanning Broker...")
    for sym in POSSIBLE_SYMBOLS:
        info = mt5.symbol_info(sym)
        if info is not None and info.visible:
            TARGET_SYMBOLS.append(sym)

    if not TARGET_SYMBOLS:
        print("❌ Tidak ada pair valid."); mt5.shutdown(); quit()

    write_log(f"✅ Active Symbols: {TARGET_SYMBOLS}")
    write_log("🤖 TERMINAL QUANTUM V17 (ULTIMATE AEGIS) LIVE.")
    write_log(f"Mode: 6-Layer Confluence | H4+H1 Bias | M15+M5 SMC | Circuit Breaker {MAX_DAILY_LOSS_PERCENT}% | Cooldown {COOLDOWN_SECONDS}s | Threaded Scan")

    last_print     = {}
    current_day    = datetime.now().day

    # FIX-1: Null-safety untuk equity_at_start
    acc            = mt5.account_info()
    equity_at_start = acc.equity if acc else 0.0

    try:
        while True:
            now = datetime.now()

            # ── Reset Circuit Breaker setiap ganti hari ──────────────────────
            if now.day != current_day:
                acc = mt5.account_info()
                equity_at_start = acc.equity if acc else equity_at_start
                current_day     = now.day
                write_log(f"\n🌅 Hari baru. Circuit Breaker direset. Equity awal: ${equity_at_start:.2f}")

            # ── Circuit Breaker Check ─────────────────────────────────────────
            acc = mt5.account_info()
            if acc and equity_at_start > 0:
                daily_dd = ((equity_at_start - acc.equity) / equity_at_start) * 100
                if daily_dd >= MAX_DAILY_LOSS_PERCENT:
                    if time.time() - last_print.get("CIRCUIT", 0) > 300:
                        write_log(f"🛑 CIRCUIT BREAKER AKTIF: Drawdown {daily_dd:.2f}% >= {MAX_DAILY_LOSS_PERCENT}%. Bot dikunci hari ini.")
                        last_print["CIRCUIT"] = time.time()
                    # Defense tetap jalan meski circuit breaker aktif
                    for sym in TARGET_SYMBOLS:
                        manage_defenses(sym)
                    time.sleep(60)
                    continue

            # ── Active Defense (selalu jalan) ─────────────────────────────────
            for sym in TARGET_SYMBOLS:
                manage_defenses(sym)

            # ── Jam Trading Check ─────────────────────────────────────────────
            if now.hour < START_HOUR or now.hour > END_HOUR:
                time.sleep(60); continue

            # ── Threaded Scan Semua Symbol Paralel (NEW-1) ────────────────────
            results = {}
            with ThreadPoolExecutor(max_workers=len(TARGET_SYMBOLS)) as executor:
                futures = {executor.submit(analyze_symbol, sym): sym for sym in TARGET_SYMBOLS}
                for future in as_completed(futures):
                    try:
                        sym, decision = future.result(timeout=5)
                        results[sym] = decision
                    except Exception as e:
                        write_log(f"   ⚠️ Thread error untuk {futures[future]}: {e}")

            # ── Proses Hasil Scan ─────────────────────────────────────────────
            for sym, decision in results.items():
                if decision is None: continue

                if decision.get("status") == "BLOCKED":
                    if time.time() - last_print.get(sym, 0) > 60:
                        write_log(f"   [{now.strftime('%H:%M:%S')}] {sym}: Memantau... ({decision['reason']})")
                        last_print[sym] = time.time()

                elif decision.get("status") == "VALID_SETUP":
                    execute_trade(sym, decision)

            time.sleep(0.2)

    except KeyboardInterrupt:
        write_log("\n🛑 V17 Ultimate Aegis dimatikan manual.")
        mt5.shutdown()
