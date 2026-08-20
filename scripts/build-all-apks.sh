#!/bin/sh

set -eu

usage() {
	printf 'Usage: %s <debug|release> [--channel <channel>] [--list]\n' "$(basename "$0")" >&2
	exit 2
}

if [ "$#" -lt 1 ]; then
	usage
fi

case "$1" in
	debug|release)
		BUILD_TYPE=$1
		;;
	*)
		usage
		;;
esac
shift

LIST_ONLY=0
CHANNEL=
while [ "$#" -gt 0 ]; do
	case "$1" in
		--channel)
			[ -z "$CHANNEL" ] || usage
			[ "$#" -ge 2 ] || usage
			CHANNEL=$2
			case "$CHANNEL" in
				""|[!a-z0-9]*|*[!a-z0-9_-]*)
					usage
					;;
			esac
			shift 2
			;;
		--list)
			[ "$LIST_ONLY" -eq 0 ] || usage
			LIST_ONLY=1
			shift
			;;
		*)
			usage
			;;
	esac
done

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

if [ ! -x "$ROOT_DIR/gradlew" ]; then
    printf 'Gradle wrapper not found or not executable: %s/gradlew\n' "$ROOT_DIR" >&2
    exit 1
fi

find_sdk_tool() {
    TOOL_NAME=$1
    SDK_ROOT=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-"$HOME/Library/Android/sdk"}}
    TOOL_PATH=$(find "$SDK_ROOT/build-tools" -type f -name "$TOOL_NAME" 2>/dev/null | sort -V | tail -n 1)
    if [ -z "$TOOL_PATH" ] || [ ! -x "$TOOL_PATH" ]; then
        printf 'Android SDK tool not found: %s\n' "$TOOL_NAME" >&2
        exit 1
    fi
    printf '%s\n' "$TOOL_PATH"
}

APKSIGNER=$(find_sdk_tool apksigner)
AAPT=$(find_sdk_tool aapt)

# Trusted release certificate fingerprint, independent of the Gradle signing configuration.
TRUSTED_RELEASE_CERT_SHA256='ab3eed20c164f46234154da81d36156698246835249ccb2094c5e5139dee2658'
MAX_APK_SIZE_BYTES=$((100 * 1024 * 1024))

START_TIME=$(date +%s)
if [ -n "$CHANNEL" ]; then
	DEFAULT_OUTPUT_DIR="$ROOT_DIR/build/$CHANNEL-$BUILD_TYPE-apks"
else
	DEFAULT_OUTPUT_DIR="$ROOT_DIR/build/all-$BUILD_TYPE-apks"
fi
OUTPUT_DIR=${OUTPUT_DIR:-"$DEFAULT_OUTPUT_DIR"}
INIT_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/$BUILD_TYPE-variants.XXXXXX")
DISCOVERY_OUTPUT=$(mktemp "${TMPDIR:-/tmp}/$BUILD_TYPE-discovery.XXXXXX")
DISCOVERED_VARIANTS_FILE=$(mktemp "${TMPDIR:-/tmp}/$BUILD_TYPE-discovered-variants.XXXXXX")
VARIANTS_FILE=$(mktemp "${TMPDIR:-/tmp}/$BUILD_TYPE-variants.XXXXXX")
MODULES_FILE=$(mktemp "${TMPDIR:-/tmp}/$BUILD_TYPE-modules.XXXXXX")
APK_LIST=$(mktemp "${TMPDIR:-/tmp}/$BUILD_TYPE-apks.XXXXXX")
SIGNING_REPORT=$(mktemp "${TMPDIR:-/tmp}/$BUILD_TYPE-signing.XXXXXX")

cleanup() {
	rm -f "$INIT_SCRIPT" "$DISCOVERY_OUTPUT" "$DISCOVERED_VARIANTS_FILE" "$VARIANTS_FILE" "$MODULES_FILE" "$APK_LIST" "$SIGNING_REPORT"
}
trap cleanup EXIT HUP INT TERM

