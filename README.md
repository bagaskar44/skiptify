# Skiptify Desktop 1.1

Skiptify Desktop adalah UI Windows ringan dengan satu toggle On/Off. Tampilan utama memakai tema gelap-hijau dengan logo Skiptify, kontrol jendela sederhana, dan pesan error singkat hanya bila diperlukan. Mesin pemantauan tetap menggunakan `skiptify/skiptify.ps1`, sehingga perilaku deteksi dan pemulihan Spotify tetap sama dengan versi VBS/PS1. Saat Spotify berada di depan, Desktop dapat menampilkan satu snapshot sementara selama pemulihan agar pergantian aplikasi terlihat seperti jeda singkat.

## Build

Jalankan dari PowerShell 5.1 di folder proyek:

```powershell
.\build.ps1
```

Hasilnya ada di `dist\Skiptify.exe` bersama worker PowerShell dan launcher VBS. Kompilasi memakai C# compiler yang disertakan .NET Framework 4.8, tanpa dependensi NuGet atau runtime browser.

Logo `Skiptify Logo.png` disematkan ke dalam executable sebagai logo header, logo utama, watermark, dan ikon jendela/taskbar. `Skiptify.ico` menjadi resource ikon Windows multiukuran untuk executable dan shortcut. PNG/ICO tidak perlu disalin ke folder instalasi saat runtime. UI tidak memakai timer animasi atau dependensi UI eksternal; gambar dan font hanya digambar ulang saat status atau ukuran jendela berubah.

Untuk membuat installer:

```powershell
.\build.ps1 -Installer
```

Perintah tersebut memerlukan Inno Setup 6 (`ISCC.exe`) dan menghasilkan `dist\Skiptify-Setup-1.1.exe`. Installer dipasang per pengguna ke `%LOCALAPPDATA%\Programs\Skiptify`, membuat shortcut Start Menu, dan menawarkan shortcut desktop.

## Menjalankan

Buka `Skiptify.exe`, tekan **On**, dan biarkan aplikasi berjalan di taskbar. Tekan **Off** untuk menghentikan worker; Spotify tidak ditutup. Klik **X** menghentikan worker secara tertib lalu keluar.

UI memakai mutex `Local\Skiptify.Desktop.1.0`; worker memakai mutex `Local\Skiptify.Engine.1.0`. Karena itu hanya satu UI dan satu worker dapat berjalan untuk setiap sesi pengguna. Tombol **Start/Stop Skiptify.vbs** memakai event berhenti yang sama dengan UI.

Snapshot hanya disimpan di RAM, diambil sekali pada area Spotify yang terlihat, dan dibatasi 64 MiB. Capture dibatalkan jika Spotify tidak lagi berada di depan, posisi atau DPI berubah, pengguna berpindah aplikasi, atau persiapan melewati 500 ms. Selama proses Spotify lama ditutup, lapisan berada di atas secara sementara agar perpindahan fokus Windows tidak menampilkan desktop; setelah Play dikirim, frame dipertahankan minimal 1,5 detik dan sampai tiga pemeriksaan jendela stabil. Handoff meminta satu render dan flush compositor Windows, memakai aktivasi fokus Win32 sementara, dan dilepas bila pengguna berpindah aplikasi. Lapisan dilepas paling lambat 8 detik; Esc, Off, dan X selalu membersihkannya.

Saat recovery, worker meminta Spotify menutup secara graceful dengan `WM_CLOSE` dan batas waktu 1 detik. Force-stop hanya dipakai untuk PID Spotify yang masih hidup setelah masa tunggu tambahan. Jika Windows menampilkan dialog `Spotify.exe - Application Error`, worker menghentikan recovery dengan pesan singkat dan tidak mengulang launch otomatis; popup tetap ditangani pengguna.

Pada pembukaan pertama ketika Spotify belum memiliki jendela responsif, Desktop dan launcher VBS menggunakan mode startup normal, termasuk ketika proses Spotify masih berjalan di latar belakang. Jendela Spotify tersembunyi yang sudah ada ditampilkan kembali tanpa meluncurkan proses baru. Startup menunggu hingga 30 detik. Recovery tanpa overlay yang siap juga memakai argumen bawaan Spotify `--minimized` untuk menghindari jendela startup muncul sebelum polling meminimalkannya. Recovery meluncurkan Spotify dalam mode minimized agar jendelanya tetap dapat dideteksi; mode Hidden dapat meninggalkan proses tanpa jendela yang terdeteksi. Judul sementara `Spotify` diabaikan dan worker memberi waktu stabilisasi 4 detik agar startup tidak dianggap sebagai iklan atau memicu recovery kedua.

Log runtime disimpan di `%LOCALAPPDATA%\Skiptify\Logs\skiptify.log` dengan satu arsip rotasi maksimal 1 MB. Jika folder tersebut tidak dapat ditulis, worker menggunakan folder script sebagai fallback dan tetap melanjutkan pemantauan.

## Verifikasi

```powershell
Invoke-Pester -Script .\tests\skiptify.tests.ps1 -EnableExit
```

Pengujian mencakup 25 skenario worker, stabilitas jendela, peluncuran minimized, named event, startup terlihat, penanganan Application Error, dan mutex lifecycle. Pengukuran CPU/RAM serta uji restart Spotify langsung dan rekaman transisi visual tetap perlu dilakukan pada mesin pengguna sebelum distribusi luas.




