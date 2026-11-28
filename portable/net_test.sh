#!/bin/sh
set -eu
PORTABLE="${1:?usage: net_test.sh /path/to/vkport}"
WORK="$(mktemp -d)"
PORT=$((20000 + ($$ % 40000)))
SERVER_PID=""
cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM
printf 'server_script\nnet_listen "127.0.0.1" %s\nnet_receive incoming\nnet_send $incoming\nnet_close\n' "$PORT" > "$WORK/server.vk"
printf 'local_script\nnet_connect "127.0.0.1" %s\nnet_send "portable loopback"\nnet_receive reply\nout $reply\nnet_close\n' "$PORT" > "$WORK/client.vk"
"$PORTABLE" run "$WORK/server.vk" > "$WORK/server.out" 2> "$WORK/server.err" &
SERVER_PID=$!
CONNECTED=0
for attempt in $(seq 1 100); do
    if "$PORTABLE" run "$WORK/client.vk" > "$WORK/client.out" 2> "$WORK/client.err"; then
        CONNECTED=1
        break
    fi
done
if [ "$CONNECTED" -ne 1 ]; then
    cat "$WORK/client.err" >&2
    exit 1
fi
wait "$SERVER_PID"
SERVER_PID=""
if [ "$(cat "$WORK/client.out")" != "portable loopback" ]; then
    printf 'unexpected network response: %s\n' "$(cat "$WORK/client.out")" >&2
    exit 1
fi
printf 'server/local TCP loopback test passed\n'
MULTI_PORT=$((PORT + 1))
printf 'server_script\nnet_peer_count before\nout $before\nnet_listen_multi "127.0.0.1" %s 2\nnet_peer_count connected\nout $connected\nnet_receive_from sender message\nnet_send_to $sender $message\nnet_receive_from sender2 message2\nnet_send_to $sender2 $message2\nnet_broadcast "ready"\nnet_close\nnet_peer_count closed\nout $closed\n' "$MULTI_PORT" > "$WORK/multi-server.vk"
printf 'local_script\nnet_connect "127.0.0.1" %s\nnet_send "player one"\nnet_receive reply\nnet_receive ready\nout $reply\nout $ready\nnet_close\n' "$MULTI_PORT" > "$WORK/client-one.vk"
printf 'local_script\nnet_connect "127.0.0.1" %s\nnet_send "player two"\nnet_receive reply\nnet_receive ready\nout $reply\nout $ready\nnet_close\n' "$MULTI_PORT" > "$WORK/client-two.vk"
"$PORTABLE" run "$WORK/multi-server.vk" > "$WORK/multi-server.out" 2> "$WORK/multi-server.err" &
SERVER_PID=$!
run_multi_client() {
    source="$1"
    output="$2"
    for attempt in $(seq 1 100); do
        if "$PORTABLE" run "$source" > "$output" 2> "$output.err"; then return 0; fi
    done
    cat "$output.err" >&2
    return 1
}
run_multi_client "$WORK/client-one.vk" "$WORK/client-one.out" &
CLIENT_ONE_PID=$!
run_multi_client "$WORK/client-two.vk" "$WORK/client-two.out" &
CLIENT_TWO_PID=$!
wait "$CLIENT_ONE_PID"
wait "$CLIENT_TWO_PID"
wait "$SERVER_PID"
SERVER_PID=""
if [ "$(cat "$WORK/multi-server.out")" != "$(printf '0\n2\n0')" ]; then
    printf 'unexpected peer counts: %s\n' "$(cat "$WORK/multi-server.out")" >&2
    exit 1
fi
if [ "$(sed -n '1p' "$WORK/client-one.out")" != "player one" ] || [ "$(sed -n '2p' "$WORK/client-one.out")" != "ready" ] ||
    [ "$(sed -n '1p' "$WORK/client-two.out")" != "player two" ] || [ "$(sed -n '2p' "$WORK/client-two.out")" != "ready" ]; then
    printf 'unexpected multi-client responses: one=%s two=%s\n' "$(cat "$WORK/client-one.out")" "$(cat "$WORK/client-two.out")" >&2
    exit 1
fi
printf 'multi-client TCP loopback test passed\n'
