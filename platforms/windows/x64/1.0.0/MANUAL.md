# Vektkove 1.0.0 Manual

Vektkove is a custom programming language and native macOS editor. Source files use `.vk`; compiled programs use `.vkb`. The native interpreter is written in Objective-C and does not require JavaScript, Node.js, an account, or an internet connection.

## Contents

- [Install and launch](#install-and-launch)
- [Editor and project files](#editor-and-project-files)
- [Language basics](#language-basics)
- [Instruction reference](#instruction-reference)
- [Native user interfaces](#native-user-interfaces)
- [3D rendering](#3d-rendering)
- [2D Games](#2d-games)
- [Script Roles and TCP](#script-roles-and-tcp)
- [UI Maker](#ui-maker)
- [Command-line tools](#command-line-tools)
- [Limits and errors](#limits-and-errors)
- [VKLINK chat](#vklink-chat)
- [Platforms and building](#platforms-and-building)

## Install and Launch

Vektkove.app and VektkoveLauncher.app run on macOS 11 or later on Intel and Apple Silicon. Open `Vektkove.app` to edit programs. The apps are unsigned; macOS may require opening them from Finder's context menu after you have reviewed them.

In the editor, choose **Open Folder** to show a project in the explorer. Select a file to edit it. Use the file-plus and folder-plus controls to create files and folders in the selected directory; existing items are not overwritten. Use **Refresh** to pick up filesystem changes. **Save** writes the source, **Compile** writes `.vkb` bytecode, and **Test Code** runs the current editor contents, including unsaved edits, in the launcher.

The editor and launcher follow the system light or dark appearance. **A-** and **A+**, or the View menu, change code and output text size. The **Manual** tab searches instruction spellings, filters by Code, Logic, Math, Text, or UI, sorts alphabetically or by category, and pages through the command list.

## Editor and Project Files

The editor accepts UTF-8 `.vk` source. The launcher can open a source file independently and displays compile errors, runtime errors, and program output. UI instructions open native windows when run in either app. The command-line runner can validate UI instructions but cannot display their windows.

Use the explorer's **Open Folder** control to choose a project root. Expand folders to navigate, select a text file to edit it, and use **Refresh** after external changes. Save files before building or sharing them. A compiled `.vkb` contains bytecode, not editable source.

## Language Basics

Each instruction occupies one line. Blank lines are ignored. A `#` starts a comment outside a quoted string; it may follow an instruction. Instruction names are case-insensitive. Variable and label names are case-sensitive.

Double quotes delimit text. Strings use JSON escapes, including `\n`, `\t`, `\\`, and `\"`. Put spaces inside quotes when they belong to an operand. Bare operands that are not variables or finite numbers are treated as text. A variable read uses `$name`; a command that changes a variable takes `name` without `$`.

`text name value` creates or replaces a variable with the text form of a value. `set name value` creates or replaces it while preserving its type. Other variable-changing instructions require an existing variable. Text and numeric values are distinct; a text value that looks like a number remains text.

```text
# A short complete program
text greeting "Hello, Vektkove!"
out $greeting
set total 2
add total 3
out $total
halt
```

Numbers are finite double-precision values. Numeric booleans use `1` for true and `0` for false. In a branch, zero and empty text are false; nonzero numbers and nonempty text are true. Numeric comparisons require numbers. Equality and inequality compare values directly.

Labels are destinations, not variables. Define a label with `label name`; branch with `jump name`, `if value name`, or `unless value name`. Labels may be declared before or after their use. A jump to a missing label is an error. Loops are allowed but are subject to the execution limit.

## Instruction Reference

The spellings in the first column are the canonical instructions. Other listed names are aliases. Except for `add` and `import`, every canonical name and alias also accepts the `vk_`, `do_`, and `op_` prefix. For example, `subtract`, `sub`, `vk_subtract`, and `do_sub` are equivalent. `add` is exactly `add`; `import` is also unprefixed. Numbered arithmetic shortcuts are not valid. The app manual and `vk keywords` list every accepted spelling.

### Code and Variables

| Instruction | Operands | Behavior | Aliases |
| --- | --- | --- | --- |
| `text` | name value | Store the value's text form. | `string_text`, `declare_text` |
| `set` | name value | Store a value, preserving number or text type. | `assign`, `store` |
| `out` | value | Append the value and a newline to program output. | `print`, `output` |
| `halt` | none | Stop the program. | `stop`, `end` |
| `label` | label | Mark a branch destination. | `mark`, `anchor` |
| `jump` | label | Jump unconditionally. | `goto`, `branch` |
| `if` | value label | Jump if the value is true. | `when`, `branch_if` |
| `unless` | value label | Jump if the value is false. | `when_not`, `branch_unless` |
| `import ui` | module | Enable UI instructions. Put it before every UI instruction. | No aliases |
| `terminal_run` | keyword | Run only the built-in `help`, `date`, or `pwd` utility. It does not launch a shell. | `run_terminal`, `terminal_command` |
| `terminal_echo` | value | Write a value and newline to program output. | `echo_terminal` |
| `terminal_keywords` | none | List terminal utility instructions and supported keywords. | `terminal_help` |
| `cite` | author title year url | Format and print `Author. (Year). Title. URL`. | `citation`, `reference`, `source_cite` |

Terminal utilities are interpreter built-ins, not shell execution. `terminal_run "date"` prints the UTC date in `YYYY-MM-DD` form; `terminal_run "pwd"` prints the process working directory; `terminal_run "help"` prints the allowlist. Use `terminal_echo value` for text. Unsupported `terminal_run` keywords return an error.

`cite` formats only the values supplied in the instruction; it does not search for or verify the source. The author, title, and URL must be nonempty text; the year may be text or a number.

### Arithmetic and Math

All arithmetic instructions update the named numeric variable. The right operand may be a number or `$variable` containing a number.

| Instruction | Operands | Behavior | Aliases |
| --- | --- | --- | --- |
| `add` | name value | Add. | None |
| `subtract` | name value | Subtract. | `sub`, `minus` |
| `multiply` | name value | Multiply. | `mul`, `times` |
| `divide` | name value | Divide; zero is an error. | `div`, `quotient` |
| `modulo` | name value | Store the floating-point remainder; zero divisor is an error. | `mod`, `remainder` |
| `power` | name value | Raise the variable to the given power. | `pow`, `exponent` |
| `min` | name value | Store the smaller number. | `minimum`, `smaller` |
| `max` | name value | Store the larger number. | `maximum`, `larger` |
| `negate` | name | Change the sign. | `negative`, `negate_number` |
| `abs` | name | Store the absolute value. | `absolute`, `magnitude` |
| `round` | name | Round to the nearest integer; halfway values round away from zero. | `nearest`, `round_number` |
| `floor` | name | Round down. | `round_down`, `downward` |
| `ceil` | name | Round up. | `round_up`, `ceiling` |
| `truncate` | name | Remove the fractional part toward zero. | `trunc`, `integer_part` |
| `sqrt` | name | Store the square root. | `square_root`, `root` |
| `sin`, `cos`, `tan` | name | Trigonometric function; input is in radians. | `sine`, `cosine`, `tangent` and their `_radians` forms |
| `asin`, `acos`, `atan` | name | Inverse trigonometric function; result is in radians. | `arcsine`, `arccosine`, `arctangent`, `inverse_sine`, `inverse_cosine`, `inverse_tangent` |
| `log` | name | Natural logarithm. | `natural_log`, `ln` |
| `log10` | name | Base-10 logarithm. | `common_log`, `decimal_log` |
| `exp` | name | Store e raised to the variable. | `exponential`, `e_power` |
| `sign` | name | Store `-1`, `0`, or `1`. | `signum`, `number_sign` |

### Logic and Comparison

Comparison and logical instructions replace the named variable with numeric `1` or `0`. Ordering comparisons require numeric values. `equal` and `not_equal` work with either value type.

| Instruction | Operands | Behavior | Aliases |
| --- | --- | --- | --- |
| `equal` | name value | True when values are equal. | `equals`, `eq` |
| `not_equal` | name value | True when values differ. | `differs`, `neq` |
| `less`, `less_equal` | name value | Test `<` or `<=`. | `below`, `lt`; `at_most`, `lte` |
| `greater`, `greater_equal` | name value | Test `>` or `>=`. | `above`, `gt`; `at_least`, `gte` |
| `and`, `or` | name value | Numeric logical AND or OR. | `both`, `logical_and`; `either`, `logical_or` |
| `not` | name | Invert numeric truth. | `invert`, `negate_boolean` |

### Text

Text operations use the value's textual representation where appropriate. `length` counts UTF-16 code units, not grapheme clusters.

| Instruction | Operands | Behavior | Aliases |
| --- | --- | --- | --- |
| `concat` | name value | Append the value's text to the variable. | `append`, `join` |
| `upper`, `lower` | name | Change text case. | `uppercase`, `capitalize`; `lowercase`, `decapitalize` |
| `length` | name | Replace the variable with its UTF-16 text length. | `len`, `size` |
| `is_number`, `is_text` | name | Replace the variable with a type check (`1` or `0`). | `numeric`, `is_numeric`; `textual`, `is_string` |
| `empty` | name | Test whether the value's text form is empty. | `is_empty`, `text_empty` |
| `trim` | name | Remove leading and trailing whitespace and newlines. | `strip`, `trim_whitespace` |
| `contains` | name value | Test whether the text contains the value's text. | `includes`, `text_contains` |
| `starts_with`, `ends_with` | name value | Test a text prefix or suffix. | `begins_with`, `has_prefix`; `finishes_with`, `has_suffix` |
| `replace` | name search replacement | Replace every occurrence of nonempty search text. | `replace_all`, `text_replace` |

### UI and Audio

The program must execute `import ui` before its `window` instruction or any other UI instruction. The `window` instruction must then appear before every UI control or action. UI coordinates start at the upper-left corner. UI positions and sizes are numbers from 0 to 10,000; widths and heights must be positive. See [Native User Interfaces](#native-user-interfaces) for examples and behavior.

| Instruction | Operands | Behavior | Aliases |
| --- | --- | --- | --- |
| `window` | title width height | Create the one program window. | `ui_window`, `make_window` |
| `ui_label` | text x y width height | Add a label. | `ui_text`, `make_label` |
| `ui_input` | placeholder x y width height | Add a text input. | `ui_field`, `make_input` |
| `ui_button` | text x y width height message | Add a button that presents a message. | `ui_action`, `make_button` |
| `ui_color` | `"#RRGGBB"` | Set the background color of following labels, inputs, and buttons. | `ui_colour`, `set_ui_color` |
| `ui_id` | id | Name the immediately preceding label, input, button, or 3D mesh. IDs must be unique. | Prefix variants only |
| `ui_bind` | id variable | Bind a named label or input to a previously defined variable. | Prefix variants only |
| `ui_scene3d` | x y width height | Add one interactive 3D viewport to the window. | `scene3d`, `make_scene3d` |
| `ui_camera3d` | x y z | Position the camera looking toward the origin. | `camera3d`, `scene_camera` |
| `ui_light3d` | x y z intensity | Add a white point light. | `light3d`, `scene_light` |
| `ui_box3d` | x y z width height depth color | Add a colored box. | `box3d`, `cube3d`, `ui_cube` |
| `ui_sphere3d` | x y z radius color | Add a colored sphere. | `sphere3d`, `ui_sphere` |
| `ui_cylinder3d` | x y z radius height color | Add a colored cylinder. | `cylinder3d`, `ui_cylinder` |
| `ui_cone3d` | x y z top_radius bottom_radius height color | Add a colored cone. | `cone3d`, `ui_cone` |
| `ui_torus3d` | x y z ring_radius pipe_radius color | Add a colored torus. | `torus3d`, `ui_torus` |
| `ui_plane3d` | x y z width height color | Add a colored plane. | `plane3d`, `ui_plane` |
| `ui_mesh3d` | path x y z scale color | Import a local 3D model supported by macOS Model I/O. | Prefix variants only |
| `ui_spin3d` | id seconds | Continuously rotate a named primitive around its Y axis. | `spin3d`, `spin_object` |
| `ui_physics3d` | id mass restitution | Enable a 3D body; mass 0 is static and restitution is 0 to 1. | `physics3d`, `game_physics3d` |
| `ui_gravity3d` | x y z | Set gravity for dynamic 3D bodies. | `gravity3d`, `game_gravity3d` |
| `ui_velocity3d` | id vx vy vz | Enable a body and set its initial velocity. | `velocity3d`, `game_velocity3d` |
| `ui_frame3d`, `ui_end_frame3d` | none | Begin and end a per-frame 3D callback. | `frame3d`, `end_frame3d` |
| `ui_move3d` | id dx dy dz | Move a 3D object in a frame callback. | `move3d`, `game_move3d` |
| `ui_force3d` | id fx fy fz | Apply force to a dynamic body in a frame callback. | `force3d`, `game_force3d` |
| `ui_set_velocity3d` | id vx vy vz | Set a body's velocity in a frame callback. | `set_velocity3d`, `game_set_velocity3d` |
| `ui_scene2d` | x y width height | Add one interactive 2D game scene. | `scene2d`, `game2d` |
| `ui_rect2d` | id x y width height color | Add a moving rectangle to the 2D scene. | `rect2d`, `game_rect` |
| `ui_circle2d` | id x y diameter color | Add a moving circle to the 2D scene. | `circle2d`, `game_circle` |
| `ui_velocity2d` | id dx dy | Move an object in scene units per second; it bounces at the scene edges. | `velocity2d`, `game_velocity` |
| `ui_keymove2d` | id key dx dy | Move an object by dx and dy when the key is pressed. | `keymove2d`, `game_keymove` |
| `ui_physics2d` | id mass restitution | Configure a 2D body; mass 0 is static and restitution is 0 to 1. | `physics2d`, `game_physics` |
| `ui_gravity2d` | x y | Set the 2D scene gravity vector. | `gravity2d`, `game_gravity` |
| `ui_frame2d` | none | Begin one per-frame callback block. | `frame2d`, `game_update` |
| `ui_end_frame2d` | none | End the frame callback block. | `end_frame2d`, `game_end_update` |
| `ui_move2d` | id dx dy | Move an object from a frame callback. | `move2d`, `game_move` |
| `ui_force2d` | id fx fy | Apply force to a dynamic object from a frame callback. | `force2d`, `game_force` |
| `ui_set_velocity2d` | id vx vy | Set object velocity from a frame callback. | `set_velocity2d`, `game_set_velocity` |
| `server_script` | none | Mark this file as the server entry point; must be first. | `serverscript` |
| `local_script` | none | Mark this file as the local/client entry point; must be first. | `localscript` |
| `net_listen` | address port | Bind an explicit address and accept one TCP client. Server scripts only. | `network_listen` |
| `net_connect` | address port | Connect to the explicitly supplied TCP address. Local scripts only. | `connect_ip`, `network_connect` |
| `net_send` | value | Send one UTF-8 message, up to 16 KiB, on the open connection. | `network_send` |
| `net_receive` | variable | Receive one UTF-8 message into a variable. | `network_receive` |
| `net_close` | none | Close the current network connection. | `network_close` |
| `net_listen_multi` | address port clients | Accept 2 to 16 TCP clients. Server scripts only. | `network_listen_multi` |
| `net_send_to` | client_id value | Send a message to one accepted client. | `network_send_to` |
| `net_receive_from` | client_variable message_variable | Receive from any client and store its 1-based ID and message. | `network_receive_from` |
| `net_broadcast` | value | Send a message to every accepted client. | `network_broadcast` |
| `ui_shortcut` | key message | Show a message when the key is pressed in the program window. | `shortcut`, `ui_key` |
| `ui_note` | instrument note seconds | Play one piano or guitar MIDI note when the window opens. | `play_note`, `note` |
| `ui_keynote` | key instrument note seconds | Play a piano or guitar MIDI note when the key is pressed. | `key_note`, `instrument_key` |
| `ui_sound` | path | Play a local audio file when the window opens. | `play_sound`, `sound_file` |
| `ui_keyboard` | instrument base_note | Bind the on-screen keyboard mapping to a focused window. | `instrument_keyboard`, `keyboard` |
| `ui_auto_turn` | seconds | Continuously rotate the preceding label, button, or input. | `auto_turn`, `ui_rotate` |

## Native User Interfaces

This program creates a window, adds controls, then stops:

```text
import ui
window "Greeting" 420 220
ui_color "#CDEBDD"
ui_label "What is your name?" 20 20 260 32
ui_input "Your name" 20 64 260 32
ui_button "Say hello" 20 112 140 36 "Hello, {input}!"
halt
```

Buttons show their message in an alert. `{input}` inserts the current text from the first input in the window. `{Placeholder}` inserts the value of an input with that exact placeholder; use braces around the placeholder text. Buttons do not execute arbitrary Vektkove instructions or update program variables after the window opens.

`ui_color` accepts a quoted six-digit hex color and affects following controls only. It does not recolor controls already created. Text contrast is selected from the control background color.

Use `ui_id "identifier"` immediately after a label, input, button, or 3D mesh to name it. Then use `ui_bind "identifier" variable` to connect a label or input to a variable declared with `text` or `set`. An input updates its variable as the user types; every bound label and input reflects the same value. Binding a label displays the variable's current value. IDs are unique, and bindings must refer to an existing ID and variable.

```text
text username "Guest"
import ui
window "Profile" 400 180
ui_input "Your name" 20 20 180 32
ui_id "name_input"
ui_bind "name_input" username
ui_label "Guest" 20 72 240 32
ui_id "name_label"
ui_bind "name_label" username
halt
```

`ui_shortcut` keys are matched without regard to case while the window is focused. Standard names include `f1` through `f12`, `home`, `end`, `pageup`, `pagedown`, `insert`, `delete`, `backspace`, `enter`, `escape`, `tab`, `space`, and arrow names; ordinary character keys are also accepted. A shortcut message is shown in an alert.

`ui_keyboard "piano" base_note` or `ui_keyboard "guitar" base_note` maps the keys `a w s e d f t g y h u j k o l p ;` to 18 consecutive MIDI notes, starting at `base_note`. The base note must be an integer from 0 through 111. `ui_note` and `ui_keynote` support piano or guitar, MIDI notes 0 through 127, and durations from 0.05 through 10 seconds. Audio uses the system General MIDI sound bank. `ui_sound` takes a local path and plays it on window startup; paths in saved programs are relative to the source file's folder when not absolute.

`ui_auto_turn seconds` animates the immediately preceding label, button, or input continuously. The duration must be from 0.1 through 3,600 seconds. A color, shortcut, note, sound, keyboard, window, or another auto-turn instruction does not qualify as the preceding control.

## 3D Rendering

Vektkove includes its own CPU 3D renderer inside a native, resizable viewport; it does not use a third-party rendering engine. A program can create one 3D viewport per window. Coordinates are centered on the scene origin and use Vektkove world units; viewport coordinates and size use window points. Add `import ui` before any UI instruction and `window` before the scene.

```text
import ui
window "Orbit Demo" 760 560
ui_scene3d 20 20 720 500
ui_camera3d 0 0 12
ui_light3d 4 7 9 1000
ui_box3d 0 0 0 2 2 2 "#F15B40"
ui_id "hero"
ui_spin3d "hero" 5
ui_sphere3d 3 0 0 1 "#38A6D8"
ui_cylinder3d -3 0 0 0.8 2 "#54B87A"
halt
```

The software pipeline transforms and perspective-projects triangles, rasterizes them with a depth buffer, and shades them with ambient, distance-attenuated point, and specular lighting. Sphere and torus meshes use higher tessellation for smoother silhouettes. Rendering is Retina-aware and caps each frame's color and depth buffers together at 2,000 MiB; actual use scales with viewport size. Each rendered dimension is capped at 16,384 pixels. Scene instructions are also subject to the 200 UI element limit. This per-frame buffer ceiling does not limit mesh storage, system graphics allocations, multiple viewports, or total app memory. The viewport supports interactive camera orbit, pan (hold Shift while dragging), and scroll zoom. If no camera is specified, a camera at `(0, 0, 12)` is used. A custom camera may be positioned once per scene and looks at the origin. One automatic fill light is present; add point lights with a nonnegative intensity from 0 through 10,000 for more control.

The available meshes are box, sphere, cylinder, cone, torus, and plane. Give each a position, positive dimensions/radii, and a quoted `#RRGGBB` material color. Coordinates range from -10,000 through 10,000. A `ui_id` immediately after a mesh assigns its unique ID; `ui_spin3d` uses that ID and a rotation period from 0.1 through 3,600 seconds. 3D scenes and meshes count toward the 200 UI element limit.

**Import 3D Model** in UI Maker loads local model geometry through macOS Model I/O. OBJ and STL imports are tested; the formats available can vary by macOS version. Models are limited to 32 MiB per source file and 100,000 triangles, centered and scaled to fit two world units before the selected scale is applied. Imported meshes use the chosen solid color; textures, materials, animation, and skeletons are not rendered. The generated `ui_mesh3d` instruction retains the original file path, so that file must remain available when the program is run. Relative paths in authored source are resolved against the source file's directory.

FBX, glTF/GLB, STEP, YDR, DFF, TXD, and YTD are not supported on the tested macOS installation. TXD and YTD are texture archives rather than standalone geometry. To use an unsupported model, convert its geometry to OBJ or STL in a compatible external tool first. Check local importer availability with `Vektkove.app/Contents/MacOS/Vektkove --model-formats`.

`ui_physics3d` and `ui_velocity3d` enable collision and motion for named objects. The physics solver uses bounding spheres for every primitive, so contacts are approximate, especially for planes and long shapes. `ui_gravity3d` applies acceleration to enabled dynamic bodies. A `ui_frame3d` block supports the same bounded variable, arithmetic, and branch instructions and frame variables as the 2D callback, plus 3D move, force, and velocity actions. Frame actions must match the scene dimension.

The 2D game scene supports bounded rectangles and circles, per-frame velocity, edge bouncing, and keyboard movement. The UI Maker's **2D Game** starter generates a working WASD-controlled scene; edit its object IDs, positions, colors, velocity, and key deltas in the table or generated source. For example, see `examples/game2d.vk`.

## 2D Games

Use `ui_scene2d x y width height` once after creating the window. Add rectangles with `ui_rect2d id x y width height "#RRGGBB"` and circles with `ui_circle2d id x y diameter "#RRGGBB"`. Bodies collide using axis-aligned rectangle/circle tests and impulse response. `ui_physics2d id mass restitution` sets mass (0 makes a static body) and bounce from 0 to 1; `ui_gravity2d x y` applies scene gravity. `ui_velocity2d id dx dy` sets initial velocity, and `ui_keymove2d id key dx dy` moves an object by a fixed amount on key press.

One `ui_frame2d` / `ui_end_frame2d` block may contain variable updates, math, labels, branches, and `ui_move2d`, `ui_force2d`, or `ui_set_velocity2d` actions. It runs once per simulation tick with a 1,000-instruction budget. Each tick sets `delta_time`, `collision`, and `collision_count`; `collision_a` and `collision_b` contain the first colliding pair's IDs, or empty text if none. The UI Maker's **2D Game** starter uses this callback to count contacts and apply force to its orb. See `examples/game2d.vk`.

## Script Roles and TCP

Start a server file with `server_script` or a client file with `local_script`; the role marker must be the first instruction. Server scripts cannot create UI. Use `net_listen "127.0.0.1" port` to wait for one local peer, or `net_listen "0.0.0.0" port` only when you intend to listen on all network interfaces. Local scripts use `net_connect "address" port`. `net_send value` and `net_receive variable` exchange length-prefixed UTF-8 messages up to 16 KiB; `net_close` closes the connection. Send and receive operations have a 60-second timeout.

This is a blocking TCP transport, not an encrypted or authenticated multiplayer service. `net_listen_multi` accepts 2 to 16 peers; `net_receive_from` waits for a message from any accepted peer and stores its 1-based client ID and text in the named variables. Use `net_send_to` for a targeted response and `net_broadcast` to send to every peer. Do not send secrets or expose a listener to an untrusted network. For a single-peer local test, run `vk run examples/server.vk` in one terminal and `vk run examples/client.vk` in another. For two peers, run `vk run examples/multi_server.vk` and two copies of `vk run examples/multi_client.vk`. Network operations block while connecting, accepting, or waiting for a message.

The native app renders scenes. `vk` and the portable runner validate and compile 2D and 3D source but do not display graphics. See `examples/scene3d.vk` and `examples/game2d.vk` for complete programs.

## UI Maker

Choose **UI Maker** in the editor. Use **3D Scene** to start with all six primitives, add them individually from **Add 3D shape**, or use **Import 3D Model** for supported local geometry. The design canvas is a 2D layout of 3D object positions; **Preview** opens the rendered scene. Set camera and gravity using the fields above the canvas. The table contains Z, depth, optional mass, bounce, velocity (VX/VY/VZ), and spin period fields; leave mass blank for a decorative shape without collisions. X/Y and width/height are canvas points converted to world units (40 points per unit), Z is in world units, and depth is in canvas points. Imported models scale uniformly using the width field; their height and depth fields do not affect the mesh. Use the color well for object colors.

The **2D Game** starter and ordinary form layouts remain available. Add labels, inputs, or buttons; select a control to edit its text, ID, binding variable, position, size, message, and background color in the table or with the color well. Drag a control to move it. Drag its lower-right handle to resize it. **Remove** deletes the selected control; **Duplicate** makes a copy offset by one grid step and assigns it a new ID. **Import Sound** adds local audio files to the generated program; **Clear Sounds** removes those startup sounds.

The canvas displays a grid and snaps control positions and sizes to it by default. Change the spacing with the stepper (4 to 40 points), or turn off **Snap to grid** for free placement. The grid remains visible when snapping is off. Coordinates and sizes are measured in the window's points.

Choose **Draw** to apply generated `.vk` source to the editor and open its live numbered view. The view reports the current caret line and updates as the design changes. **Preview** validates and opens the current design without replacing the editor. Generated source includes `import ui`, any bound variables, the window, imported sounds, colors, controls, IDs, bindings, and a final `halt`. Starter buttons display placeholder alert messages until you edit or connect their behavior in Vektkove source.

## Command-Line Tools

From this folder, run a source file, compile source, run bytecode, or list accepted instruction spellings:

```sh
./vk run examples/hello.vk
./vk compile examples/hello.vk hello.vkb
./vk run hello.vkb
./vk keywords
```

`vk run` prints program output to standard output and reports errors to standard error. UI instructions are validated and run, but the command-line program reports that UI requires the native app. The `.vkb` format begins with the `VK01` signature. Run `./vk keywords | wc -l` to count spellings for the current build.

The `vkport` portable runner supports a separate, reduced language implementation with the ordinary `add` instruction. It does not provide the native editor, manual, or graphical UI. It is not a drop-in replacement for the complete macOS engine.

## Limits and Errors

The interpreter stops after 100,000 executed instructions, limits output to 100,000 characters, and limits a UI program to 200 UI records, including its window. A UI program can therefore contain at most 199 other controls and actions combined. Programs report errors for malformed or truncated bytecode, invalid operands, undefined variables or labels, invalid variable names, division by zero, non-finite numeric results, invalid UI values, and exceeded limits.

Use the **Manual** tab for command help. The engine's `diagnose` facility also reports unknown instructions, wrong operand counts, duplicate or unused labels, undefined variables, some UI ordering mistakes, and unreachable code. Diagnostics are advisory for some runtime-dependent conditions; **Test Code** remains the final check for a program.

## VKLINK Chat

The portable runner also includes a one-peer encrypted terminal chat. On the listening computer, run:

```sh
./vkport chat listen 0.0.0.0 54321
```

On the other computer, connect with:

```sh
./vkport chat connect HOST 54321
```

Use `vk` instead of `./vkport` on Linux or Windows. Replace `HOST` with the listener's reachable address. Both peers must enter the same strong passphrase, shared independently and securely beforehand. Each listener accepts one peer. Messages are UTF-8 text up to 16,384 bytes and are never executed as code.

VKLINK/2 uses Argon2id and authenticated XChaCha20-Poly1305 secret streams; it is incompatible with the earlier plaintext VKLINK/1. This implementation has not had an independent security audit. A weak passphrase can be guessed offline. The shared passphrase authenticates possession of the secret, not individual identity; the protocol does not provide forward secrecy, and addresses and connection metadata remain visible. Bind only on a trusted network, avoid exposing the listener to the public internet, and allow the selected port through the firewall only when needed.

## Platforms and Building

The native editor, launcher, UI Maker, and complete language engine are macOS-only. The app bundle is built for Intel and Apple Silicon; tests run on the host architecture. Linux and Windows receive only the portable command-line runner, which is a separate implementation and supports fewer instructions.

Install Apple Command Line Tools, then run `make` to build the native apps and command-line programs. Run `make test` for the interpreter, native UI and launcher self-tests, command-line checks, and chat tests. The portable differential and fuzz checks are available with `make portable-test`. Cross-build the Linux and Windows runners with Zig using `ZIG=/path/to/zig portable/build-portable.sh`; outputs go to `dist/`.