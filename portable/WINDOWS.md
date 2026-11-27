# Vektkove for Windows

Vektkove for Windows is a terminal compiler and bytecode runner. Choose the x64
installer for Intel or AMD PCs, or the arm64 installer for Windows on ARM. The
installer adds `vk` to your user PATH; open a new PowerShell or Command Prompt:

```powershell
vk --help
vk --version
```

Portable ZIP archives are also available. Extract the appropriate archive and run
`vk.exe` from the extracted directory:

```powershell
.\vk.exe --help
.\vk.exe --version
.\vk.exe run examples\hello.vk
.\vk.exe compile examples\hello.vk hello.vkb
.\vk.exe run hello.vkb
```

To run the portable `vk` from any directory, add the directory containing `vk.exe`
to your user PATH. The installer removes its own PATH entry when uninstalled.
The WinGet submission is under review; automated WinGet installer tests have not
yet passed. The setup executables are unsigned, so Windows may show a warning.

The Windows builds do not include the macOS editor, launcher, UI Maker, or graphical
rendering. UI instructions are validated but cannot display windows. VKLINK chat is
available through `vk chat listen ADDRESS PORT` and `vk chat connect ADDRESS PORT`.
Use only a trusted network and a strong shared passphrase.