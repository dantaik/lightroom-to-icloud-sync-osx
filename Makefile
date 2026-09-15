APP := dist/LightroomSync.app

.PHONY: app run install test clean

## Build dist/LightroomSync.app (macOS)
app:
	scripts/build-app.sh

## Build and launch the app
run: app
	open $(APP)

## Copy the built app to /Applications
install: app
	rm -rf /Applications/LightroomSync.app
	cp -R $(APP) /Applications/LightroomSync.app
	@echo "Installed /Applications/LightroomSync.app"

## Run the core library tests (needs Xcode on macOS; works as is on Linux)
test:
	scripts/run-tests.sh

clean:
	rm -rf .build dist
