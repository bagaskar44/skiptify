# Skiptify 1.1 validation

Tanggal: 16 September 2026

## Build dan regresi

- Parser PowerShell: **Lulus**, tanpa kesalahan sintaks.
- Pester: **20/20 lulus** (regresi recovery, startup terlihat, lifecycle worker,
  handshake overlay, status `Stopped`, dan penanganan dialog Application Error).
- Build C# x64: **Lulus**; assembly `Skiptify.exe` versi `1.1.0.0`.
- UI referensi: **Lulus smoke visual**. Tema gelap-kehitaman dengan header ringkas berlogo saja, logo utama/watermark, toggle custom, tagline, dan kontrol jendela borderless dirender tanpa dependensi UI eksternal; teks status normal disembunyikan dan pesan error hanya muncul saat diperlukan. Skala konten dibatasi 100% dan dipusatkan saat maximize agar tidak membesar atau terpotong.
- Installer per pengguna: **Lulus** di direktori TEMP terpisah; hash executable
  hasil instalasi sama dengan build; uninstaller menghapus direktori uji.
- Instalasi utama diperbarui dengan installer yang sama; smoke startup UI lulus
  dan UI menutup bersih.

## Pengujian end-to-end yang dapat diulang

- Desktop single-instance: **Lulus**. Peluncuran kedua keluar; hanya satu UI.
- 100 siklus On/Off dengan Spotify simulator: **Lulus**. Maksimum satu worker,
  100 siklus selesai, worker tersisa 0, delta private memory UI setelah idle
  `+6,70 MB`.
- Recovery simulator dengan foreground yang valid: **5/5 handoff lulus**.
  Overlay tampil sebelum proses lama ditutup pada setiap siklus; PID berganti
  sekali; handoff awal tercatat sekitar 3,9–4,2 detik.
- Smoke setelah readiness gate: **1/1 lulus**. Overlay ditahan hingga tiga
  pemeriksaan stabil; handoff tercatat 4,883 detik.
- Logo executable: **Lulus**. PNG disematkan ke `Skiptify.exe`, ditampilkan
  sebagai logo header 64 px dengan sudut transparan, dan dipakai sebagai ikon
  jendela/taskbar; resource ikon Windows multiukuran juga disematkan agar
  shortcut desktop dan Start Menu menampilkan logo yang sama.
- Recovery simulator tanpa host overlay: **Lulus fallback**. Worker tetap
  menyelesaikan pemulihan dan mengirim Next/Play sesuai urutan.
- Jalur penghentian graceful: **Lulus** pada recovery simulator; `WM_CLOSE`
  bertimeout digunakan sebelum force-stop terbatas pada PID target.
- Dialog `Spotify.exe - Application Error`: **Lulus** pada dua tes regresi.
  Worker berhenti bounded dengan pesan jelas dan tidak melakukan retry otomatis.
- Simulasi worker mutex dan status `Stopped`: **Lulus** pada tes Pester dan
  smoke worker. Launcher VBS langsung pada desktop interaktif tidak dapat
  dipisahkan dari proses shell uji, sehingga skenario konflik VBS ditandai
  belum terverifikasi langsung.

## Pengukuran sumber daya

Kondisi diukur pada komputer yang sama setelah pemanasan; Spotify simulator dan
PowerShell penguji tidak dimasukkan ke agregat.

| Kondisi | Hasil | Target | Status |
|---|---:|---:|---|
| UI Off, 10 menit | CPU rata-rata 0,0662%; private memory maksimum 25,04 MB | CPU <0,1%; memory <=60 MB | Lulus |
| UI + worker On stabil, 10 menit | CPU rata-rata 0,412%; private memory maksimum 88,05 MB | CPU <1%; memory <=150 MB | Lulus |
| 100 siklus On/Off | private memory UI +6,70 MB; worker tersisa 0 | kenaikan <=10 MB; tanpa worker tertinggal | Lulus |
| 100 siklus overlay | belum selesai dengan foreground stabil | tanpa pertumbuhan memory/handle | Belum terverifikasi |

CPU On memiliki spike sampel sesaat 30,94%, tetapi rata-rata 10 menit tetap di
bawah target. Optimasi snapshot jendela native menghilangkan polling
`Get-Process` berulang dari loop worker. Handoff visual memakai minimum hold
1,5 detik, `UpdateWindow`/`DwmFlush`, dan tiga pemeriksaan jendela stabil; timer
ini hanya aktif selama recovery.

## Bukti dan hash

- Simulator uji (tidak dikemas dalam rilis): `test-artifacts/FakeSpotify.cs`.
- Bukti logo UI: `test-artifacts/logo-ui-dpi-aware.png` (capture DPI-aware).
- Bukti UI sederhana: `test-artifacts/main-ui-simple.png` (status normal,
  hint, dan subtitle dihilangkan).
- Bukti header compact: `test-artifacts/main-ui-compact-header.png`.
- Bukti tata letak ringkas: `test-artifacts/main-ui-tidy.png`.
- Bukti header diperkecil dan dipusatkan: `test-artifacts/main-ui-header-refined.png`.
- Bukti header tanpa judul: `test-artifacts/header-nologo-normal.png`.
- Bukti maximize/restore tanpa pembesaran atau sudut terpotong: `test-artifacts/maximize-fixed.png`, `test-artifacts/restore-fixed.png`.
- Bukti logo dan judul utama diperkecil: `test-artifacts/main-logo-title-smaller.png`.
- Bukti palet gelap-kehitaman: `test-artifacts/main-ui-darker.png`.
- Bukti ikon executable terpasang: `test-artifacts/installed-exe-icon.png`.
- Cadangan 1.0: `releases/Skiptify-1.0-snapshot-20260915-145137.zip`.
- Build UI: `dist/Skiptify.exe` - SHA-256
  `ECC274335A4E925E8A1BE6CC877BA14EE0160CD391DA8469DE47D33E05FB3C21`.
- Installer final: `dist/Skiptify-Setup-1.1.exe` - SHA-256
  `64ADD990A6C748C4790A568A949763831CD25F78D9BCE72F5FC693910AB01BE1`. Hash executable
  terpasang utama cocok dengan build.
- Bundel source dan artefak: `releases/Skiptify-1.1-release-final-20260915.zip`.
- Log runtime berada di `%LOCALAPPDATA%\Skiptify\Logs`.

## Belum terverifikasi di lingkungan ini

Rekaman layar lima recovery dengan Spotify nyata, playback/audio nyata,
scaling 100/125/150/200%, perpindahan monitor, lock/unlock, crash UI/worker,
launch Spotify yang tidak terpasang, timeout jendela tidak responsif, dan
upgrade/uninstall sambil recovery aktif memerlukan sesi Windows pengguna dengan
Spotify nyata. Simulator tidak menggantikan bukti tersebut. Satu run stress
overlay berhenti pada fallback karena harness kehilangan foreground; perilaku
fallback sesuai desain dan tidak meninggalkan worker, tetapi 100 siklus overlay
belum boleh disebut lulus.
