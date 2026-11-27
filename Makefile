CC = clang
CFLAGS = -arch x86_64 -arch arm64 -mmacosx-version-min=11.0 -fobjc-arc -Wall -Wextra -Werror
APP = Vektkove.app/Contents/MacOS/Vektkove
LAUNCHER = VektkoveLauncher.app/Contents/MacOS/VektkoveLauncher

.PHONY: all test portable-test
SODIUM = deps/sodium-mac
all: $(APP) $(LAUNCHER) vk vkport

$(SODIUM)/lib/libsodium.a:
	portable/build-sodium.sh mac

portable-test: vk $(SODIUM)/lib/libsodium.a
	$(CC) -std=c11 -Wall -Wextra -Werror -O1 -pthread -fsanitize=address,undefined -I$(SODIUM)/include portable/vkport.c $(SODIUM)/lib/libsodium.a -lm -o /tmp/vkport-test
	portable/difftest.sh /tmp/vkport-test
	python3 portable/fuzz.py /tmp/vkport-test 300 7
	python3 portable/chat_test.py /tmp/vkport-test
	/tmp/vkport-test compile examples/game2d.vk /tmp/vektkove-game2d-portable.vkb
	/tmp/vkport-test compile examples/multi_server.vk /tmp/vektkove-multi-server-portable.vkb
	/tmp/vkport-test compile examples/multi_client.vk /tmp/vektkove-multi-client-portable.vkb
	sh portable/net_test.sh /tmp/vkport-test
	@test "`./vk keywords | wc -l | tr -d ' '`" = "`/tmp/vkport-test keyword-count`"

$(APP): VKEngine.m VKEngine.h portable/vkcodec.h Vektkove.m third_party/mini3d/mini3d.c third_party/mini3d/LICENSE Info.plist Makefile
	mkdir -p Vektkove.app/Contents/MacOS
	mkdir -p Vektkove.app/Contents/Resources
	cp Info.plist Vektkove.app/Contents/Info.plist
	cp third_party/mini3d/LICENSE Vektkove.app/Contents/Resources/Mini3D-LICENSE.txt
	$(CC) $(CFLAGS) -framework Cocoa -framework AVFoundation -framework QuartzCore -framework UniformTypeIdentifiers -framework ModelIO VKEngine.m Vektkove.m -o "$@"

$(LAUNCHER): VKEngine.m VKEngine.h portable/vkcodec.h Vektkove.m third_party/mini3d/mini3d.c third_party/mini3d/LICENSE LauncherInfo.plist Makefile
	mkdir -p VektkoveLauncher.app/Contents/MacOS
	mkdir -p VektkoveLauncher.app/Contents/Resources
	cp LauncherInfo.plist VektkoveLauncher.app/Contents/Info.plist
	cp third_party/mini3d/LICENSE VektkoveLauncher.app/Contents/Resources/Mini3D-LICENSE.txt
	$(CC) $(CFLAGS) -DVEKTKOVE_LAUNCHER -framework Cocoa -framework AVFoundation -framework QuartzCore -framework UniformTypeIdentifiers -framework ModelIO VKEngine.m Vektkove.m -o "$@"

vk: VKEngine.m VKEngine.h portable/vkcodec.h vk.m Makefile
	$(CC) $(CFLAGS) -framework Foundation VKEngine.m vk.m -o "$@"

vkport: portable/vkport.c portable/vkcodec.h Makefile $(SODIUM)/lib/libsodium.a
	$(CC) $(CFLAGS) -pthread -I$(SODIUM)/include portable/vkport.c $(SODIUM)/lib/libsodium.a -lm -o "$@"

engine_test: VKEngine.m VKEngine.h portable/vkcodec.h engine_test.m Makefile
	$(CC) $(CFLAGS) -framework Foundation VKEngine.m engine_test.m -o "$@"

test: all engine_test
	./engine_test
	"$(APP)" --self-test
	"$(LAUNCHER)" --self-test
	./vk compile examples/hello.vk /tmp/vektkove-test.vkb
	./vk run /tmp/vektkove-test.vkb
	./vk compile examples/scene3d.vk /tmp/vektkove-scene3d-test.vkb
	./vk run /tmp/vektkove-scene3d-test.vkb
	./vk compile examples/code3d.vk /tmp/vektkove-code3d-test.vkb
	./vk run /tmp/vektkove-code3d-test.vkb
	./vk compile examples/game2d.vk /tmp/vektkove-game2d-test.vkb
	./vk run /tmp/vektkove-game2d-test.vkb
	./vk compile examples/server.vk /tmp/vektkove-server-test.vkb
	./vk compile examples/client.vk /tmp/vektkove-client-test.vkb
	./vk compile examples/multi_server.vk /tmp/vektkove-multi-server-test.vkb
	./vk compile examples/multi_client.vk /tmp/vektkove-multi-client-test.vkb
	./vkport compile examples/game2d.vk /tmp/vektkove-game2d-portable-test.vkb
	./vkport compile examples/multi_server.vk /tmp/vektkove-multi-server-portable-test.vkb
	./vkport compile examples/multi_client.vk /tmp/vektkove-multi-client-portable-test.vkb
	python3 portable/chat_test.py ./vkport
	sh portable/net_test.sh ./vkport
	@test `./vk keywords | wc -l | tr -d ' '` -eq 1318
	@test "`./vkport keyword-count`" = "`./vk keywords | wc -l | tr -d ' '`"