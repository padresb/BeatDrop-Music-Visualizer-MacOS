#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include "MacAudioCaptureService.h"
#include "beatdrop/core/AudioRingBuffer.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

namespace beatdrop::macos {
class SystemAudioCaptureStream;
}

@interface BeatDropSystemAudioStreamOutput : NSObject <SCStreamOutput, SCStreamDelegate>
- (instancetype)initWithOwner:(beatdrop::macos::SystemAudioCaptureStream*)owner;
@end

namespace beatdrop::macos {
namespace {

constexpr double kTargetSampleRate = 44100.0;
constexpr int64_t kAsyncTimeoutSeconds = 10;

std::string NsStringToStd(NSString* value) {
    if (value == nil) {
        return {};
    }

    const char* utf8 = [value UTF8String];
    return utf8 == nullptr ? std::string() : std::string(utf8);
}

std::string DescribeError(NSError* error) {
    if (error == nil) {
        return "unknown error";
    }

    return NsStringToStd([error localizedDescription]);
}

std::string DescribeOsStatus(OSStatus status) {
    return std::to_string(static_cast<int>(status));
}

dispatch_time_t AsyncTimeout() {
    return dispatch_time(DISPATCH_TIME_NOW, kAsyncTimeoutSeconds * NSEC_PER_SEC);
}

std::string CopyStringProperty(AudioObjectID object_id, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };

    CFStringRef value = nullptr;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(object_id, &address, 0, nullptr, &size, &value) != noErr || value == nullptr) {
        return {};
    }

    std::string result = NsStringToStd((__bridge NSString*)value);
    CFRelease(value);
    return result;
}

std::vector<AudioObjectID> ListAllAudioDevices() {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };

    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) != noErr || size == 0) {
        return {};
    }

    std::vector<AudioObjectID> devices(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, devices.data()) != noErr) {
        return {};
    }

    return devices;
}

AudioObjectID DefaultDevice(AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };

    AudioObjectID device_id = kAudioObjectUnknown;
    UInt32 size = sizeof(device_id);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device_id) != noErr) {
        return kAudioObjectUnknown;
    }

    return device_id;
}

bool DeviceHasChannels(AudioObjectID device_id, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        scope,
        kAudioObjectPropertyElementMain,
    };

    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device_id, &address, 0, nullptr, &size) != noErr || size == 0) {
        return false;
    }

    auto storage = std::make_unique<std::byte[]>(size);
    auto* buffers = reinterpret_cast<AudioBufferList*>(storage.get());
    if (AudioObjectGetPropertyData(device_id, &address, 0, nullptr, &size, buffers) != noErr) {
        return false;
    }

    UInt32 channel_count = 0;
    for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) {
        channel_count += buffers->mBuffers[index].mNumberChannels;
    }

    return channel_count > 0;
}

std::vector<core::AudioDeviceDescriptor> EnumerateDevices(
    AudioObjectPropertyScope scope,
    AudioObjectPropertySelector default_selector) {
    const AudioObjectID default_device_id = DefaultDevice(default_selector);
    std::vector<core::AudioDeviceDescriptor> devices;

    for (const AudioObjectID device_id : ListAllAudioDevices()) {
        if (!DeviceHasChannels(device_id, scope)) {
            continue;
        }

        core::AudioDeviceDescriptor descriptor;
        descriptor.id = CopyStringProperty(device_id, kAudioDevicePropertyDeviceUID);
        descriptor.name = CopyStringProperty(device_id, kAudioObjectPropertyName);
        descriptor.is_default = device_id == default_device_id;

        if (descriptor.id.empty()) {
            descriptor.id = std::to_string(device_id);
        }

        if (descriptor.name.empty()) {
            descriptor.name = "Unnamed audio device";
        }

        devices.push_back(std::move(descriptor));
    }

    return devices;
}

bool ContainsDeviceId(const std::vector<core::AudioDeviceDescriptor>& devices, const std::string& device_id) {
    return std::any_of(devices.begin(), devices.end(), [&](const core::AudioDeviceDescriptor& device) {
        return device.id == device_id;
    });
}

std::string DefaultDeviceSummary(const std::vector<core::AudioDeviceDescriptor>& devices) {
    for (const auto& device : devices) {
        if (device.is_default) {
            return device.name;
        }
    }

    return devices.empty() ? std::string("none") : devices.front().name;
}

core::CapturePermissionState MicrophonePermissionState() {
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
    case AVAuthorizationStatusNotDetermined:
        return core::CapturePermissionState::not_determined;
    case AVAuthorizationStatusRestricted:
        return core::CapturePermissionState::restricted;
    case AVAuthorizationStatusDenied:
        return core::CapturePermissionState::denied;
    case AVAuthorizationStatusAuthorized:
        return core::CapturePermissionState::granted;
    }

    return core::CapturePermissionState::unknown;
}

