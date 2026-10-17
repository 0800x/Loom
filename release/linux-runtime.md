# Linux x64 runtime

Extract the complete archive and keep `loom`, `lib/` and `data/` together.
This is an application bundle built on Ubuntu 24.04, not a static executable.
Install GTK 3, libsecret, PulseAudio and mpv runtime libraries. On Ubuntu 24.04:

```sh
sudo apt-get install libgtk-3-0t64 libsecret-1-0 libmpv2 libpulse0
cd bundle
ldd loom
./loom
```

The bundle includes `linux-runtime-dependencies.txt` from its builder. Resolve
every `not found` entry on the target host before launching. Other distributions
need equivalent libraries and compatible glibc. ARM64 Linux messenger is not
advertised until native plugins and a supported runner pass a real build.
