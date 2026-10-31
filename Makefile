.PHONY: run test test-visual test-server test-online server zip win64 win32 all clean

ver := 2.1.0
name := spppd

run:
	love .

# Simulation, rules, editor and support code. Needs no display.
test:
	love . --test

# Plays the real game through its real input handlers. Needs a display.
test-visual:
	love . --visual flow

test-server:
	cd server && go vet ./... && go test -race ./...

# Two clients racing through a real relay on this machine.
test-online:
	cd server && go build -o ../dist/relay .
	./dist/relay -addr 127.0.0.1:18080 & pid=$$!; sleep 0.5; \
	SPPPD_RELAY=127.0.0.1:18080 love . --test network; code=$$?; kill $$pid; exit $$code

server:
	mkdir -p dist
	cd server && go build -o ../dist/relay .

clean:
	rm -rf dist/

# Tests stay out of the build.
zip:
	mkdir -p dist/
	zip -9 -r dist/${name}-${ver}.love main.lua conf.lua LICENSE assets src

dist/love-binaries/love-11.5-win64.zip:
	mkdir -p dist/love-binaries
	curl -L -o dist/love-binaries/love-11.5-win64.zip https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip
	cd dist/love-binaries && unzip -o love-11.5-win64.zip

dist/love-binaries/love-11.5-win32.zip:
	mkdir -p dist/love-binaries
	curl -L -o dist/love-binaries/love-11.5-win32.zip https://github.com/love2d/love/releases/download/11.5/love-11.5-win32.zip
	cd dist/love-binaries && unzip -o love-11.5-win32.zip

win64: zip dist/love-binaries/love-11.5-win64.zip
	mkdir -p dist/win64/
	rm -rf dist/win64/*
	cp dist/love-binaries/love-11.5-win64/*.dll dist/win64/
	cp dist/love-binaries/love-11.5-win64/*.txt dist/win64/
	cp dist/love-binaries/love-11.5-win64/*.ico dist/win64/
	cp LICENSE dist/win64/LICENSE.txt
	cp assets/fonts/OFL.txt dist/win64/
	cat dist/love-binaries/love-11.5-win64/love.exe dist/${name}-${ver}.love > dist/win64/${name}.exe
	cd dist/win64/ && zip -9 -r ../${name}-${ver}-win64.zip .

win32: zip dist/love-binaries/love-11.5-win32.zip
	mkdir -p dist/win32/
	rm -rf dist/win32/*
	cp dist/love-binaries/love-11.5-win32/*.dll dist/win32/
	cp dist/love-binaries/love-11.5-win32/*.txt dist/win32/
	cp dist/love-binaries/love-11.5-win32/*.ico dist/win32/
	cp LICENSE dist/win32/LICENSE.txt
	cp assets/fonts/OFL.txt dist/win32/
	cat dist/love-binaries/love-11.5-win32/love.exe dist/${name}-${ver}.love > dist/win32/${name}.exe
	cd dist/win32/ && zip -9 -r ../${name}-${ver}-win32.zip .

all: clean zip win64 win32