core::CapturePermissionState RequestMicrophonePermissionIfNeeded() {
    const core::CapturePermissionState current_state = MicrophonePermissionState();
    if (current_state != core::CapturePermissionState::not_determined) {
        return current_state;
    }

    __block BOOL granted = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL accessGranted) {
                                 granted = accessGranted;
                                 dispatch_semaphore_signal(semaphore);
                             }];
    (void)dispatch_semaphore_wait(semaphore, AsyncTimeout());

    return granted ? core::CapturePermissionState::granted : MicrophonePermissionState();
}

core::CapturePermissionState ScreenRecordingPermissionState() {
    return CGPreflightScreenCaptureAccess()
        ? core::CapturePermissionState::granted
        : core::CapturePermissionState::denied;
}

bool SupportsCoreAudioProcessTap() {
    NSOperatingSystemVersion version = {14, 4, 0};
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:version];
}

bool SupportsScreenCaptureKitAudio() {
    NSOperatingSystemVersion version = {13, 0, 0};
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:version];
}

bool NeedsConversion(AVAudioFormat* format, const core::AudioStreamFormat& target_format) {
    if (format == nil) {
        return true;
    }

    if ([format commonFormat] != AVAudioPCMFormatFloat32) {
        return true;
    }

    if ([[format channelLayout] layoutTag] != kAudioChannelLayoutTag_Stereo && [format channelCount] != 2) {
        return true;
    }

    return std::fabs([format sampleRate] - static_cast<double>(target_format.sample_rate_hz)) >= 0.5;
}

void CopyBufferIntoStereoInterleaved(AVAudioPCMBuffer* buffer, std::vector<float>& destination) {
    destination.clear();
    if (buffer == nil || [buffer frameLength] == 0) {
        return;
    }

    float* const* channels = [buffer floatChannelData];
    if (channels == nullptr) {
        return;
    }

    const AVAudioFrameCount frame_count = [buffer frameLength];
    const AVAudioChannelCount channel_count = [[buffer format] channelCount];
    const NSUInteger stride = [buffer stride];

    destination.resize(static_cast<std::size_t>(frame_count) * 2, 0.0F);

    if ([[buffer format] isInterleaved]) {
        const float* interleaved = channels[0];
        if (interleaved == nullptr) {
            destination.clear();
            return;
        }

        for (AVAudioFrameCount frame_index = 0; frame_index < frame_count; ++frame_index) {
            const std::size_t source_index = static_cast<std::size_t>(frame_index) * stride;
            const std::size_t destination_index = static_cast<std::size_t>(frame_index) * 2;
            const float left = interleaved[source_index];
            const float right = channel_count > 1 ? interleaved[source_index + 1] : left;
            destination[destination_index] = left;
            destination[destination_index + 1] = right;
        }

        return;
    }

    const float* left_channel = channels[0];
    const float* right_channel = channel_count > 1 ? channels[1] : channels[0];
    if (left_channel == nullptr || right_channel == nullptr) {
        destination.clear();
        return;
    }

    for (AVAudioFrameCount frame_index = 0; frame_index < frame_count; ++frame_index) {
        const std::size_t source_index = static_cast<std::size_t>(frame_index) * stride;
        const std::size_t destination_index = static_cast<std::size_t>(frame_index) * 2;
        destination[destination_index] = left_channel[source_index];
        destination[destination_index + 1] = right_channel[source_index];
    }
}

float DecodePcmSample(const std::uint8_t* data, std::uint32_t bits_per_channel, bool is_float) {
    if (data == nullptr) {
        return 0.0F;
    }

    if (is_float) {
        switch (bits_per_channel) {
        case 32:
            return *reinterpret_cast<const float*>(data);
        case 64:
            return static_cast<float>(*reinterpret_cast<const double*>(data));
        default:
            return 0.0F;
        }
    }

    switch (bits_per_channel) {
    case 16:
        return static_cast<float>(*reinterpret_cast<const std::int16_t*>(data)) / 32768.0F;
    case 24: {
        std::int32_t value = static_cast<std::int32_t>(data[0]) |
            (static_cast<std::int32_t>(data[1]) << 8) |
            (static_cast<std::int32_t>(data[2]) << 16);
        if ((value & 0x00800000) != 0) {
            value |= ~0x00FFFFFF;
        }
        return static_cast<float>(value) / 8388608.0F;
    }
    case 32:
        return static_cast<float>(*reinterpret_cast<const std::int32_t*>(data)) / 2147483648.0F;
    default:
        return 0.0F;
    }
}

