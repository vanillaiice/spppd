.PHONY: run car-stats test test-serial test-visual test-server test-online test-online-visual listen sound-report server relay-linux deploy-relay check-relay deploy-backup site-downloads web site site-dev deploy-site itch release-files zip apk aab apk-perf win64 linux macos all clean

# src/config.lua holds the version.
ver := $(shell sed -n 's/.*VERSION = "\(.*\)".*/\1/p' src/config.lua)
name := spppd

# The LÖVE that runs the game here: the LÖVE 12 build bin/love12 is pinned to,
# fetched the first time. make test LOVE=love runs the tests on the system's LÖVE
# instead, e.g. 11.5 to check the browser build (love.js, LÖVE 11.4) still works.
LOVE ?= ./bin/love12
export LOVE

run:
	$(LOVE) .

# The race setup's car stats, measured through the real dynamics. Rerun after
# changing a car or the handling; a test fails until you do.
car-stats:
	luajit -e 'package.path = "./?.lua;" .. package.path; io.write(require("src.sim.car_stats").file(require("src.entities.garage")))' > src/sim/car_stats_data.lua.tmp
	mv src/sim/car_stats_data.lua.tmp src/sim/car_stats_data.lua

# Simulation, rules, editor and support code. Needs no display. Runs on every core;
# test-serial runs it in one process, in order.
test:
	./bin/test-parallel

test-serial:
	$(LOVE) . --test

# Plays the real game through its real input handlers. Needs a display.
test-visual:
	$(LOVE) . --visual flow

# Old and new sounds side by side, with the engine on a slider.
listen:
	$(LOVE) . --visual listen

# Measures every sound and the mix, old against new. See SOUND.md.
# pip install -r tests/sound/requirements.txt first.
sound-report:
	$(LOVE) . --sounds old dist/sfx/old
	$(LOVE) . --sounds new dist/sfx/new
	python3 tests/sound/analyze.py dist/sfx/old --json dist/sfx/old.json > /dev/null
	python3 tests/sound/analyze.py dist/sfx/new --json dist/sfx/new.json
	python3 tests/sound/analyze.py dist/sfx/new --compare dist/sfx/old.json
	python3 tests/sound/mix.py dist/sfx/new --compare dist/sfx/old

test-server:
	cd server && go vet ./... && go test -race ./...

# Two clients racing through a real relay on this machine.
test-online:
	cd server && go build -o ../dist/relay .
	./dist/relay -addr 127.0.0.1:18080 -db= -temp-db= -quick-fill 2s & pid=$$!; sleep 0.5; \
	SPPPD_RELAY=127.0.0.1:18080 $(LOVE) . --test network; code=$$?; kill $$pid; exit $$code

# The real game online, through its real input handlers, against three bots and a
# real relay. Needs a display.
test-online-visual:
	cd server && go build -o ../dist/relay .
	./dist/relay -addr 127.0.0.1:18080 -db= -temp-db= -quick-fill 2s & pid=$$!; sleep 0.5; \
	SPPPD_RELAY=127.0.0.1:18080 $(LOVE) . --visual online; code=$$?; kill $$pid; exit $$code

server:
	mkdir -p dist
	cd server && go build -o ../dist/relay .

# The static binary the server runs. See config/deploy.yml.
relay-linux:
	mkdir -p dist
	cd server && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o ../dist/relay-linux .

deploy-relay: test-server
	./bin/relay-deploy

# Checks the official relay answers without counting in its analytics. Never point
# the network tests at it: they make rooms and races that end up in the stats.
check-relay:
	./bin/relay-check

# Litestream, which backs the relay's database up to a bucket. See config/litestream.yml.
deploy-backup:
	./bin/backup-deploy

# The website, in site/. It links this version's release builds on GitHub and shows
# their sizes, so build those first with make zip win64 linux macos apk.
site_files := $(name)-$(ver)-win64.zip $(name)-$(ver)-linux.AppImage $(name)-$(ver)-macos.zip $(name)-$(ver)-android.apk $(name)-$(ver).love

release-files:
	@for f in $(site_files); do \
	  [ -f dist/$$f ] || { echo "dist/$$f is missing: run make zip win64 linux macos apk first"; exit 1; }; \
	done

site-downloads: release-files
	rm -rf site/public/download
	cd dist && printf '{"version":"$(ver)","bytes":{' > ../site/src/downloads.json && \
	  sep=; for f in $(site_files); do printf '%s"%s":%s' "$$sep" "$$f" "$$(stat -c %s $$f)" >> ../site/src/downloads.json; sep=,; done && \
	  printf '}}\n' >> ../site/src/downloads.json

# The browser version, into site/public/play/ for the site's /play/ page.
web:
	cd site && npm ci
	./bin/web-build

site: site-downloads web
	cd site && npm run build

site-dev: site-downloads
	cd site && npm run dev

# Builds the site's image and deploys it behind kamal-proxy. See config/deploy.yml.
deploy-site: site
	./bin/site-deploy

# Uploads this version's release builds to itch.io with butler. Run butler login once
# first. The channel names tell itch which platform each build is for.
itch_game := vanillaiice/spppd

# The browser version goes up too, as the demo played on the page before buying. It
# needs make web first (make deploy-site runs it).
itch: release-files
	./bin/itch-web $(ver) dist/$(name)-$(ver)-web.zip
	butler push dist/$(name)-$(ver)-web.zip $(itch_game):html5 --userversion $(ver)
	butler push dist/$(name)-$(ver)-win64.zip $(itch_game):windows-64 --userversion $(ver)
	butler push dist/$(name)-$(ver)-android.apk $(itch_game):android --userversion $(ver)
	butler push dist/$(name)-$(ver)-linux.AppImage $(itch_game):linux --userversion $(ver)
	butler push dist/$(name)-$(ver)-macos.zip $(itch_game):mac --userversion $(ver)