cat > "$INIT_SCRIPT" <<'GRADLE'
allprojects { project ->
	project.plugins.withId("com.android.application") {
		def androidComponents = project.extensions.findByName("androidComponents")
		if (androidComponents != null) {
			def buildType = gradle.startParameter.projectProperties["batchBuildType"]
			if (!(buildType in ["debug", "release"])) {
				throw new GradleException("Unsupported batchBuildType: ${buildType}")
			}
			androidComponents.onVariants(androidComponents.selector().withBuildType(buildType)) { variant ->
				def variantName = variant.name
				def channelFlavor = variant.productFlavors.find { flavor -> flavor.first == "CHANNEL" }
				def channelName = channelFlavor != null ? channelFlavor.second : ""
				def taskName = "assemble${variantName.substring(0, 1).toUpperCase()}${variantName.substring(1)}"
				def taskPath = project.path == ":" ? ":${taskName}" : "${project.path}:${taskName}"
				println "__APK_VARIANT__|${taskPath}|${project.projectDir.absolutePath}|${variantName}|${channelName}"
			}
		}
	}
}
GRADLE

if ! ./gradlew -PbatchBuildType="$BUILD_TYPE" -I "$INIT_SCRIPT" help --console=plain -q > "$DISCOVERY_OUTPUT"; then
	printf 'Gradle variant discovery failed for build type: %s\n' "$BUILD_TYPE" >&2
	exit 1
fi

grep '^__APK_VARIANT__|' "$DISCOVERY_OUTPUT" | sort -u > "$DISCOVERED_VARIANTS_FILE" || true

DISCOVERED_TOTAL=$(grep -c '^__APK_VARIANT__|' "$DISCOVERED_VARIANTS_FILE" || true)
if [ "$DISCOVERED_TOTAL" -eq 0 ]; then
	printf 'No enabled %s variants were found in Android application modules.\n' "$BUILD_TYPE" >&2
	exit 1
fi

if [ -n "$CHANNEL" ]; then
	awk -F '|' -v channel="$CHANNEL" '$5 == channel' "$DISCOVERED_VARIANTS_FILE" > "$VARIANTS_FILE"
else
	cp "$DISCOVERED_VARIANTS_FILE" "$VARIANTS_FILE"
fi

