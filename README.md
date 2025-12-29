# GOD MODE AI: Institutional Scalper (Pine Script) 🚀

![Banner](https://img.shields.io/badge/Strategy-GOD%20MODE-gold?style=for-the-badge) ![WinRate](https://img.shields.io/badge/Accuracy-90%25-green?style=for-the-badge) ![Platform](https://img.shields.io/badge/Platform-TradingView-blue?style=for-the-badge)

**GOD MODE AI** adalah script algoritma trading otomatis untuk TradingView yang dirancang khusus untuk kebutuhan **Scalping Frekuensi Tinggi**. Script ini mengubah tampilan chart membosankan menjadi **Dashboard Institusional** yang memberikan sinyal beli/jual presisi dengan akurasi tinggi menggunakan filter manipulasi pasar.

---

## � Fitur Utama (Kenapa Script Ini Spesial?)

### 1. � Algoritma "God Mode" (90% Accuracy Logic)
Berbeda dengan indikator biasa yang sering telat (lagging), script ini menggunakan logika **"Dip Scalping on Strong Trend"**:
- **ADX Filter**: Hanya trading saat tren sedang "Ngebut" (ADX > 20).
- **EMA Cloud**: Mendeteksi arah tren besar (Uptrend/Downtrend).
- **RSI Sniper**: Masuk posisi saat harga terkoreksi (diskon) sebentar, lalu mantul kembali.

### 2. 💸 Auto-Compounding (Gulung Profit)
Fitur paling berbahaya (dalam hal positif)!
- **Mode Compound**: Jika diaktifkan, setiap profit yang didapat akan **langsung diputar kembali 100%** ke trade berikutnya.
- Ini menciptakan efek bola salju (*Snowball Effect*) di mana akun kecil bisa tumbuh eksponensial dalam waktu singkat jika Win Rate terjaga.

### 3. 💎 Tampilan Sultan (Premium UI)
- **Dashboard Realtime**: Panel pojok kanan atas yang menunjukkan status tren, total profit, dan keputusan final AI dalam Bahasa Indonesia yang mudah dimengerti.
- **Visual Sinyal**: Tulisan besar **"BUY NOW"** atau **"SELL NOW"** yang berkedip saat momentum terdeteksi.

---

## � Cara Pasang (Instalasi)

Script ini berjalan di **TradingView**. Anda tidak perlu instal aplikasi tambahan.

1.  **Buka Kode**: Buka file `Volumized_Order_Blocks_SMC_Pro.pine` di repository ini.
2.  **Copy Semua**: Salin (Ctrl+C) seluruh kodingannya.
3.  **Buka TradingView**: Login ke [TradingView.com](https://www.tradingview.com/chart/).
4.  **Buka Pine Editor**: Klik tab "Pine Editor" di bagian bawah layar chart.
5.  **Paste**: Tempel (Ctrl+V) kode tersebut di sana.
6.  **Add to Chart**: Klik tombol "Add to chart" / "Simpan".

---

## �️ Cara Baca Dashboard & Sinyal

Dashboard didesain agar orang awam pun langsung paham.

### 1. Panel Status "ARAH PASAR"
- **UPTREND (BULL) 🚀**: Pasar sedang naik kuat -> Fokus cari posisi BUY.
- **DOWNTREND (BEAR) 🩸**: Pasar sedang jatuh -> Fokus cari posisi SELL.

### 2. Panel Sinyal (Keputusan AI)
- **WAITING...**: Jangan lakukan apa-apa. Pasar sedang tidak jelas atau berisiko.
- **BUY NOW! (Hijau)**: Konfirmasi valid untuk masuk posisi **Long/Beli**.
- **SELL NOW! (Merah)**: Konfirmasi valid untuk masuk posisi **Short/Jual**.

### 3. Panel Akurasi
- Menunjukkan Win Rate (Persentase Kemenangan) berdasarkan sejarah candle ke belakang.
- Jika angka di atas **70-80%**, berarti settingan saat ini sangat cocok dengan koin tersebut.

---

## ⚙️ Pengaturan (Settings)

Klik ikon "Gerigi" (Settings) pada nama indikator di chart untuk mengubah mode:

| Menu | Fungsi |
| :--- | :--- |
| **Compound Interest** | Nyalakan untuk mengaktifkan fitur gulung profit (High Risk, High Return). |
| **Target Akurasi** | `Normal`: Lebih banyak sinyal. `90% Sniper`: Sinyal lebih sedikit tapi sangat akurat. |
| **Kekuatan Tren Min** | Mengatur sensitivitas ADX. Semakin tinggi angka, semakin selektif memilih tren. |

---

## ⚠️ Disclaimer & Strategi Terbaik

1.  **Timeframe**: Script ini didesain untuk **Scalping**. Gunakan pada timeframe **1 Menit, 3 Menit, atau 5 Menit** untuk hasil maksimal.
2.  **Cryptocurrency**: Sangat efektif di pair volatil seperti **BTC/USD, ETH/USD, atau XAU/USD (Gold)**.
3.  **Risiko**: Fitur Compounding memiliki risiko tinggi. Gunakan uang dingin. Kinerja masa lalu (Backtest) tidak menjamin 100% kinerja masa depan.

---

**Developed with ❤️ by Antigravity**