bool CopyLinearPcmAudioBufferListToStereoInterleaved(
    const AudioBufferList* buffer_list,
    const AudioStreamBasicDescription& format,
    std::size_t frame_count,
    std::vector<float>& destination) {
    destination.clear();
    if (buffer_list == nullptr || frame_count == 0 || format.mChannelsPerFrame == 0 || format.mFormatID != kAudioFormatLinearPCM) {
        return false;
    }

    const bool is_float = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool is_signed = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    const bool is_non_interleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if (!is_float && !is_signed) {
        return false;
    }

    if (format.mBitsPerChannel == 0 || format.mBitsPerChannel % 8 != 0 || format.mBytesPerFrame == 0) {
        return false;
    }

    const std::size_t sample_size = format.mBitsPerChannel / 8;
    destination.resize(frame_count * 2, 0.0F);

    for (std::size_t frame_index = 0; frame_index < frame_count; ++frame_index) {
        float left = 0.0F;
        float right = 0.0F;

        if (is_non_interleaved) {
            const UInt32 left_buffer_index = 0;
            const UInt32 right_buffer_index = format.mChannelsPerFrame > 1 ? std::min<UInt32>(1, buffer_list->mNumberBuffers - 1) : left_buffer_index;
            const auto& left_buffer = buffer_list->mBuffers[left_buffer_index];
            const auto& right_buffer = buffer_list->mBuffers[right_buffer_index];

            const auto* left_bytes = static_cast<const std::uint8_t*>(left_buffer.mData);
            const auto* right_bytes = static_cast<const std::uint8_t*>(right_buffer.mData);
            if (left_bytes == nullptr || right_bytes == nullptr) {
                destination.clear();
                return false;
            }

            left = DecodePcmSample(left_bytes + frame_index * format.mBytesPerFrame, format.mBitsPerChannel, is_float);
            right = DecodePcmSample(right_bytes + frame_index * format.mBytesPerFrame, format.mBitsPerChannel, is_float);
        } else {
            if (buffer_list->mNumberBuffers == 0 || buffer_list->mBuffers[0].mData == nullptr) {
                destination.clear();
                return false;
            }

            const auto* bytes = static_cast<const std::uint8_t*>(buffer_list->mBuffers[0].mData);
            const std::size_t frame_offset = frame_index * format.mBytesPerFrame;
            left = DecodePcmSample(bytes + frame_offset, format.mBitsPerChannel, is_float);
            right = format.mChannelsPerFrame > 1
                ? DecodePcmSample(bytes + frame_offset + sample_size, format.mBitsPerChannel, is_float)
                : left;
        }

        destination[frame_index * 2] = left;
        destination[frame_index * 2 + 1] = right;
    }

    return true;
}

SCDisplay* SelectCaptureDisplay(SCShareableContent* shareable_content) {
    if (shareable_content == nil || [shareable_content displays].count == 0) {
        return nil;
    }

    const CGDirectDisplayID main_display_id = CGMainDisplayID();
    for (SCDisplay* display in [shareable_content displays]) {
        if ([display displayID] == main_display_id) {
            return display;
        }
    }

    return [shareable_content displays].firstObject;
}

class MicrophoneCaptureStream {
public:
    explicit MicrophoneCaptureStream(core::AudioStreamFormat target_stream_format)
        : target_stream_format_(target_stream_format) {}

    ~MicrophoneCaptureStream() {
        Stop();
    }

    bool Start(core::AudioRingBuffer& ring_buffer) {
        Stop();
        SetLastError({});

        if (RequestMicrophonePermissionIfNeeded() != core::CapturePermissionState::granted) {
            SetLastError("Microphone permission is not granted.");
            return false;
        }

        AVAudioEngine* engine = [[AVAudioEngine alloc] init];
        AVAudioInputNode* input = [engine inputNode];
        if (input == nil) {
            SetLastError("AVAudioEngine did not expose an input node.");
            return false;
        }

        AVAudioFormat* input_format = [input outputFormatForBus:0];
        if (input_format == nil || [input_format channelCount] == 0) {
            SetLastError("The default microphone device did not provide a usable stream format.");
            return false;
        }

        AVAudioFormat* target_format = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatFloat32
                       sampleRate:static_cast<double>(target_stream_format_.sample_rate_hz)
                         channels:static_cast<AVAudioChannelCount>(target_stream_format_.channel_count)
                      interleaved:YES];
        if (target_format == nil) {
            SetLastError("Unable to allocate the internal microphone stream format.");
            return false;
        }