clean:
	rm -rf dist/

# Tests stay out of the build.
zip:
	mkdir -p dist/
	rm -f dist/${name}-${ver}.love
	zip -q -9 -r dist/${name}-${ver}.love main.lua conf.lua LICENSE assets src

# The phone build. See android/apk.sh for what it needs; F-Droid builds its own
# from source (android/fdroid.yml).
apk: zip
	./android/apk.sh

# The bundle Google Play takes, signed with the upload key: see android/aab.sh.
aab: zip
	./android/aab.sh

# An APK that runs love . --perf as soon as it opens. Read the results with
# adb logcat | grep PERF. It shares the game's save folder but changes nothing in it.
apk-perf:
	rm -rf dist/perf && mkdir -p dist/perf
	cp -r main.lua conf.lua LICENSE assets src tests dist/perf/
	printf 'local load = love.load\nlove.load = function(args) args[#args + 1] = "--perf" load(args) end\n' >> dist/perf/main.lua
	cd dist/perf && zip -q -9 -r ../spppd-${ver}-perf.love .
	GAME=dist/spppd-${ver}-perf.love OUTPUT=dist/spppd-${ver}-perf.apk ./android/apk.sh

# The desktop builds: LÖVE 12 (bin/love12 fetches it) with the game fused in.
# LÖVE 12 has no 32-bit Windows build.
win64: zip
	src=$$(./bin/love12 --fetch love-windows-x64) && \
	  rm -rf dist/win64 dist/love-win64 && mkdir -p dist/win64 && \
	  unzip -q $$src/love-12.0-win64.zip -d dist/love-win64
	cp dist/love-win64/love-12.0-win64/*.dll dist/love-win64/love-12.0-win64/*.ico dist/win64/
	cp dist/love-win64/love-12.0-win64/license.txt dist/win64/love-license.txt
	cat dist/love-win64/love-12.0-win64/love.exe dist/${name}-${ver}.love > dist/win64/${name}.exe
	cp LICENSE dist/win64/LICENSE.txt
	cp assets/fonts/OFL.txt dist/win64/
	rm -rf dist/love-win64 dist/${name}-${ver}-win64.zip
	cd dist/win64/ && zip -q -9 -r ../${name}-${ver}-win64.zip .

# One file that runs on most Linux desktops: LÖVE's AppImage with the game inside.
appimagetool := love-binaries/appimagetool-1.9.1-x86_64.AppImage
$(appimagetool):
	mkdir -p love-binaries
	curl -fL -o $@.part https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage
	chmod +x $@.part && mv $@.part $@

# The part of an AppImage that runs it, pinned too: without one, appimagetool
# fetches the newest from GitHub on every build.
appimage_runtime := love-binaries/appimage-runtime-20251108-x86_64
$(appimage_runtime):
	mkdir -p love-binaries
	curl -fL -o $@.part https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64
	mv $@.part $@

linux: zip $(appimagetool) $(appimage_runtime)
	./bin/love12 --version > /dev/null
	rm -rf dist/linux && mkdir -p dist/linux
	cp -a love-binaries/12-*/love-linux-X64.AppImage/squashfs-root dist/linux/SPPPD.AppDir
	cp dist/${name}-${ver}.love dist/linux/SPPPD.AppDir/spppd.love
	sed -i 's|^#FUSE_PATH="$$APPDIR/my_game.love"|FUSE_PATH="$$APPDIR/spppd.love"|' dist/linux/SPPPD.AppDir/AppRun
	grep -q '^FUSE_PATH=' dist/linux/SPPPD.AppDir/AppRun
	rm -f dist/linux/SPPPD.AppDir/love.desktop dist/linux/SPPPD.AppDir/love.svg dist/linux/SPPPD.AppDir/.DirIcon
	cp android/res/drawable-xxxhdpi/love.png dist/linux/SPPPD.AppDir/spppd.png
	printf '[Desktop Entry]\nName=SPPPD\nComment=Top-down arcade racing\nExec=spppd\nType=Application\nCategories=Game;\nTerminal=false\nIcon=spppd\n' > dist/linux/SPPPD.AppDir/spppd.desktop
	cp LICENSE assets/fonts/OFL.txt dist/linux/SPPPD.AppDir/
	rm -f dist/${name}-${ver}-linux.AppImage
	APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 $(appimagetool) --no-appstream --runtime-file $(appimage_runtime) dist/linux/SPPPD.AppDir dist/${name}-${ver}-linux.AppImage

# An app for macOS 10.15 and later, unsigned: players open it with right-click, Open.
macos: zip
	src=$$(./bin/love12 --fetch love-macos) && \
	  rm -rf dist/macos && mkdir -p dist/macos && \
	  unzip -q $$src/love-macos.zip -d dist/macos
	mv dist/macos/love.app dist/macos/SPPPD.app
	cp dist/${name}-${ver}.love dist/macos/SPPPD.app/Contents/Resources/spppd.love
	python3 bin/mac-plist dist/macos/SPPPD.app/Contents/Info.plist ${ver}
	cp LICENSE dist/macos/LICENSE.txt
	rm -f dist/${name}-${ver}-macos.zip
	cd dist/macos && zip -q -9 -y -r ../${name}-${ver}-macos.zip SPPPD.app LICENSE.txt

all: clean zip win64 linux macos