TOTAL=$(grep -c '^__APK_VARIANT__|' "$VARIANTS_FILE" || true)
if [ "$TOTAL" -eq 0 ]; then
	printf 'No enabled %s variants were found for channel: %s.\n' "$BUILD_TYPE" "$CHANNEL" >&2
	AVAILABLE_CHANNELS=$(cut -d '|' -f 5 "$DISCOVERED_VARIANTS_FILE" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
	if [ -n "$AVAILABLE_CHANNELS" ]; then
		printf 'Available channels: %s\n' "$AVAILABLE_CHANNELS" >&2
	fi
	exit 1
fi

cut -d '|' -f 3 "$VARIANTS_FILE" | sort -u > "$MODULES_FILE"

if [ "$LIST_ONLY" -eq 1 ]; then
	if [ -n "$CHANNEL" ]; then
		printf 'Discovered %d enabled %s variants for channel %s:\n' "$TOTAL" "$BUILD_TYPE" "$CHANNEL"
	else
		printf 'Discovered %d enabled %s variants:\n' "$TOTAL" "$BUILD_TYPE"
	fi
	cut -d '|' -f 2 "$VARIANTS_FILE"
	exit 0
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# Remove only generated APK outputs so disabled or stale variants are not collected.
while IFS= read -r MODULE_DIR; do
    [ -n "$MODULE_DIR" ] || continue
    rm -rf "$MODULE_DIR/build/outputs/apk"
done < "$MODULES_FILE"

CURRENT=0
while IFS='|' read -r MARKER TASK MODULE_DIR VARIANT_NAME VARIANT_CHANNEL; do
    [ -n "$MARKER" ] || continue

    CURRENT=$((CURRENT + 1))
    printf '\n[%d/%d] Building %s\n' "$CURRENT" "$TOTAL" "$TASK"
    # Separate invocations serialize variants; Gradle may still parallelize this variant's tasks.
    ./gradlew "$TASK"
done < "$VARIANTS_FILE"

while IFS= read -r MODULE_DIR; do
    [ -d "$MODULE_DIR/build/outputs/apk" ] || continue
    find "$MODULE_DIR/build/outputs/apk" -type f -name '*.apk' >> "$APK_LIST"
done < "$MODULES_FILE"

sort -u "$APK_LIST" -o "$APK_LIST"
APK_TOTAL=0
while IFS= read -r APK; do
    [ -n "$APK" ] || continue

    FILE_NAME=$(basename "$APK")
    DESTINATION="$OUTPUT_DIR/$FILE_NAME"
    if [ -e "$DESTINATION" ]; then
        INDEX=2
        BASE_NAME=${FILE_NAME%.apk}
        while [ -e "$OUTPUT_DIR/${BASE_NAME}-${INDEX}.apk" ]; do
            INDEX=$((INDEX + 1))
        done
        DESTINATION="$OUTPUT_DIR/${BASE_NAME}-${INDEX}.apk"
    fi

    cp "$APK" "$DESTINATION"
    APK_TOTAL=$((APK_TOTAL + 1))
done < "$APK_LIST"

if [ "$APK_TOTAL" -eq 0 ]; then
    printf 'Builds succeeded, but no APKs were found in application module outputs.\n' >&2
    exit 1
fi

printf '\nStrictly verifying %d collected APKs.\n' "$APK_TOTAL"
VERIFIED_TOTAL=0
while IFS='|' read -r MARKER TASK MODULE_DIR VARIANT_NAME VARIANT_CHANNEL; do
    [ -n "$MARKER" ] || continue

    METADATA=$(find "$MODULE_DIR/build/outputs/apk" -type f -name output-metadata.json \
        -exec grep -l "\"variantName\"[[:space:]]*:[[:space:]]*\"$VARIANT_NAME\"" {} \;)
    METADATA_TOTAL=$(printf '%s\n' "$METADATA" | grep -c . || true)
    if [ "$METADATA_TOTAL" -ne 1 ]; then
        printf 'Expected exactly one output metadata file for %s, found %d.\n' "$VARIANT_NAME" "$METADATA_TOTAL" >&2
        exit 1
    fi

    EXPECTED_APKS=$(grep -o '"outputFile"[[:space:]]*:[[:space:]]*"[^"]*\.apk"' "$METADATA" \
        | cut -d '"' -f 4)
    EXPECTED_TOTAL=$(printf '%s\n' "$EXPECTED_APKS" | grep -c . || true)
    if [ "$EXPECTED_TOTAL" -eq 0 ]; then
        printf 'No APK outputs declared for %s.\n' "$VARIANT_NAME" >&2
        exit 1
    fi

    while IFS= read -r APK_NAME; do
        [ -n "$APK_NAME" ] || continue
        SOURCE_APK="$(dirname "$METADATA")/$APK_NAME"
        [ -f "$SOURCE_APK" ] || {
            printf 'Declared APK is missing: %s\n' "$SOURCE_APK" >&2
            exit 1
        }

        printf 'Verifying %s\n' "$APK_NAME"
        "$APKSIGNER" verify --verbose --print-certs "$SOURCE_APK" > "$SIGNING_REPORT"
        grep -q '^Verifies$' "$SIGNING_REPORT" || {
            printf 'APK signature verification failed: %s\n' "$SOURCE_APK" >&2
            exit 1
        }
        grep -Eq '^Verified using v[234](\.1)? scheme .*: true$' "$SIGNING_REPORT" || {
            printf 'APK does not use a modern signature scheme: %s\n' "$SOURCE_APK" >&2
            exit 1
        }
        ACTUAL_CERT=$(awk -F': ' '/^Signer #1 certificate SHA-256 digest:/ { value = tolower($2); gsub(/:/, "", value); print value; exit }' "$SIGNING_REPORT")
        SIGNER_TOTAL=$(awk -F': ' '/^Number of signers:/ { print $2; exit }' "$SIGNING_REPORT")
        if [ "$SIGNER_TOTAL" != "1" ]; then
            printf 'Expected exactly one APK signer for %s, found: %s\n' \
                "$SOURCE_APK" "${SIGNER_TOTAL:-unknown}" >&2
            exit 1
        fi
		if [ "$BUILD_TYPE" = "release" ] && { [ -z "$ACTUAL_CERT" ] || [ "$ACTUAL_CERT" != "$TRUSTED_RELEASE_CERT_SHA256" ]; }; then
			printf 'Untrusted signing certificate for %s.\nExpected: %s\nActual:   %s\n' \
				"$SOURCE_APK" "$TRUSTED_RELEASE_CERT_SHA256" "${ACTUAL_CERT:-unavailable}" >&2
			exit 1
		fi

		BADGING=$("$AAPT" dump badging "$SOURCE_APK")
		IS_DEBUGGABLE=0
		if printf '%s\n' "$BADGING" | grep -q "application-debuggable"; then
			IS_DEBUGGABLE=1
		fi
		if [ "$BUILD_TYPE" = "release" ] && [ "$IS_DEBUGGABLE" -eq 1 ]; then
			printf 'Release APK is debuggable: %s\n' "$SOURCE_APK" >&2
			exit 1
		fi
		if [ "$BUILD_TYPE" = "debug" ] && [ "$IS_DEBUGGABLE" -eq 0 ]; then
			printf 'Debug APK is not debuggable: %s\n' "$SOURCE_APK" >&2
			exit 1
		fi
        PACKAGE_NAME=$(printf '%s\n' "$BADGING" | awk -F"'" '/^package: name=/{ print $2; exit }')
        VERSION_CODE=$(printf '%s\n' "$BADGING" | awk -F"'" '/^package: name=/{ print $4; exit }')
        if [ -z "$PACKAGE_NAME" ] || [ -z "$VERSION_CODE" ]; then
            printf 'Could not read package identity from %s.\n' "$SOURCE_APK" >&2
            exit 1
        fi

        APK_SIZE_BYTES=$(wc -c < "$SOURCE_APK" | tr -d '[:space:]')
        if [ "$APK_SIZE_BYTES" -gt "$MAX_APK_SIZE_BYTES" ]; then
            printf 'APK exceeds the 100 MB size limit: %s (%d bytes).\n' \
                "$SOURCE_APK" "$APK_SIZE_BYTES" >&2
            exit 1
        fi

        COLLECTED_MATCHES=0
        for COLLECTED_APK in "$OUTPUT_DIR"/*.apk; do
            [ -f "$COLLECTED_APK" ] || continue
            if cmp -s "$SOURCE_APK" "$COLLECTED_APK"; then
                COLLECTED_MATCHES=$((COLLECTED_MATCHES + 1))
            fi
        done
        if [ "$COLLECTED_MATCHES" -ne 1 ]; then
            printf 'Expected exactly one identical collected copy of %s, found %d.\n' \
                "$APK_NAME" "$COLLECTED_MATCHES" >&2
            exit 1
        fi

        VERIFIED_TOTAL=$((VERIFIED_TOTAL + 1))
    done <<EOF
$EXPECTED_APKS
EOF
done < "$VARIANTS_FILE"

if [ "$VERIFIED_TOTAL" -ne "$APK_TOTAL" ]; then
    printf 'Verified APK count (%d) differs from collected count (%d).\n' "$VERIFIED_TOTAL" "$APK_TOTAL" >&2
    exit 1
fi

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
HOURS=$((ELAPSED / 3600))
MINUTES=$(((ELAPSED % 3600) / 60))
SECONDS=$((ELAPSED % 60))

if [ -n "$CHANNEL" ]; then
	printf '\nBuilt %d %s variants for channel %s, collected and strictly verified %d APKs.\n' \
		"$TOTAL" "$BUILD_TYPE" "$CHANNEL" "$APK_TOTAL"
else
	printf '\nBuilt %d %s variants, collected and strictly verified %d APKs.\n' "$TOTAL" "$BUILD_TYPE" "$APK_TOTAL"
fi
printf 'Output directory: %s\n' "$OUTPUT_DIR"
printf 'Total time: %02d:%02d:%02d\n' "$HOURS" "$MINUTES" "$SECONDS"