        AVAudioConverter* converter = nil;
        if (NeedsConversion(input_format, target_stream_format_)) {
            converter = [[AVAudioConverter alloc] initFromFormat:input_format toFormat:target_format];
            if (converter == nil) {
                SetLastError("Unable to create the microphone resampler.");
                return false;
            }

            [converter setPrimeMethod:AVAudioConverterPrimeMethod_None];
        }

        ring_buffer.clear();
        [input installTapOnBus:0
                    bufferSize:2048
                        format:input_format
                         block:^(AVAudioPCMBuffer* buffer, AVAudioTime* when) {
                             (void)when;
                             this->HandleBuffer(buffer);
                         }];

        {
            std::lock_guard<std::mutex> lock(mutex_);
            ring_buffer_ = &ring_buffer;
            engine_ = engine;
            converter_ = converter;
            target_format_ = target_format;
            scratch_buffer_ = nil;
            interleaved_scratch_.clear();
            running_ = false;
        }

        [engine prepare];

        NSError* error = nil;
        if (![engine startAndReturnError:&error]) {
            [input removeTapOnBus:0];
            [engine stop];

            {
                std::lock_guard<std::mutex> lock(mutex_);
                engine_ = nil;
                converter_ = nil;
                target_format_ = nil;
                scratch_buffer_ = nil;
                ring_buffer_ = nullptr;
                interleaved_scratch_.clear();
            }

            SetLastError("Unable to start microphone capture: " + DescribeError(error));
            return false;
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            running_ = true;
        }

        return true;
    }

    void Stop() {
        AVAudioEngine* engine = nil;
        AVAudioInputNode* input = nil;
        core::AudioRingBuffer* ring_buffer = nullptr;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            running_ = false;
            engine = engine_;
            input = engine == nil ? nil : [engine inputNode];
            ring_buffer = ring_buffer_;
        }

        if (input != nil) {
            [input removeTapOnBus:0];
        }

        if (engine != nil) {
            [engine stop];
        }

        if (ring_buffer != nullptr) {
            ring_buffer->clear();
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            engine_ = nil;
            converter_ = nil;
            target_format_ = nil;
            scratch_buffer_ = nil;
            ring_buffer_ = nullptr;
            interleaved_scratch_.clear();
        }
    }

    bool IsRunning() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return running_;
    }

    std::string LastError() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return last_error_;
    }

private:
    void HandleBuffer(AVAudioPCMBuffer* buffer) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_ || ring_buffer_ == nullptr || buffer == nil || [buffer frameLength] == 0) {
            return;
        }

        AVAudioPCMBuffer* output_buffer = buffer;
        if (converter_ != nil) {
            const double source_rate = std::max([[buffer format] sampleRate], 1.0);
            const double target_rate = target_format_ == nil ? source_rate : [target_format_ sampleRate];
            const double rate_ratio = target_rate / source_rate;
            const AVAudioFrameCount capacity = std::max<AVAudioFrameCount>(
                static_cast<AVAudioFrameCount>(std::ceil(static_cast<double>([buffer frameLength]) * rate_ratio) + 64.0),
                1);

            if (scratch_buffer_ == nil || [scratch_buffer_ frameCapacity] < capacity) {
                scratch_buffer_ = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target_format_ frameCapacity:capacity];
                if (scratch_buffer_ == nil) {
                    last_error_ = "Failed to allocate the microphone conversion buffer.";
                    return;
                }
            }

            [scratch_buffer_ setFrameLength:0];

            NSError* error = nil;
            if (![converter_ convertToBuffer:scratch_buffer_ fromBuffer:buffer error:&error]) {
                last_error_ = "Unable to convert microphone audio to stereo PCM: " + DescribeError(error);
                return;
            }

            output_buffer = scratch_buffer_;
        }

        CopyBufferIntoStereoInterleaved(output_buffer, interleaved_scratch_);
        if (interleaved_scratch_.empty()) {
            return;
        }

        ring_buffer_->push_interleaved_stereo(
            interleaved_scratch_.data(),
            interleaved_scratch_.size() / 2);
    }

    void SetLastError(std::string error) {
        std::lock_guard<std::mutex> lock(mutex_);
        last_error_ = std::move(error);
    }

    core::AudioStreamFormat target_stream_format_;
    mutable std::mutex mutex_;
    core::AudioRingBuffer* ring_buffer_ = nullptr;
    AVAudioEngine* __strong engine_ = nil;
    AVAudioConverter* __strong converter_ = nil;
    AVAudioFormat* __strong target_format_ = nil;
    AVAudioPCMBuffer* __strong scratch_buffer_ = nil;
    std::vector<float> interleaved_scratch_;
    bool running_ = false;
    std::string last_error_;
};

} // namespace

