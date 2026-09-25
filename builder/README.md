### BLUI CEF Chromium Build Script

Current CEF building instructions: https://github.com/getnamo/blubrowser

#### Isolating the CEF runtime (required, Windows)

The engine ships its own CEF (`Engine/Binaries/ThirdParty/CEF3`) for the WebBrowser module. Windows binds DLLs imported by bare name to whichever module of that name is already loaded, so two `libcef.dll`s in one process end up sharing one Chromium: the second `CefInitialize` silently becomes a no-op and one side runs with the other's settings, subprocess and version.

After copying a new CEF drop (`Release` + `Resources` files) and a freshly built `BluBrowserProcess.exe` into `ThirdParty/cef/Win/shipping` and `libcef.lib` into `ThirdParty/cef/Win/lib`, run:

```
powershell -ExecutionPolicy Bypass -File builder/isolate_cef.ps1
```

It renames `libcef.dll` -> `blucef.dll` and `chrome_elf.dll` -> `blucef_elf.dll` (same-length names, patched in the import/export tables and the runtime `GetModuleHandle` name tables), patches `BluBrowserProcess.exe` to import `blucef.dll` and generates `lib/blucef.lib`. The script checks the number of patched references and aborts if a new CEF version changes them, so review it when bumping CEF.

#### Archived - Windows Steps

Requirements:
```
Python 2.7 (latest)
Visual Studio 2015
CMake
Patch
Git
```

* Ensure that `git, python, msbuild, patch, cmake` are all added to your PATH and can be run from the command line.
* Copy `builder.py` to some other directory.
* Use command prompt to navigate to the builder.py location.
* Run `python builder.py` and provide the Visual Studio version (2015 is recommended)
* Wait. A very long time. Really.
* If no errors. Folder `blui` will contain all source and binary files needed for the `Plugins` folder.

> Other platforms for this script are still a WIP...