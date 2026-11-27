Read the [complete Vektkove manual](MANUAL.md) for editor, language, UI Maker, command-line, and VKLINK instructions. The editor and launcher follow the Mac's light or dark appearance. Use **A-** and **A+**, or the View menu, to adjust code and output text size. Select the **Manual** tab to search command names, filter by Code, Logic, Math, Text, or UI, sort command spellings A-Z or group them by category, and page through all results.
To rebuild, install Apple Command Line Tools and run `make` in this folder. Run `make test` for the interpreter, native UI, and command-line checks. The build contains both x86_64 and arm64 macOS slices. Tests run on the host architecture.
# Vektkove 1.2.0

Vektkove is a custom, deterministic programming language and native Mac editor. It does not use AI, JavaScript, Node.js, or an external runtime. `.vk` source is compiled to Vektkove's `VK01` bytecode and executed by its interpreter.

## Versioned Files

The repository's `platforms/<os>/<architecture>/<version>/` folders contain separate Windows, Linux, and macOS downloads for 1.0.0, 1.1.0, and 1.2.0. Full source bundles are under `source/<version>/`; the repository root contains the current source. Windows and Linux distributions provide the terminal runner only. The graphical editor, UI Maker, and both 3D renderers require macOS.

## Start

On an Intel or Apple Silicon Mac running macOS 11 or newer, open `Vektkove.app`. Use **Open Folder** to show your project's files in the left explorer; expand folders and select a text file to edit it. Use the file-plus and folder-plus icons to create items in the selected folder, and the refresh icon to pick up external changes. Hover over an icon to see its name. Existing files are not overwritten. The editor can save `.vk` programs, compile `.vkb` bytecode, and build native windows.

Select **Test Code** to open `VektkoveLauncher.app` and test the current editor contents, including unsaved edits. The launcher shows output, compile errors, and runtime errors, and opens windows made by the program. It can also be opened independently to choose and test a `.vk` file. Both apps are unsigned; macOS may require you to open them from Finder's context menu after reviewing them.

The editor and launcher follow the Mac's light or dark appearance. Use **A-** and **A+**, or the View menu, to adjust code and output text size. Select the **Manual** tab to search command names, filter by Code, Logic, Math, Text, or UI, sort commands A-Z or group them by category, and page through the results.

To rebuild, install Apple Command Line Tools and run `make` in this folder. Run `make test` for the interpreter, native UI, and command-line checks. The build contains both x86_64 and arm64 macOS slices. Tests run on the host architecture.

## Write And Run

Each instruction occupies a line. Names are case-insensitive; variables are case-sensitive. Use `$name` to read a variable, double quotes for text, and `#` for comments. Strings use JSON escapes such as `\n` and `\"`. Numeric values are finite decimal numbers. Commands that change a variable take its name without `$`.

```text
text greeting "Hello!"
out $greeting
set total 2
add total 3
out $total
halt
```

`./vk run examples/hello.vk` runs source in Terminal. `./vk compile examples/hello.vk hello.vkb` produces bytecode, and `./vk run hello.vkb` runs it. Use `./vk --help` for terminal commands. UI instructions require the native app; the command-line runner validates them but cannot display windows or 3D scenes. UI programs must start with `import ui` before their first UI instruction. The fixed `terminal_run` utilities support only `help`, `date`, and `pwd`; `terminal_echo` prints text without invoking a shell or launching external processes. `cite author title year url` formats a supplied author-date citation without looking up sources. `./vk keywords` lists command spellings.

Use the ordinary arithmetic instructions with a variable and numeric operand, for example `set total 1e300`, `add total 1e300`, or `divide total 2`. The runtime uses finite double-precision numbers, so operations that overflow to infinity report an error.

## Instructions

| Instruction | Operands | Effect |
| --- | --- | --- |
| `text`, `set` | name value | Set a text or numeric variable; `text` converts its value to text. |
| `add`, `subtract`, `multiply`, `divide`, `modulo`, `power` | name value | Update a numeric variable. |
| `concat` | name value | Append text to a variable. |
| `upper`, `lower`, `length` | name | Change text case or replace it with its UTF-16 length. |
| `equal`, `not_equal`, `less`, `less_equal`, `greater`, `greater_equal` | name value | Replace the variable with `1` or `0`. Ordering requires numbers. |
| `and`, `or` | name value | Numeric boolean operations. |
| `not`, `negate`, `abs`, `round`, `floor`, `ceil`, `sqrt` | name | Update a numeric variable. |
| `out` | value | Write a line to the output. |
| `label`, `jump` | name | Mark a location or jump to it. |
| `if`, `unless` | value label | Jump when the value is true or false. Zero and empty text are false. |
| `halt` | none | Stop the program. |
| `import ui` | module | Enable UI instructions; place it before `window` and all UI controls. |
| `window` | title width height | Create a window; this must precede UI controls. |
| `ui_label`, `ui_input` | text x y width height | Add a label or text input. Coordinates start at the top left. |
| `ui_button` | text x y width height message | Add a button that displays the message when clicked. `{input}` inserts the first input's current text; `{placeholder}` inserts the text from the input with that placeholder. |
| `ui_id` | id | Name the preceding label, input, or button for later bindings. IDs must be unique. |
| `ui_bind` | id variable | Bind an input or label to a previously defined text variable. Inputs update the variable and all labels or inputs bound to it. |
| `ui_scene3d` | x y width height | Add an interactive native 3D viewport. |
| `ui_camera3d` | x y z | Position the scene camera, looking toward the origin. |
| `ui_light3d` | x y z intensity | Add a white point light. |
| `ui_box3d`, `ui_sphere3d`, `ui_cylinder3d`, `ui_cone3d`, `ui_torus3d`, `ui_plane3d` | position, dimensions, color | Add a colored 3D primitive; see `examples/scene3d.vk` and `MANUAL.md` for operands. |
| `ui_spin3d` | id seconds | Continuously rotate a named primitive around its Y axis. |
| `cite` | author title year url | Format a supplied citation as `Author. (Year). Title. URL`. |
| `ui_color` | "#RRGGBB" | Set the background color of subsequent labels, inputs, and buttons. Put the color in quotes. |
| `min`, `max` | name value | Store the smaller or larger number. |
| `sin`, `cos`, `tan`, `asin`, `acos`, `atan` | name | Calculate trigonometric functions in radians. |
| `log`, `log10`, `exp`, `sign`, `truncate` | name | Calculate a logarithm, exponential, sign, or integer part. |
| `is_number`, `is_text`, `empty` | name | Replace the variable with a type or emptiness check. |
| `trim`, `contains`, `starts_with`, `ends_with`, `replace` | name and values | Trim, inspect, or replace text. See the Manual tab for operands. |

