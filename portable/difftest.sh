#!/bin/bash
# Differential test: the macOS engine (./vk) and the portable runner must agree on
# compiled bytecode, program output, and success/failure for every case.
# Usage: portable/difftest.sh /path/to/vkport
set -u
cd "$(dirname "$0")/.." || exit 1
PORT="${1:?usage: difftest.sh /path/to/vkport}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0; n=0

check() {
  n=$((n + 1))
  printf '%b' "$1" > "$WORK/p.vk"
  ./vk compile "$WORK/p.vk" "$WORK/mac.vkb" 2> "$WORK/mac.cerr"; mac_c=$?
  "$PORT" compile "$WORK/p.vk" "$WORK/port.vkb" 2> "$WORK/port.cerr"; port_c=$?
  if [ "$mac_c" != "$port_c" ]; then echo "FAIL #$n compile status differs ($mac_c vs $port_c): $1"; fail=$((fail + 1)); return; fi
  if [ "$mac_c" = 0 ]; then
    if ! cmp -s "$WORK/mac.vkb" "$WORK/port.vkb"; then echo "FAIL #$n bytecode differs: $1"; fail=$((fail + 1)); return; fi
    ./vk run "$WORK/mac.vkb" > "$WORK/mac.out" 2> "$WORK/mac.err"; mac_r=$?
    "$PORT" run "$WORK/mac.vkb" > "$WORK/port.out" 2> "$WORK/port.err"; port_r=$?
    if [ "$mac_r" != "$port_r" ]; then echo "FAIL #$n run status differs ($mac_r vs $port_r): $1"; fail=$((fail + 1)); return; fi
    if ! cmp -s "$WORK/mac.out" "$WORK/port.out"; then echo "FAIL #$n output differs: $1"; echo "  mac : $(head -c 300 "$WORK/mac.out" | tr '\n' '|')"; echo "  port: $(head -c 300 "$WORK/port.out" | tr '\n' '|')"; fail=$((fail + 1)); return; fi
    if [ "$mac_r" != 0 ] && [ "$(head -1 "$WORK/mac.err")" != "$(head -1 "$WORK/port.err")" ]; then echo "FAIL #$n error text differs: $1"; echo "  mac : $(head -1 "$WORK/mac.err")"; echo "  port: $(head -1 "$WORK/port.err")"; fail=$((fail + 1)); return; fi
  fi
  pass=$((pass + 1))
}

