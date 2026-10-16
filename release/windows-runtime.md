# Windows x64 engineering packages

Extract the complete portable ZIP into one folder, then open `loom.exe`.
Keep the DLLs and `data` directory beside the executable. The installer deploys
the same complete application folder.

The bundle includes the Microsoft C++ app-local release runtime selected by
the build toolchain. Runtime DLLs retain their original vendor attribution.
Packages are for 64-bit Windows; they are unsigned engineering builds.

Installation, media devices, incoming calls and background behavior still need
acceptance testing on a real Windows machine.
