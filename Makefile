APP := dist/LightroomSync.app

.PHONY: app run install refresh-icon test clean

## Build dist/LightroomSync.app (macOS)
app:
	scripts/build-app.sh

## Build and launch the app
run: app
	open $(APP)

## Copy the built app to /Applications and refresh its icon
install: app
	rm -rf /Applications/LightroomSync.app
	cp -R $(APP) /Applications/LightroomSync.app
	@$(MAKE) --no-print-directory refresh-icon
	@echo "Installed /Applications/LightroomSync.app"

## Make Finder and the Dock notice a changed app icon
## macOS caches icons per bundle, so a bundle that once had none keeps showing the blank one.
refresh-icon:
	@touch /Applications/LightroomSync.app 2>/dev/null || true
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f /Applications/LightroomSync.app >/dev/null 2>&1 || true
	@killall Dock >/dev/null 2>&1 || true
	@echo "Refreshed the icon cache (the Dock restarts for a moment)"

## Run the core library tests (needs Xcode on macOS; works as is on Linux)
test:
	scripts/run-tests.sh

clean:
	rm -rf .build dist
