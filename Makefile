.PHONY: backend-install backend-test backend-run ios-generate ios-typecheck verify

backend-install:
	cd backend && python3.12 -m venv .venv && .venv/bin/pip install -e '.[dev]'

backend-test:
	cd backend && .venv/bin/pytest -q

backend-run:
	cd backend && .venv/bin/uvicorn undernyc_backend.app:app --reload

ios-generate:
	cd ios && xcodegen generate

ios-typecheck:
	cd ios && IOS_SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk; \
	/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
	-typecheck -parse-as-library -module-name UnderNYC -target arm64-apple-ios17.0-simulator \
	-sdk "$$IOS_SDK" $$(find UnderNYC -name '*.swift' -print)

verify: backend-test ios-typecheck

