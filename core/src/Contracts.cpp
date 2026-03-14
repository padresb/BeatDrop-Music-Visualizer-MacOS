#include "beatdrop/core/Contracts.h"

namespace beatdrop::core {

std::string_view to_string(AudioInputMode mode) {
    switch (mode) {
    case AudioInputMode::system_output:
        return "system output";
    case AudioInputMode::microphone:
        return "microphone";
    }

    return "system output";
}

std::string_view to_string(CapturePermissionState state) {
    switch (state) {
    case CapturePermissionState::not_required:
        return "not required";
    case CapturePermissionState::not_determined:
        return "not determined";
    case CapturePermissionState::restricted:
        return "restricted";
    case CapturePermissionState::denied:
        return "denied";
    case CapturePermissionState::granted:
        return "granted";
    case CapturePermissionState::unknown:
        return "unknown";
    }

    return "unknown";
}

} // namespace beatdrop::core