class SystemAudioCaptureStream {
public:
    explicit SystemAudioCaptureStream(core::AudioStreamFormat target_stream_format)
        : target_stream_format_(target_stream_format) {}

    ~SystemAudioCaptureStream() {
        Stop();
    }

    bool Start(core::AudioRingBuffer& ring_buffer) {
        Stop();
        SetLastError({});

        if (!SupportsScreenCaptureKitAudio()) {
            SetLastError("System-output capture requires ScreenCaptureKit on macOS 13 or newer.");
            return false;
        }

        if (ScreenRecordingPermissionState() != core::CapturePermissionState::granted) {
            SetLastError("Screen Recording permission is required for system-output capture.");
            return false;
        }

        __block SCShareableContent* shareable_content = nil;
        __block NSError* shareable_error = nil;
        dispatch_semaphore_t shareable_semaphore = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                  onScreenWindowsOnly:NO
                                                    completionHandler:^(SCShareableContent* content, NSError* error) {
                                                        shareable_content = content;
                                                        shareable_error = error;
                                                        dispatch_semaphore_signal(shareable_semaphore);
                                                    }];

        if (dispatch_semaphore_wait(shareable_semaphore, AsyncTimeout()) != 0) {
            SetLastError("Timed out while enumerating ScreenCaptureKit content.");
            return false;
        }

        if (shareable_error != nil) {
            SetLastError("Unable to enumerate ScreenCaptureKit content: " + DescribeError(shareable_error));
            return false;
        }

        SCDisplay* display = SelectCaptureDisplay(shareable_content);
        if (display == nil) {
            SetLastError("ScreenCaptureKit did not expose a display to capture.");
            return false;
        }

        SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        SCStreamConfiguration* configuration = [[SCStreamConfiguration alloc] init];
        [configuration setWidth:2];
        [configuration setHeight:2];
        [configuration setMinimumFrameInterval:CMTimeMake(1, 5)];
        [configuration setShowsCursor:NO];
        [configuration setQueueDepth:3];
        [configuration setCapturesAudio:YES];
        [configuration setSampleRate:static_cast<NSInteger>(target_stream_format_.sample_rate_hz)];
        [configuration setChannelCount:static_cast<NSInteger>(target_stream_format_.channel_count)];
        [configuration setExcludesCurrentProcessAudio:NO];

        if (@available(macOS 14.0, *)) {
            [configuration setPresenterOverlayPrivacyAlertSetting:SCPresenterOverlayAlertSettingNever];
        }

        BeatDropSystemAudioStreamOutput* output = [[BeatDropSystemAudioStreamOutput alloc] initWithOwner:this];
        dispatch_queue_t sample_queue = dispatch_queue_create("com.beatdrop.systemaudio.capture", DISPATCH_QUEUE_SERIAL);
        SCStream* stream = [[SCStream alloc] initWithFilter:filter configuration:configuration delegate:output];

        NSError* add_output_error = nil;
        if (![stream addStreamOutput:output
                                type:SCStreamOutputTypeAudio
                  sampleHandlerQueue:sample_queue
                               error:&add_output_error]) {
            SetLastError("Unable to attach the ScreenCaptureKit audio output: " + DescribeError(add_output_error));
            return false;
        }

