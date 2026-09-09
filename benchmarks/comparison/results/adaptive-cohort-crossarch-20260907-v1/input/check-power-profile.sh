#!/bin/sh

# Apple documents Automatic, Low Power, and High Power as the selectable macOS
# energy modes: https://support.apple.com/101613
detect_macos() {
    if ! command -v pmset >/dev/null 2>&1; then
        emit_result macos pmset unknown unknown unknown
        return 2
    fi

    power_source=$(
        LC_ALL=C pmset -g batt 2>/dev/null |
            awk -F "'" '/^Now drawing from / { print $2; exit }'
    )

    case "$power_source" in
        "AC Power" | "Battery Power" | "UPS Power") ;;
        *)
            emit_result macos pmset unknown unknown unknown
            return 2
            ;;
    esac

    # Current macOS releases encode Automatic, Low Power, and High Power as
    # powermode 0, 1, and 2. Older releases expose separate lowpowermode and
    # highpowermode booleans, so retain that representation as a fallback.
    profile=$(
        LC_ALL=C pmset -g custom 2>/dev/null |
            awk -v wanted="$power_source" '
                /^(AC|Battery|UPS) Power:$/ {
                    source = $0
                    sub(/:$/, "", source)
                    next
                }

                source == wanted && $1 == "powermode" {
                    power_mode = $2
                }
                source == wanted && $1 == "lowpowermode" {
                    low_power_mode = $2
                    saw_low_power_mode = 1
                }
                source == wanted && $1 == "highpowermode" {
                    high_power_mode = $2
                    saw_high_power_mode = 1
                }

                END {
                    if (power_mode != "") {
                        if (power_mode == "0")
                            print "automatic"
                        else if (power_mode == "1")
                            print "low-power"
                        else if (power_mode == "2")
                            print "high-power"
                        else
                            print "unknown"
                    } else if ((saw_low_power_mode && low_power_mode !~ /^[01]$/) ||
                               (saw_high_power_mode && high_power_mode !~ /^[01]$/)) {
                        print "unknown"
                    } else if (low_power_mode == "1" && high_power_mode != "1") {
                        print "low-power"
                    } else if (high_power_mode == "1" && low_power_mode != "1") {
                        print "high-power"
                    } else if ((saw_low_power_mode || saw_high_power_mode) &&
                               low_power_mode != "1" && high_power_mode != "1") {
                        print "automatic"
                    } else {
                        print "unknown"
                    }
                }
            '
    )

    if [ -z "$profile" ]; then
        emit_result macos pmset unknown unknown "$power_source"
        return 2
    fi

    case "$profile" in
        low-power)
            emit_result macos pmset "$profile" true "$power_source"
            return 10
            ;;
        automatic | high-power)
            emit_result macos pmset "$profile" false "$power_source"
            return 0
            ;;
        *)
            emit_result macos pmset unknown unknown "$power_source"
            return 2
            ;;
    esac
}

# powerprofilesctl documents `get` as printing the active profile:
# https://gitlab.freedesktop.org/upower/power-profiles-daemon
# The fallback values are standardized by the Linux sysfs ABI:
# https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-platform_profile
detect_linux() {
    profile=
    detector=

    if command -v powerprofilesctl >/dev/null 2>&1; then
        profile=$(powerprofilesctl get 2>/dev/null | awk 'NF { print $1; exit }')
        if [ -n "$profile" ]; then
            detector=powerprofilesctl
        fi
    fi

    if [ -z "$profile" ] && [ -r /sys/firmware/acpi/platform_profile ]; then
        profile=$(awk 'NF { print $1; exit }' /sys/firmware/acpi/platform_profile)
        if [ -n "$profile" ]; then
            detector=platform_profile
        fi
    fi

    if [ -z "$profile" ]; then
        emit_result linux unavailable unknown unknown unknown
        return 2
    fi

    case "$profile" in
        power-saver | low-power | cool | quiet)
            emit_result linux "$detector" "$profile" true unknown
            return 10
            ;;
        balanced | balanced-performance | performance)
            emit_result linux "$detector" "$profile" false unknown
            return 0
            ;;
        *)
            emit_result linux "$detector" "$profile" unknown unknown
            return 2
            ;;
    esac
}

emit_result() {
    printf 'os=%s\ndetector=%s\nprofile=%s\nreduced_performance=%s\npower_source=%s\n' \
        "$1" "$2" "$3" "$4" "$5"
}

case "$(uname -s 2>/dev/null)" in
    Darwin)
        detect_macos
        exit $?
        ;;
    Linux)
        detect_linux
        exit $?
        ;;
    *)
        emit_result unsupported unavailable unknown unknown unknown
        exit 2
        ;;
esac
