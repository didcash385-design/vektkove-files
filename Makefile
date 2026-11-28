CC = clang
CFLAGS = -arch x86_64 -arch arm64 -mmacosx-version-min=11.0 -fobjc-arc -Wall -Wextra -Werror
APP = Vektkove.app/Contents/MacOS/Vektkove
LAUNCHER = VektkoveLauncher.app/Contents/MacOS/VektkoveLauncher

.PHONY: all test portable-test ai-test
SODIUM = deps/sodium-mac
AI_SRC = portable/vkai.c portable/vkjson.c
AI_DEPS = portable/vkai.h third_party/cjson/cJSON.h third_party/cjson/cJSON.c third_party/cjson/LICENSE
all: $(APP) $(LAUNCHER) vk vkport

$(SODIUM)/lib/libsodium.a:
	portable/build-sodium.sh mac

portable-test: vk $(SODIUM)/lib/libsodium.a
	$(CC) -std=c11 -Wall -Wextra -Werror -O1 -pthread -fsanitize=address,undefined -I$(SODIUM)/include portable/vkport.c $(AI_SRC) $(SODIUM)/lib/libsodium.a -lm -o /tmp/vkport-test
	portable/difftest.sh /tmp/vkport-test
	python3 portable/fuzz.py /tmp/vkport-test 300 7
	python3 portable/chat_test.py /tmp/vkport-test
	node portable/archive_test.mjs /tmp/vkport-test
	node portable/game_state_test.mjs /tmp/vkport-test
	/tmp/vkport-test compile examples/game2d.vk /tmp/vektkove-game2d-portable.vkb
	/tmp/vkport-test compile examples/multi_server.vk /tmp/vektkove-multi-server-portable.vkb
	/tmp/vkport-test compile examples/multi_client.vk /tmp/vektkove-multi-client-portable.vkb
	sh portable/net_test.sh /tmp/vkport-test
	@test "`./vk keywords | wc -l | tr -d ' '`" = "`/tmp/vkport-test keyword-count`"

ai-test: vk vkport
	$(CC) -std=c11 -Wall -Wextra -Werror -O1 -fsanitize=address,undefined $(AI_SRC) portable/ai_test.c -o /tmp/vektkove-ai-test
	node portable/ai_integration_test.mjs /tmp/vektkove-ai-test ./vk ./vkport

$(APP): VKEngine.m VKEngine.h portable/vkcodec.h $(AI_SRC) $(AI_DEPS) Vektkove.m third_party/mini3d/mini3d.c third_party/mini3d/LICENSE Info.plist Makefile
	mkdir -p Vektkove.app/Contents/MacOS
	mkdir -p Vektkove.app/Contents/Resources
	cp Info.plist Vektkove.app/Contents/Info.plist
	cp third_party/mini3d/LICENSE Vektkove.app/Contents/Resources/Mini3D-LICENSE.txt
	cp third_party/cjson/LICENSE Vektkove.app/Contents/Resources/cJSON-LICENSE.txt
	$(CC) $(CFLAGS) -framework Cocoa -framework AVFoundation -framework QuartzCore -framework UniformTypeIdentifiers -framework ModelIO VKEngine.m Vektkove.m $(AI_SRC) -o "$@"

$(LAUNCHER): VKEngine.m VKEngine.h portable/vkcodec.h $(AI_SRC) $(AI_DEPS) Vektkove.m third_party/mini3d/mini3d.c third_party/mini3d/LICENSE LauncherInfo.plist Makefile
	mkdir -p VektkoveLauncher.app/Contents/MacOS
	mkdir -p VektkoveLauncher.app/Contents/Resources
	cp LauncherInfo.plist VektkoveLauncher.app/Contents/Info.plist
	cp third_party/mini3d/LICENSE VektkoveLauncher.app/Contents/Resources/Mini3D-LICENSE.txt
	cp third_party/cjson/LICENSE VektkoveLauncher.app/Contents/Resources/cJSON-LICENSE.txt
	$(CC) $(CFLAGS) -DVEKTKOVE_LAUNCHER -framework Cocoa -framework AVFoundation -framework QuartzCore -framework UniformTypeIdentifiers -framework ModelIO VKEngine.m Vektkove.m $(AI_SRC) -o "$@"

vk: VKEngine.m VKEngine.h portable/vkcodec.h $(AI_SRC) $(AI_DEPS) vk.m Makefile
	$(CC) $(CFLAGS) -framework Foundation VKEngine.m vk.m $(AI_SRC) -o "$@"

