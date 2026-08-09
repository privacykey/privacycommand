# List available commands
default:
    @just --list

# Build every SPM target (Core, auditctlKit, auditctl, guest agent, protocol)
[group("dev")]
build:
    cd privacycommand && swift build

# Run the full SPM test suite (same as CI)
[group("dev")]
test:
    cd privacycommand && swift test

# Tag v<version> and push it to trigger the release workflow (tag must match MARKETING_VERSION)
[group("ship")]
release version:
    git tag "v{{version}}"
    git push origin "v{{version}}"

# Build, sign, notarize and package the DMG locally (needs Developer ID + notary env)
[group("ship")]
release-local:
    ./scripts/release.sh

# Remove SPM build output
[group("dev")]
clean:
    rm -rf privacycommand/.build