        ring_buffer.clear();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ring_buffer_ = &ring_buffer;
            stream_ = stream;
            output_ = output;
            sample_queue_ = sample_queue;
            buffer_list_storage_.clear();
            interleaved_scratch_.clear();
            running_ = false;
        }

        __block NSError* start_error = nil;
        dispatch_semaphore_t start_semaphore = dispatch_semaphore_create(0);
        [stream startCaptureWithCompletionHandler:^(NSError* error) {
            start_error = error;
            dispatch_semaphore_signal(start_semaphore);
        }];

        if (dispatch_semaphore_wait(start_semaphore, AsyncTimeout()) != 0) {
            [stream stopCaptureWithCompletionHandler:nil];
            NSError* remove_error = nil;
            [stream removeStreamOutput:output type:SCStreamOutputTypeAudio error:&remove_error];
            {
                std::lock_guard<std::mutex> lock(mutex_);
                stream_ = nil;
                output_ = nil;
                sample_queue_ = nil;
                ring_buffer_ = nullptr;
            }
            SetLastError("Timed out while starting ScreenCaptureKit system-output capture.");
            return false;
        }

        if (start_error != nil) {
            [stream stopCaptureWithCompletionHandler:nil];
            NSError* remove_error = nil;
            [stream removeStreamOutput:output type:SCStreamOutputTypeAudio error:&remove_error];
            {
                std::lock_guard<std::mutex> lock(mutex_);
                stream_ = nil;
                output_ = nil;
                sample_queue_ = nil;
                ring_buffer_ = nullptr;
            }
            SetLastError("Unable to start ScreenCaptureKit system-output capture: " + DescribeError(start_error));
            return false;
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            running_ = true;
        }

        return true;
    }

    void Stop() {
        SCStream* stream = nil;
        BeatDropSystemAudioStreamOutput* output = nil;
        core::AudioRingBuffer* ring_buffer = nullptr;

        {
            std::lock_guard<std::mutex> lock(mutex_);
            running_ = false;
            stream = stream_;
            output = output_;
            ring_buffer = ring_buffer_;
        }

        if (stream != nil) {
            dispatch_semaphore_t stop_semaphore = dispatch_semaphore_create(0);
            [stream stopCaptureWithCompletionHandler:^(NSError* error) {
                (void)error;
                dispatch_semaphore_signal(stop_semaphore);
            }];
            dispatch_semaphore_wait(stop_semaphore, AsyncTimeout());

            NSError* remove_error = nil;
            if (output != nil) {
                [stream removeStreamOutput:output type:SCStreamOutputTypeAudio error:&remove_error];
            }

            if (remove_error != nil) {
                SetLastError("ScreenCaptureKit removed the system-output stream with an error: " + DescribeError(remove_error));
            }
        }

        if (ring_buffer != nullptr) {
            ring_buffer->clear();
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            stream_ = nil;
            output_ = nil;
            sample_queue_ = nil;
            ring_buffer_ = nullptr;
            buffer_list_storage_.clear();
            interleaved_scratch_.clear();
        }
    }

    bool IsRunning() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return running_;
    }

    std::string LastError() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return last_error_;
    }

    void HandleSampleBuffer(CMSampleBufferRef sample_buffer, SCStreamOutputType type) {
        if (type != SCStreamOutputTypeAudio || sample_buffer == nullptr || !CMSampleBufferDataIsReady(sample_buffer)) {
            return;
        }

        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_ || ring_buffer_ == nullptr) {
            return;
        }

        CMFormatDescriptionRef format_description = CMSampleBufferGetFormatDescription(sample_buffer);
        if (format_description == nullptr) {
            last_error_ = "ScreenCaptureKit system-output capture produced a sample buffer without a format description.";
            return;
        }

        const auto* stream_description = CMAudioFormatDescriptionGetStreamBasicDescription(
            static_cast<CMAudioFormatDescriptionRef>(format_description));
        if (stream_description == nullptr) {
            last_error_ = "ScreenCaptureKit system-output capture did not provide a valid audio stream description.";
            return;
        }

        std::size_t audio_buffer_list_size = 0;
        OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample_buffer,
            &audio_buffer_list_size,
            nullptr,
            0,
            kCFAllocatorDefault,
            kCFAllocatorDefault,
            0,
            nullptr);
        if (status != noErr || audio_buffer_list_size == 0) {
            last_error_ = "Unable to query the ScreenCaptureKit audio buffer list: OSStatus " + DescribeOsStatus(status);
            return;
        }

        buffer_list_storage_.resize(audio_buffer_list_size);
        auto* audio_buffer_list = reinterpret_cast<AudioBufferList*>(buffer_list_storage_.data());
        CMBlockBufferRef block_buffer = nullptr;

        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample_buffer,
            &audio_buffer_list_size,
            audio_buffer_list,
            audio_buffer_list_size,
            kCFAllocatorDefault,
            kCFAllocatorDefault,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            &block_buffer);
        if (status != noErr) {
            last_error_ = "Unable to read the ScreenCaptureKit audio buffer list: OSStatus " + DescribeOsStatus(status);
            if (block_buffer != nullptr) {
                CFRelease(block_buffer);
            }
            return;
        }

        const std::size_t frame_count = static_cast<std::size_t>(CMSampleBufferGetNumSamples(sample_buffer));
        const bool copied = CopyLinearPcmAudioBufferListToStereoInterleaved(
            audio_buffer_list,
            *stream_description,
            frame_count,
            interleaved_scratch_);

        if (block_buffer != nullptr) {
            CFRelease(block_buffer);
        }

        if (!copied) {
            last_error_ = "Unsupported ScreenCaptureKit audio format for system-output capture.";
            return;
        }

        if (!interleaved_scratch_.empty()) {
            ring_buffer_->push_interleaved_stereo(
                interleaved_scratch_.data(),
                interleaved_scratch_.size() / 2);
        }
    }

    void HandleStop(NSError* error) {
        std::lock_guard<std::mutex> lock(mutex_);
        running_ = false;
        if (error != nil) {
            last_error_ = "ScreenCaptureKit stopped system-output capture: " + DescribeError(error);
        }
    }