vkport: portable/vkport.c portable/vkcodec.h $(AI_SRC) $(AI_DEPS) Makefile $(SODIUM)/lib/libsodium.a
	$(CC) $(CFLAGS) -pthread -I$(SODIUM)/include portable/vkport.c $(AI_SRC) $(SODIUM)/lib/libsodium.a -lm -o "$@"

engine_test: VKEngine.m VKEngine.h portable/vkcodec.h $(AI_SRC) $(AI_DEPS) engine_test.m Makefile
	$(CC) $(CFLAGS) -framework Foundation VKEngine.m engine_test.m $(AI_SRC) -o "$@"

test: all engine_test
	@test "`./vk --version`" = "Vektkove 1.4.3"
	@test "`./vkport --version`" = "Vektkove 1.4.3"
	@test "`./vk run examples/codecs.vk`" = "`printf 'SGVsbG8sIFZla3Rrb3ZlIQ==\\nHello, Vektkove!\\nHello, Vektkove!\\n'`"
	@test "`./vkport run examples/codecs.vk`" = "`printf 'SGVsbG8sIFZla3Rrb3ZlIQ==\\nHello, Vektkove!\\nHello, Vektkove!\\n'`"
	./engine_test
	"$(APP)" --self-test
	"$(LAUNCHER)" --self-test
	./vk compile examples/hello.vk /tmp/vektkove-test.vkb
	./vk run /tmp/vektkove-test.vkb
	./vk check examples/hello.vk
	./vkport check examples/hello.vk
	@test "`./vk score examples/hello.vk`" = 1
	@test "`./vkport score LICENSE`" = 0
	./vk compile examples/scene3d.vk /tmp/vektkove-scene3d-test.vkb
	./vk run /tmp/vektkove-scene3d-test.vkb
	./vk compile examples/code3d.vk /tmp/vektkove-code3d-test.vkb
	./vk run /tmp/vektkove-code3d-test.vkb
	./vk compile examples/voxel3d.vk /tmp/vektkove-voxel3d-test.vkb
	./vk run /tmp/vektkove-voxel3d-test.vkb
	./vk compile examples/physics3d.vk /tmp/vektkove-physics3d-test.vkb
	./vk run /tmp/vektkove-physics3d-test.vkb
	./vk compile examples/boxphysics3d.vk /tmp/vektkove-boxphysics3d-test.vkb
	./vk run /tmp/vektkove-boxphysics3d-test.vkb
	./vk compile examples/entity3d.vk /tmp/vektkove-entity3d-test.vkb
	./vk run /tmp/vektkove-entity3d-test.vkb
	./vk check examples/game_state.vk
	./vkport check examples/game_state.vk
	./vk compile examples/game_state.vk /tmp/vektkove-game-state-test.vkb
	./vk compile examples/ai.vk /tmp/vektkove-ai-example.vkb
	./vk compile examples/game2d.vk /tmp/vektkove-game2d-test.vkb
	./vk run /tmp/vektkove-game2d-test.vkb
	./vk compile examples/server.vk /tmp/vektkove-server-test.vkb
	./vk compile examples/client.vk /tmp/vektkove-client-test.vkb
	./vk compile examples/multi_server.vk /tmp/vektkove-multi-server-test.vkb
	./vk compile examples/multi_client.vk /tmp/vektkove-multi-client-test.vkb
	./vkport compile examples/game2d.vk /tmp/vektkove-game2d-portable-test.vkb
	./vkport compile examples/physics3d.vk /tmp/vektkove-physics3d-portable-test.vkb
	./vkport compile examples/boxphysics3d.vk /tmp/vektkove-boxphysics3d-portable-test.vkb
	./vkport compile examples/entity3d.vk /tmp/vektkove-entity3d-portable-test.vkb
	./vkport compile examples/game_state.vk /tmp/vektkove-game-state-portable-test.vkb
	./vkport compile examples/multi_server.vk /tmp/vektkove-multi-server-portable-test.vkb
	./vkport compile examples/multi_client.vk /tmp/vektkove-multi-client-portable-test.vkb
	python3 portable/chat_test.py ./vkport
	node portable/archive_test.mjs ./vkport
	node portable/game_state_test.mjs ./vkport
	sh portable/net_test.sh ./vkport
	@test `./vk keywords | wc -l | tr -d ' '` -eq 1514
	@test "`./vkport keyword-count`" = "`./vk keywords | wc -l | tr -d ' '`"