# --- core and numbers ---
check 'text g "Hello"\nout $g\nset t 2\nadd t 3\nout $t\nhalt\nout "no"'
check 'set a 0x10\nout $a\nset b 5.\nout $b\nset c 1e5\nout $c\nset d 100000000\nout $d\nset e 1e15\nout $e'
check 'set f 100000000000000000000\nout $f\nset g 0.1\nadd g 0.2\nout $g\nset h 1\ndivide h 3\nout $h'
check 'set i inf\nout $i\nset j +7\nout $j\nset k 1e400\nout $k\nset l 1e-7\nout $l\nset m 123456789012345678\nout $m\nset n -0\nout $n'
check 'set n 12\nsubtract n 2\nmultiply n 3\ndivide n 5\nmodulo n 4\npower n 2\nout $n'
check 'set n 7\nmodulo n 3\nout $n\nset m -7\nmodulo m 3\nout $m'
check 'set n 1\ndivide n 0'
check 'set n 1\nmodulo n 0'
check 'set n -1\nsqrt n'
check 'set n 0\nlog n'
check 'set n 2\nasin n'
check 'set n 10\npower n 400'
check 'set n 5\nnegate n\nout $n\nabs n\nout $n'
check 'set n 2.5\nround n\nout $n\nset m -2.5\nround m\nout $m'
check 'set n 2.6\nfloor n\nout $n\nset m 2.1\nceil m\nout $m\nset t -2.6\ntruncate t\nout $t'
check 'set n 5\nsign n\nout $n\nset m -3\nsign m\nout $m\nset z 0\nsign z\nout $z'
check 'set n 5\nmin n 2\nout $n\nset m 5\nmax m 8\nout $m'
check 'set n 0\nsin n\nout $n\nset c 0\ncos c\nout $c\nset t 1\ntan t\nout $t'
check 'set n 1\nexp n\nout $n\nset l 100\nlog10 l\nout $l\nset a 1\natan a\nout $a'
# --- comparisons and logic ---
check 'set n 5\nequal n 5\nout $n\nset m 5\nnot_equal m 4\nout $m'
check 'text s "5"\nset q 5\nequal q $s\nout $q'
check 'set n 5\nless n 6\nout $n\nset m 5\nless_equal m 5\nout $m\nset g 5\ngreater g 6\nout $g\nset h 5\ngreater_equal h 5\nout $h'
check 'set a 1\nand a 0\nout $a\nset b 0\nor b 1\nout $b\nset c 0\nnot c\nout $c'
check 'text a "x"\nless a 3'
check 'text a "x"\nadd a 1'
# --- text ---
check 'text s "Hello"\nencode s "base64"\nout $s\ndecode s "base64"\nout $s'
check 'text s "Hello"\nencode s "zstd+base64"\ndecode s "base64+zstd"\nout $s'
check 'text s "!!!"\ndecode s "base64"'
check 'codec_list'
check 'text x "Hi"\nconcat x " there"\nupper x\nout $x\nlower x\nlength x\nout $x'
check 'text v "straße"\nupper v\nout $v\ntext w "é😀"\nlength w\nout $w'
check 'text s "ÀÉÎ"\nlower s\nout $s\ntext u "àéî"\nupper u\nout $u'
check 'text s "  hi \\t"\ntrim s\nout $s\nlength s\nout $s'
check 'text s "abc"\ncontains s ""\nout $s\ntext t "abc"\nstarts_with t ""\nout $t\ntext u "abc"\nends_with u ""\nout $u'
check 'text s "hello"\ncontains s "ell"\nout $s\ntext t "hello"\nstarts_with t "he"\nout $t\ntext u "hello"\nends_with u "lo"\nout $u'
check 'text s "hello"\nreplace s "l" "x"\nout $s\ntext t "aaa"\nreplace t "aa" "b"\nout $t'
check 'text s "hello"\nreplace s "" "x"'
check 'text s "hello"\nreplace s "l" ""\nout $s'
check 'set n 3\nis_number n\nout $n\ntext t "a"\nis_text t\nout $t\ntext e ""\nempty e\nout $e'
check 'set n 3\nis_text n\nout $n\ntext t "a"\nis_number t\nout $t'
check 'text s "a\\nb\\"c\\\\d\\u00e9\\ud83d\\ude00"\nout $s\nlength s\nout $s'
check 'out "tab\\there"'
check 'text n 5\nout $n\nconcat n "x"\nout $n'
check 'set n 5\nconcat n "x"\nout $n'
check 'text s "a"\nconcat s 12\nout $s'
check 'set n 3\nlength n\nout $n'
check 'set n 1234567\nupper n'
check 'out bare\nout 3\nout -0\nout +3\nout 007'
check 'out "unterminated'
check 'out "bad\\q"'
check 'out "bad\\u12"'
check 'out "\\ud83d"'
# --- control flow ---
check 'set n 0\nlabel loop\nadd n 1\nset c $n\nless c 3\nif $c loop\nout $n'
check 'set n 5\nequal n 5\nnot n\nunless $n done\nout "bad"\nlabel done\nout "ok"'
check 'label a\nlabel a'
check 'jump missing'
check 'label loop\njump loop'
check 'set n 0\nif $n x\nout "fell"\nlabel x\nout "end"'
check 'text s ""\nunless $s x\nout "bad"\nlabel x\nout "ok"'
check 'if "text" x\nout "bad"\nlabel x\nout "ok"'
# --- keywords, aliases, numbered shortcuts ---
check 'vk_set n -9\ndo_absolute n\nop_sqrt n\nprint $n'
check 'SET n 4\nOUT $n\nHaLt'
check 'set_12 n\nadd n 8\nsubtract_5 n\nmultiply_2 n\ndivide_3 n\nout $n'
check 'set_159860 n'
check 'subtract_159860 n'
check 'multiply_1 n'
check 'divide_1 n'
check 'set_159861 n'
check 'set_01 n'
check 'divide_0 n'
check 'set_0 n\nout $n'
check 'set_7 n\nadd n 1\nout $n\nadd n 99999999999999999\nout $n'
check 'add_100000 n'
check 'add_0 n'
check 'plus n 1'
check 'vk_add n 1'
check 'set_3 n extra'
check 'set n'
check 'frobnicate x'
check 'out'
# --- names, comments, whitespace, line endings ---
check '# comment only\nset n 4 # trailing\nout $n'
check '   \t  set   n   4  \n\n\n  out   $n  '
check 'set n 4\r\nout $n\r\n'
check 'set n 4\rout $n'
check 'set 1bad 4'
check 'set bad-name 4'
check 'set n 4\nout $nn'
check 'out $missing'
check 'add missing 1'
check 'set Name 1\nset name 2\nout $Name\nout $name'
check 'text s "a#b"\nout $s # real comment'
check 'out "a b  c"'
check 'set é 1'
check ''
check '\n\n\n'
# --- UI instructions ---
check 'import ui\nwindow "W" 400 300\nui_label "L" 1 2 3 4\nui_button "B" 1 2 3 4 "m"\nui_input "I" 1 2 3 4'
check 'import ui\nwindow "W" 400 300'
check 'text name "Guest"\nimport ui\nwindow "W" 400 300\nui_input "Name" 1 2 3 4\nui_id "input_name"\nui_label "Guest" 1 8 30 4\nui_id "label_name"\nui_bind "input_name" name\nui_bind "label_name" name'
check 'window "Missing import" 400 300'
check 'import ui\nwindow "Scene" 640 480\nui_scene3d 20 20 600 440\nui_camera3d 0 0 12\nui_light3d 4 6 8 900\nui_box3d 0 0 0 2 2 2 "#FF5533"\nui_id "box"\nui_spin3d "box" 3\nui_sphere3d 3 0 0 1 "#33AAFF"'
check 'import ui\nwindow "Scene" 640 480\nui_scene3d 0 0 500 400\nui_box3d 0 0 0 1 1 1 "#FFFFFF"\nui_id "box"\nui_id "again"'
check 'import ui\nwindow "Scene" 640 480\nui_scene3d 0 0 500 400\nui_light3d 0 0 3 1\nui_id "bad"'
check 'import ui\nwindow "Scene" 640 480\nui_scene3d 0 0 500 400\nui_camera3d 0 0 0'
check 'import ui\nwindow "Scene" 640 480\nui_camera3d 0 0 12'
check 'set hits 0\nimport ui\nwindow "3D Physics" 640 480\nui_scene3d 0 0 640 480\nui_sphere3d 0 0 0 1 "#FF5533"\nui_id "ball"\nui_physics3d "ball" 1 0.8\nui_gravity3d 0 -2 0\nui_velocity3d "ball" 1 2 3\nui_frame3d\nadd hits 1\nui_force3d "ball" 0 2 0\nui_end_frame3d\nhalt'
check 'import ui\nwindow "3D Physics" 640 480\nui_scene3d 0 0 640 480\nui_physics3d "missing" 1 0.8'
check 'import ui\nwindow "3D Physics" 640 480\nui_scene3d 0 0 640 480\nui_frame3d\nui_end_frame3d'
check 'import ui\nwindow "Model" 640 480\nui_scene3d 0 0 640 480\nui_mesh3d "model.obj" 0 1 2 1 "#AABBCC"\nui_id "model"\nui_physics3d "model" 1 0.5\nui_spin3d "model" 2'
check 'import ui\nwindow "Model" 640 480\nui_scene3d 0 0 640 480\nui_mesh3d "model.obj" 0 1 2 0 "#AABBCC"'
check 'import ui\nwindow "3D Physics" 640 480\nui_scene3d 0 0 640 480\nui_sphere3d 0 0 0 1 "#FF5533"\nui_id "ball"\nui_frame3d\nui_move3d "ball" $delta_time 0 0\nui_end_frame3d'
check 'import ui\nwindow "Both" 640 480\nui_scene2d 0 0 100 100\nui_circle2d "circle" 0 0 20 "#FFFFFF"\nui_scene3d 100 0 100 100\nui_frame3d\nui_move2d "circle" 1 0\nui_end_frame3d'
check 'import ui\nwindow "Arcade" 480 300\nui_scene2d 0 0 480 300\nui_circle2d "player" 20 30 36 "#32C8B2"\nui_rect2d "orb" 220 80 28 28 "#FF7059"\nui_velocity2d "orb" -38 27\nui_keymove2d "player" "a" -12 0'
check 'import ui\nwindow "Arcade" 480 300\nui_scene2d 0 0 480 300\nui_circle2d "player" 0 0 20 "#GGGGGG"'
check 'import ui\nwindow "Arcade" 480 300\nui_scene2d 0 0 480 300\nui_keymove2d "missing" "a" 1 0'
check 'set frames 0\nset hits 0\nimport ui\nwindow "Physics" 480 300\nui_scene2d 0 0 480 300\nui_circle2d "ball" 80 80 24 "#FF5533"\nui_physics2d "ball" 1 0.8\nui_gravity2d 0 120\nui_frame2d\nadd frames 1\nif $collision hit\njump done\nlabel hit\nadd hits 1\nui_force2d "ball" -2 0\nlabel done\nui_end_frame2d\nhalt'
check 'import ui\nwindow "Bad frame" 100 100\nui_scene2d 0 0 100 100\nui_frame2d\nadd frames 1'
check 'local_script\nnet_send "not connected"'
check 'local_script\nnet_listen "127.0.0.1" 41001'
check 'local_script\nnet_listen_multi "127.0.0.1" 41001 2'
check 'server_script\nnet_send_to 1 "not connected"'
check 'server_script\nnet_receive_from sender message'
check 'server_script\nnet_broadcast "not connected"'
check 'server_script\nimport ui\nwindow "No UI" 100 100'
check 'server_script\nlocal_script'
check 'terminal_keywords'
check 'terminal_run "help"'
check 'terminal_run "pwd"'
check 'terminal_run "echo"'
check 'cite "Ada Lovelace" "Notes" 1843 "https://example.test/notes"'
check 'cite "" "Title" 2024 "https://example.test"'
check 'text message "hello"\nterminal_echo $message'
check 'terminal_run "rm"'
# --- long output ---
check 'set n 0\nlabel l\nout "0123456789012345678901234567890123456789012345678901234567890123456789"\nadd n 1\nset c $n\nless c 2000\nif $c l'

echo "differential cases: $n  passed: $pass  failed: $fail"
[ "$fail" = 0 ]