private:
    void SetLastError(std::string error) {
        std::lock_guard<std::mutex> lock(mutex_);
        last_error_ = std::move(error);
    }

    core::AudioStreamFormat target_stream_format_;
    mutable std::mutex mutex_;
    core::AudioRingBuffer* ring_buffer_ = nullptr;
    SCStream* __strong stream_ = nil;
    BeatDropSystemAudioStreamOutput* __strong output_ = nil;
    dispatch_queue_t __strong sample_queue_ = nil;
    std::vector<std::byte> buffer_list_storage_;
    std::vector<float> interleaved_scratch_;
    bool running_ = false;
    std::string last_error_;
};

namespace {

core::AudioModeInfo BuildSystemOutputMode(
    const SystemAudioCaptureStream& stream,
    const core::AudioRingBuffer& ring_buffer) {
    core::AudioModeInfo mode;
    mode.mode = core::AudioInputMode::system_output;
    mode.platform_supported = SupportsScreenCaptureKitAudio();
    mode.capture_ready = stream.IsRunning();
    mode.permission_state = ScreenRecordingPermissionState();
    mode.backend_name = mode.platform_supported ? "ScreenCaptureKit audio" : "unsupported";
    mode.devices = EnumerateDevices(kAudioObjectPropertyScopeOutput, kAudioHardwarePropertyDefaultOutputDevice);

    std::ostringstream detail;
    if (!mode.platform_supported) {
        detail << "System-output capture requires macOS 13 or newer.";
    } else if (mode.permission_state != core::CapturePermissionState::granted) {
        detail << "Grant Screen Recording permission in System Settings to enable system-output capture.";
    } else {
        detail << "System-output capture is available through ScreenCaptureKit. ";
        if (SupportsCoreAudioProcessTap()) {
            detail << "CoreAudio process taps remain a planned lower-overhead backend on macOS 14.4+.";
        }
    }

    detail << " Devices discovered: " << mode.devices.size() << ".";
    if (!mode.devices.empty()) {
        detail << " Default output: " << DefaultDeviceSummary(mode.devices) << ".";
    }
    detail << " Buffered frames: " << ring_buffer.available_frames() << ".";

    const std::string last_error = stream.LastError();
    if (!last_error.empty()) {
        detail << " Last error: " << last_error;
    }

    mode.detail = detail.str();
    return mode;
}

core::AudioModeInfo BuildMicrophoneMode(
    const MicrophoneCaptureStream& stream,
    const core::AudioRingBuffer& ring_buffer) {
    core::AudioModeInfo mode;
    mode.mode = core::AudioInputMode::microphone;
    mode.platform_supported = true;
    mode.capture_ready = stream.IsRunning();
    mode.permission_state = MicrophonePermissionState();
    mode.backend_name = "AVAudioEngine input tap";
    mode.devices = EnumerateDevices(kAudioObjectPropertyScopeInput, kAudioHardwarePropertyDefaultInputDevice);

    std::ostringstream detail;
    detail << "Input devices discovered: " << mode.devices.size() << ".";
    if (!mode.devices.empty()) {
        detail << " Default input: " << DefaultDeviceSummary(mode.devices) << ".";
    }
    detail << " Buffered frames: " << ring_buffer.available_frames() << ".";

    const std::string last_error = stream.LastError();
    if (!last_error.empty()) {
        detail << " Last error: " << last_error;
    }

    mode.detail = detail.str();
    return mode;
}

} // namespace
} // namespace beatdrop::macos

@implementation BeatDropSystemAudioStreamOutput {
    beatdrop::macos::SystemAudioCaptureStream* _owner;
}

- (instancetype)initWithOwner:(beatdrop::macos::SystemAudioCaptureStream*)owner {
    self = [super init];
    if (self) {
        _owner = owner;
    }
    return self;
}

- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    if (_owner != nullptr) {
        _owner->HandleSampleBuffer(sampleBuffer, type);
    }
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    (void)stream;
    if (_owner != nullptr) {
        _owner->HandleStop(error);
    }
}

@end

namespace beatdrop::macos {

class MacAudioCaptureService::Impl {
public:
    Impl()
        : system_audio_stream_(stream_format_),
          microphone_stream_(stream_format_) {}

    std::vector<core::AudioModeInfo> DescribeModes() const {
        return {
            BuildSystemOutputMode(system_audio_stream_, ring_buffer_),
            BuildMicrophoneMode(microphone_stream_, ring_buffer_),
        };
    }

