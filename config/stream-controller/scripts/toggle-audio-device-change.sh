#!/usr/bin/env bash

# List of allowed output and corresponding input devices
ALLOWED_DEVICES=(
    "alsa_output.usb-SteelSeries_Arctis_Nova_7-00.analog-stereo,alsa_input.usb-SteelSeries_Arctis_Nova_7-00.mono-fallback"
    "alsa_output.usb-ACTIONS_Pebble_V3-00.analog-stereo,alsa_input.usb-046d_Logitech_Webcam_C925e_DE3975BF-02.analog-stereo"
)


get_current_output_device() {
    pactl info | grep "Default Sink" | awk '{print $3}'
}

get_current_input_device() {
    pactl info | grep "Default Source" | awk '{print $3}'
}

set_output_device() {
    local device=$1
    if pactl set-default-sink "$device"; then
        echo "Output device switched to: $device"
    else
        echo "Error setting output device: $device" >&2
    fi
}

set_input_device() {
    local device=$1
    if pactl set-default-source "$device"; then
        echo "Input device switched to: $device"
    else
        echo "Error setting input device: $device" >&2
    fi
}

switch_devices() {
    local current_output_device=$(get_current_output_device)
    local current_input_device=$(get_current_input_device)

    # Iterate through the allowed devices and match output/input pair
    for device_pair in "${ALLOWED_DEVICES[@]}"; do
        IFS=',' read -r output_device input_device <<< "$device_pair"
        
        # Switch to the corresponding output/input pair if matched
        if [[ "$current_output_device" != "$output_device" ]]; then
            set_output_device "$output_device"
            set_input_device "$input_device"
            return
        fi
    done

    echo "No matching output/input device pair found for switching."
}

main() {
    echo "Current default output device: $(get_current_output_device)"
    echo "Current default input device: $(get_current_input_device)"
    switch_devices
}

main