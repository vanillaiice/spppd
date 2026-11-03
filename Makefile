.PHONY: run test test-visual test-server test-online test-online-visual listen sound-report server relay-linux deploy-relay zip apk apk-perf win64 win32 all clean

# src/config.lua holds the version.
ver := $(shell sed -n 's/.*VERSION = "\(.*\)".*/\1/p' src/config.lua)
name := spppd

run:
	love .

# Simulation, rules, editor and support code. Needs no display.
test:
	love . --test

# Plays the real game through its real input handlers. Needs a display.
test-visual:
	love . --visual flow

# Old and new sounds side by side, with the engine on a slider.
listen:
	love . --visual listen

# Measures every sound and the mix, old against new. See SOUND.md.
# pip install -r tests/sound/requirements.txt first.
sound-report:
	love . --sounds old dist/sfx/old
	love . --sounds new dist/sfx/new
	python3 tests/sound/analyze.py dist/sfx/old --json dist/sfx/old.json > /dev/null
	python3 tests/sound/analyze.py dist/sfx/new --json dist/sfx/new.json
	python3 tests/sound/analyze.py dist/sfx/new --compare dist/sfx/old.json
	python3 tests/sound/mix.py dist/sfx/new --compare dist/sfx/old

test-server:
	cd server && go vet ./... && go test -race ./...

# Two clients racing through a real relay on this machine.
test-online:
	cd server && go build -o ../dist/relay .
	./dist/relay -addr 127.0.0.1:18080 -db= & pid=$$!; sleep 0.5; \
	SPPPD_RELAY=127.0.0.1:18080 love . --test network; code=$$?; kill $$pid; exit $$code

# The real game online, through its real input handlers, against three bots and a
# real relay. Needs a display.
test-online-visual:
	cd server && go build -o ../dist/relay .
	./dist/relay -addr 127.0.0.1:18080 -db= & pid=$$!; sleep 0.5; \
	SPPPD_RELAY=127.0.0.1:18080 love . --visual online; code=$$?; kill $$pid; exit $$code

server:
	mkdir -p dist
	cd server && go build -o ../dist/relay .

# The static binary the server runs. See config/deploy.yml.
relay-linux:
	mkdir -p dist
	cd server && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o ../dist/relay-linux .

deploy-relay: test-server
	./bin/relay-deploy

clean:
	rm -rf dist/

# Tests stay out of the build.
zip:
	mkdir -p dist/
	zip -9 -r dist/${name}-${ver}.love main.lua conf.lua LICENSE assets src

# A test build for a phone. See android/apk.sh for what it needs.
apk: zip
	./android/apk.sh

# An APK that runs love . --perf as soon as it opens. Read the results with
# adb logcat | grep PERF. It shares the game's save folder but changes nothing in it.
apk-perf:
	rm -rf dist/perf && mkdir -p dist/perf
	cp -r main.lua conf.lua LICENSE assets src tests dist/perf/
	printf 'local load = love.load\nlove.load = function(args) args[#args + 1] = "--perf" load(args) end\n' >> dist/perf/main.lua
	cd dist/perf && zip -q -9 -r ../spppd-${ver}-perf.love .
	GAME=dist/spppd-${ver}-perf.love OUTPUT=dist/spppd-${ver}-perf.apk ./android/apk.sh

dist/love-binaries/love-11.5-%.zip:
	mkdir -p dist/love-binaries
	curl -L -o $@ https://github.com/love2d/love/releases/download/11.5/love-11.5-$*.zip
	cd dist/love-binaries && unzip -o love-11.5-$*.zip

win64 win32: %: zip dist/love-binaries/love-11.5-%.zip
	mkdir -p dist/$@/
	rm -rf dist/$@/*
	cp dist/love-binaries/love-11.5-$@/*.dll dist/$@/
	cp dist/love-binaries/love-11.5-$@/*.txt dist/$@/
	cp dist/love-binaries/love-11.5-$@/*.ico dist/$@/
	cp LICENSE dist/$@/LICENSE.txt
	cp assets/fonts/OFL.txt dist/$@/
	cat dist/love-binaries/love-11.5-$@/love.exe dist/${name}-${ver}.love > dist/$@/${name}.exe
	cd dist/$@/ && zip -9 -r ../${name}-${ver}-$@.zip .

all: clean zip win64 win32