    bool StartCapture(core::AudioInputMode mode, const std::string& device_id) {
        last_error_.clear();
        system_audio_stream_.Stop();
        microphone_stream_.Stop();
        ring_buffer_.clear();

        switch (mode) {
        case core::AudioInputMode::system_output: {
            const auto devices = EnumerateDevices(kAudioObjectPropertyScopeOutput, kAudioHardwarePropertyDefaultOutputDevice);
            if (!device_id.empty() && !ContainsDeviceId(devices, device_id)) {
                last_error_ = "Requested system-output device was not found.";
                return false;
            }

            const auto requested_device = std::find_if(devices.begin(), devices.end(), [&](const core::AudioDeviceDescriptor& device) {
                return device.id == device_id;
            });
            if (requested_device != devices.end() && !requested_device->is_default) {
                last_error_ = "Explicit system-output device selection is not implemented yet. The default output device is used.";
                return false;
            }

            if (!system_audio_stream_.Start(ring_buffer_)) {
                last_error_ = system_audio_stream_.LastError();
                return false;
            }

            return true;
        }
        case core::AudioInputMode::microphone: {
            const auto devices = EnumerateDevices(kAudioObjectPropertyScopeInput, kAudioHardwarePropertyDefaultInputDevice);
            if (!device_id.empty() && !ContainsDeviceId(devices, device_id)) {
                last_error_ = "Requested microphone device was not found.";
                return false;
            }

            const auto requested_device = std::find_if(devices.begin(), devices.end(), [&](const core::AudioDeviceDescriptor& device) {
                return device.id == device_id;
            });
            if (requested_device != devices.end() && !requested_device->is_default) {
                last_error_ = "Explicit microphone device selection is not implemented yet. The default input device is used.";
                return false;
            }

            if (!microphone_stream_.Start(ring_buffer_)) {
                last_error_ = microphone_stream_.LastError();
                return false;
            }

            return true;
        }
        }

        last_error_ = "Unknown audio capture mode.";
        return false;
    }

    void StopCapture() {
        system_audio_stream_.Stop();
        microphone_stream_.Stop();
        ring_buffer_.clear();
        last_error_.clear();
    }

    bool IsCapturing() const {
        return system_audio_stream_.IsRunning() || microphone_stream_.IsRunning();
    }

    std::size_t BufferedFrameCount() const {
        return ring_buffer_.available_frames();
    }

    std::size_t PopInterleavedStereoFrames(std::size_t max_frames, std::vector<float>& destination) {
        return ring_buffer_.pop_interleaved_stereo(max_frames, destination);
    }

    std::string LastError() const {
        const std::string system_error = system_audio_stream_.LastError();
        if (!system_error.empty()) {
            return system_error;
        }

        const std::string microphone_error = microphone_stream_.LastError();
        if (!microphone_error.empty()) {
            return microphone_error;
        }

        return last_error_;
    }

private:
    core::AudioStreamFormat stream_format_ = {
        static_cast<std::uint32_t>(kTargetSampleRate),
        2,
    };
    core::AudioRingBuffer ring_buffer_;
    SystemAudioCaptureStream system_audio_stream_;
    MicrophoneCaptureStream microphone_stream_;
    std::string last_error_;
};

MacAudioCaptureService::MacAudioCaptureService()
    : impl_(std::make_unique<Impl>()) {}

MacAudioCaptureService::~MacAudioCaptureService() = default;

std::string MacAudioCaptureService::backend_name() const {
    return "macOS audio services";
}

bool MacAudioCaptureService::supports_mode(core::AudioInputMode mode) const {
    const auto modes = describe_modes();
    for (const auto& candidate : modes) {
        if (candidate.mode == mode) {
            return candidate.platform_supported;
        }
    }

    return false;
}

core::AudioStreamFormat MacAudioCaptureService::stream_format() const {
    core::AudioStreamFormat format;
    format.sample_rate_hz = static_cast<std::uint32_t>(kTargetSampleRate);
    format.channel_count = 2;
    return format;
}

std::vector<core::AudioModeInfo> MacAudioCaptureService::describe_modes() const {
    return impl_->DescribeModes();
}

bool MacAudioCaptureService::start_capture(core::AudioInputMode mode, const std::string& device_id) {
    return impl_->StartCapture(mode, device_id);
}

void MacAudioCaptureService::stop_capture() {
    impl_->StopCapture();
}

bool MacAudioCaptureService::is_capturing() const {
    return impl_->IsCapturing();
}

std::size_t MacAudioCaptureService::buffered_frame_count() const {
    return impl_->BufferedFrameCount();
}

std::size_t MacAudioCaptureService::pop_interleaved_stereo_frames(
    std::size_t max_frames,
    std::vector<float>& destination) {
    return impl_->PopInterleavedStereoFrames(max_frames, destination);
}

std::string MacAudioCaptureService::last_error() const {
    return impl_->LastError();
}

} // namespace beatdrop::macos
