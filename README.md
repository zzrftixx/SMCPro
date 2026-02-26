# QUANTUM NOVA PLATINUM V2: The Ultimate Trading Machine 🤖📊

![Platform](https://img.shields.io/badge/Platform-TradingView-blue?style=for-the-badge) ![Version](https://img.shields.io/badge/Version-Platinum%20V2-gold?style=for-the-badge) ![Status](https://img.shields.io/badge/Status-Live%20&%20Tested-green?style=for-the-badge)

**QUANTUM NOVA PLATINUM V2** bukanlah sekadar indikator biasa, melainkan sebuah **"Super Computer"** analisa teknikal yang terintegrasi langsung di chart TradingView Anda. Indikator ini menggabungkan belasan konsep trading kelas atas (Smart Money Concepts, Volumized Order Blocks, Price Action, Trend, Momentum) menjadi satu sistem **AI Voting Engine** yang cerdas dan objektif.

Dengan tampilan ala **Bloomberg Terminal**, indikator ini mendeteksi jejak "Bandar" (Smart Money), mengkonfirmasinya dengan momentum dan tren, lalu menyajikan **Trading Plan lengkap (Entry, Take Profit, Stop Loss)** secara langsung di layar Anda.

---

## 🌟 Fitur Utama & Indikator Terintegrasi (Apa yang Baru?)

Pembaruan V2 membawa integrasi masif dari berbagai script premium menjadi satu kesatuan:

### 1. 🏗️ Volumized Order Blocks (Flux Charts)
*   **Fungsi:** Mendeteksi blok pesanan institusi (Buy/Sell) berdasarkan ayunan harga (swings) dan memvalidasinya menggunakan *volume bid/ask*.
*   **Keunggulan:** Tidak semua Order Block itu valid. Indikator ini menyoroti blok mana yang didukung oleh lonjakan volume nyata, mengurangi manipulasi (fakeout). Menampilkan persentase Bullish/Bearish Volume di dalam box Order Block.

### 2. 🧠 Smart Money Concepts Pro (LuxAlgo Integration)
*   **Internal & Swing Structure:** Melacak struktur pasar secara akurat (Higher High, Lower Low) baik untuk tren minor maupun mayor.
*   **Break of Structure (BOS) & Change of Character (CHoCH):** Mendeteksi pergantian arah tren secara real-time.
*   **Premium & Discount Zones:** Mengetahui kapan harga sedang "mahal" (fokus Sell) dan kapan sedang "murah" (fokus Buy).
*   **Fair Value Gaps (FVG) & EQH/EQL:** Menyoroti celah harga dan area likuiditas (Equal Highs/Lows) yang sering menjadi magnet harga.

### 3. ⏱️ Multi-Timeframe (MTF) BOS & MSS
*   **Fungsi:** Memungkinkan Anda melihat Market Structure Shift (MSS) dan Break of Structure (BOS) dari *Timeframe yang lebih besar* tanpa harus berpindah chart.
*   **Keunggulan:** Anda bisa trading di 15 Menit, sambil melihat garis BOS/MSS dari Timeframe 1 Jam dan 4 Jam. Ini memberikan *helicopter view* yang luar biasa tajam.

### 4. 🕯️ Price Action: Engulfing Candles
*   **Fungsi:** Mendeteksi pola candlestick pembalikan arah (Reversal) yang paling kuat: Bullish & Bearish Engulfing.
*   **Keunggulan:** Pola ini bertindak sebagai *trigger* konfirmasi tambahan saat harga sudah memasuki area Order Block.

### 5. 🌊 Trend & Momentum Core (The AI Engine)
*   **SuperTrend & 3 EMA (Exponential Moving Average):** Penentu arah tren utama.
*   **RSI (Relative Strength Index):** Pengukur kejenuhan pasar (Overbought/Oversold).
*   **UT Bot Alerts (Volatility):** Mengonfirmasi sinyal berdasarkan volatilitas langkah harga.

---

## 🖥️ Bloomberg Terminal Dashboard & AI Prediction

Jantung dari indikator ini adalah Dashboard-nya. Sistem AI memberikan nilai (Score) dari 0 hingga 100 berdasarkan keselarasan semua indikator di atas.

**Cara Membaca Dashboard:**
*   **SMC FLUX:** Menunjukkan bias Struktur Pasar saat ini (Bullish/Bearish) berdasarkan logika LuxAlgo SMC.
*   **Score & AI PREDICTION:**
    *   **Skor >= 80 (ZONA BUY):** Sinyal SANGAT KUAT untuk Long/Beli. Tren, Momentum, dan Smart Money semuanya mendukung kenaikan.
    *   **Skor <= 20 (ZONA SELL):** Sinyal SANGAT KUAT untuk Short/Jual.
    *   **Skor 21 - 79 (WAITING):** Pasar sedang ragu (Sideways/Konsolidasi). **JANGAN ENTRY**. Menunggu konfirmasi.
*   **TARGET PRICE (TP & SL):** Jika Skor mencapai 80 atau 20, sistem otomatis memberikan level Take Profit dan Stop Loss yang dihitung secara dinamis menggunakan volatilitas (ATR).

---

## 🎯 Strategi Trading yang Direkomendasikan

Indikator ini dirancang untuk gaya **"Wait and Strike" (Sniper Trading)**. Jangan mengejar harga, biarkan harga mendatangi zona Anda.

### Strategi: SMC Confluence (Order Block + Score)

**Aturan untuk BUY (LONG):**
1.  **Tunggu Harga Masuk Order Block Hijau (Bullish):** Harga harus *retrace* turun memasuki area Volumized Order Block atau Internal SMC Order Block.
2.  **Konfirmasi FVG/Discount Zone (Opsional namun Kuat):** Area OB berada di dalam Discount Zone (Murah) atau bertepatan dengan Bullish FVG.
3.  **Cek Dashboard (AI Score):** Pastikan skor AI di Dashboard melonjak menjadi **>= 80**.
4.  **Trigger (Opsional):** Muncul pola Bullish Engulfing atau garis CHoCH tembus ke atas.
5.  **Eksekusi:** Entry Buy saat sinyal BUY muncul, letakkan Stop Loss sedikit di bawah kotak Order Block (atau ikuti SL dari Dashboard), dan Take Profit di Swing High terdekat (atau ikuti TP dari Dashboard).

**Aturan untuk SELL (SHORT):**
1.  **Tunggu Harga Masuk Order Block Merah (Bearish):** Harga naik (*pullback*) masuk ke dalam area Volumized Order Block merah.
2.  **Konfirmasi:** Area OB berada di Premium Zone (Mahal).
3.  **Cek Dashboard (AI Score):** Pastikan skor AI turun drastis menjadi **<= 20**.
4.  **Eksekusi:** Entry Sell saat sinyal SELL muncul. Letakkan Stop Loss sedikit di atas kotak OB. Take profit di Swing Low terdekat.

---

## 🕹️ Panduan Penggunaan & Pengaturan (Settings)

Indikator ini sangat bisa dikustomisasi (Customizable). Buka menu Pengaturan (ikon gir):

*   **🏆 QUANTUM AI CORE:** Nyalakan sinyal Buy/Sell, atur pengganda Take Profit (TP Mult) dan Stop Loss (SL Mult).
*   **📊 DASHBOARD SETTINGS:** Atur posisi Dashboard (misal: Bottom Right) agar tidak menutupi *price action*.
*   **⚙️ VOLUMIZED ORDER BLOCKS:** Atur ketebalan riwayat Order Block, periode Swing, dan metrik Volume.
*   **🏗️ MTF STRUCTURE (BOS & MSS):** Nyalakan struktur dari Timeframe yang lebih tinggi (Sangat disarankan untuk dinyalakan 1 TF di atas TF Anda trading).
*   **Smart Money Concepts (LUX):** Anda bisa menyalakan/mematikan tampilan Internal Structure, Swing Structure, FVG, dan Equal Highs/Lows agar chart tidak terlalu penuh. Sesuaikan dengan kenyamanan mata Anda.

---

**Dikembangkan oleh Algoritma Khusus untuk Akurasi Maksimal.**
*Kuasai kesabarannya, AI akan menangani kompleksitasnya.*