The interpreter limits programs to 100,000 instructions, output to 100,000 characters, and UI to 200 elements. Division by zero, invalid operations, and missing variables or labels report errors.

## Encoding and Compression

Use `vk formats` to list the supported codecs. `vk encode base64 input.txt output.txt` and `vk decode base64 input.txt output.txt` transform files; omit the paths or use `-` for standard input or output. For example, `vk encode zstd+base64 input.txt output.txt` and `vk decode base64+zstd output.txt restored.txt` reverse each other. In `.vk` programs, `encode name "base64"` and `decode name "base64"` update an existing text variable. See the manual for formats and limits.

## Platforms

| Platform | What is provided | Status |
| --- | --- | --- |
| macOS Intel (x86_64) and Apple Silicon (arm64) | Editor, launcher, UI Maker, manual, `vk` command line | Universal binaries. Tested on an Intel Mac; the arm64 slice builds but was not run. |
| Linux x64, Linux aarch64, Windows x64, Windows ARM64 | `vk` / `vk.exe` command-line compiler and runner only | Cross-compiled with Zig; see the release workflow for Windows smoke-test results. |

The Linux and Windows programs are built from `portable/vkport.c`, a separate C implementation of the compiler and runner. It supports the single ordinary Add command and does not include the graphical editor, launcher, or UI Maker, which use macOS-only AppKit. UI instructions are checked but cannot display windows there. Use `vk --help`, `vk run program.vk`, `vk compile program.vk out.vkb`, or `vk keyword-count`. Windows installation and terminal usage are described in [portable/WINDOWS.md](portable/WINDOWS.md).

## VKLINK Chat

Run `./vkport chat listen 0.0.0.0 54321` on a Mac, or `vk chat listen 0.0.0.0 54321` on Linux or Windows, on the computer accepting a connection. On the other computer run `./vkport chat connect HOST 54321` on Mac or `vk chat connect HOST 54321` on Linux or Windows. Replace `HOST` with the listener's reachable IP address or hostname. Both peers must enter the same strong, independently shared passphrase when prompted. Each listener accepts one peer. VKLINK/2 uses libsodium Argon2id and authenticated XChaCha20-Poly1305 secret streams for UTF-8 messages up to 16,384 bytes. Received messages are never executed as code. VKLINK/2 is incompatible with the earlier plaintext VKLINK/1.

Use a unique, high-entropy passphrase shared securely beforehand: a weak passphrase can be guessed offline. This protocol authenticates possession of that shared passphrase, not individual identities; it does not provide forward secrecy, and addresses and connection metadata remain visible. It has not had an independent security audit. Bind only to a trusted network and avoid exposing the listener to the public internet. Firewalls may need to allow the chosen port.

To compare the portable runner with the macOS engine, `portable/difftest.sh` and `portable/fuzz.py` run the same programs through both and compare the compiled bytecode, output, exit status, and first error line. `make test` also exercises a local VKLINK chat session. Cross-build Linux and Windows targets with `ZIG=/path/to/zig portable/build-portable.sh`; build Windows release ZIPs with `ZIG=/path/to/zig bash portable/package-windows.sh`. Outputs are written to `dist/`.

## UI Maker

Open **UI Maker** in the app. Choose one of 20 starter layouts or add labels, input fields, and buttons. Drag an object to move it, or drag its bottom-right corner to resize it. The canvas grid snaps positions and sizes by default; change its spacing or turn snapping off. Duplicate the selected control, edit its ID and binding variable in the table, and set its color with the color well. **Draw** immediately applies generated source to the editor and opens a live line-numbered view. **Apply Code** remains available from the maker toolbar. Import startup sounds and preview the design. UI source begins with `import ui`. Buttons display messages and can insert input text using `{input}` or an input's placeholder in braces. See [MANUAL.md](MANUAL.md) for the complete instructions.

For native 3D scenes, see `examples/scene3d.vk`. Select Basic for Vektkove's original rasterizer or Regular for the Mini3D-based rasterizer by Linwei (MIT license). Both support camera orbit, Shift-drag pan, scroll zoom, point lights, primitive meshes, and continuous object rotation. See [third_party/mini3d/LICENSE](third_party/mini3d/LICENSE).