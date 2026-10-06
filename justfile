# Generated from .project/commands.json; regenerate with .project/install.py.
set shell := ["bash", "-uc"]
target := "default"
platform := "default"
environment := ""
channel := env("BUILD_CHANNEL", "")
suite := "unit"
package := ""
filter := ""
state := ""
width := "0"
height := "0"
unsigned := "false"
plan := "false"

default: help

# Find available commands
help:
    @python3 .project/projectctl.py help --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Inspect this checkout and its capabilities
info:
    @python3 .project/projectctl.py info --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Check whether this machine is ready
doctor:
    @python3 .project/projectctl.py doctor --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Prepare a fresh checkout
setup:
    @python3 .project/projectctl.py setup --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Remove reproducible build outputs
clean:
    @python3 .project/projectctl.py clean --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Run the normal validation bundle
check:
    @python3 .project/projectctl.py check --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Check static code and conventions
lint:
    @python3 .project/projectctl.py lint --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Run the declared security checks
security-check:
    @python3 .project/projectctl.py security-check --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Validate docs and their visibility
docs-check:
    @python3 .project/projectctl.py docs-check --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Run the default automated tests
test:
    @python3 .project/projectctl.py test --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Change the marketing version deliberately
version chosen notes_file:
    @python3 .project/projectctl.py version {{quote(chosen)}} --notes {{quote(notes_file)}} --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Refresh release notes and feeds
changelog:
    @python3 .project/projectctl.py changelog --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Read CI for the selected revision
ci-status ref="":
    @python3 .project/projectctl.py ci-status {{quote(ref)}} --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Dispatch a named workflow deliberately
ci workflow ref:
    @python3 .project/projectctl.py ci {{quote(workflow)}} --ref {{quote(ref)}} --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Compile the intended product
build:
    @python3 .project/projectctl.py build --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Check types without publishing
typecheck:
    @python3 .project/projectctl.py typecheck --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Create and verify a native archive
archive selected_platform=platform:
    @python3 .project/projectctl.py archive {{if unsigned == "true" { "--unsigned" } else { "" }}} {{if plan == "true" { "--plan" } else { "" }}} --target {{quote(target)}} --platform {{quote(selected_platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Inspect a built artifact before shipping
artifact-verify artifact selected_platform=platform:
    @python3 .project/projectctl.py artifact-verify {{quote(artifact)}} --target {{quote(target)}} --platform {{quote(selected_platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Export an existing verified archive
export artifact selected_platform=platform:
    @python3 .project/projectctl.py export {{quote(artifact)}} --target {{quote(target)}} --platform {{quote(selected_platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Keep a combined local convenience task
archive-export selected_platform=platform:
    @python3 .project/projectctl.py archive-export --target {{quote(target)}} --platform {{quote(selected_platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Preview the release actions
release-plan selected_platform=platform:
    @python3 .project/projectctl.py release-plan --target {{quote(target)}} --platform {{quote(selected_platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Validate release eligibility
release-check:
    @python3 .project/projectctl.py release-check --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Capture reproducible screenshots
screenshot value="":
    @python3 .project/projectctl.py screenshot {{quote(value)}} --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Start an interactive development loop
dev value="":
    @python3 .project/projectctl.py dev {{quote(value)}} --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Copy the shared Settings, menu and About code into this app
surfaces:
    @python3 .project/projectctl.py surfaces --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Create and trigger a versioned release
release chosen:
    @python3 .project/projectctl.py release {{quote(chosen)}} --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}

# Keep the combined local release builder
release-local:
    @python3 .project/projectctl.py release-local --target {{quote(target)}} --platform {{quote(platform)}} --environment {{quote(environment)}} --channel {{quote(channel)}} --suite {{quote(suite)}} --package {{quote(package)}} --filter {{quote(filter)}} --state {{quote(state)}} --width {{quote(width)}} --height {{quote(height)}}
