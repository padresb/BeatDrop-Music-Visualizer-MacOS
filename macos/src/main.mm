#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>

#include "MacAudioCaptureService.h"
#include "MacPresetEngine.h"
#include "MacSyphonOutputPublisher.h"
#include "beatdrop/core/IniConfigStore.h"
#include "beatdrop/core/PresetSession.h"
#include "beatdrop/core/ProjectStatus.h"
#include "beatdrop/core/RuntimeCoordinator.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <filesystem>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr CGFloat kWindowWidth = 1360.0;
constexpr CGFloat kWindowHeight = 860.0;

NSString* ToNSString(const std::string& value) {
    return [NSString stringWithUTF8String:value.c_str()];
}

NSString* ToNSString(std::string_view value) {
    return [NSString stringWithUTF8String:std::string(value).c_str()];
}

NSString* ToNSString(const std::filesystem::path& value) {
    return [NSString stringWithUTF8String:value.generic_string().c_str()];
}

std::string UppercaseCopy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::toupper(ch));
    });
    return value;
}

std::string LowercaseCopy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

std::string TrimCopy(const std::string& value) {
    const auto first = std::find_if_not(value.begin(), value.end(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    });
    const auto last = std::find_if_not(value.rbegin(), value.rend(), [](unsigned char ch) {
        return std::isspace(ch) != 0;
    }).base();

    if (first >= last) {
        return {};
    }

    return std::string(first, last);
}

std::filesystem::path NormalizePath(const std::filesystem::path& path) {
    std::error_code error;
    const auto canonical = std::filesystem::weakly_canonical(path, error);
    return error ? path.lexically_normal() : canonical;
}

bool StartsWithCaseInsensitive(std::string_view value, std::string_view prefix) {
    if (value.size() < prefix.size()) {
        return false;
    }

    for (std::size_t index = 0; index < prefix.size(); ++index) {
        if (std::tolower(static_cast<unsigned char>(value[index])) !=
            std::tolower(static_cast<unsigned char>(prefix[index]))) {
            return false;
        }
    }

    return true;
}

bool IsRelativeDescendant(const std::filesystem::path& relative_path) {
    if (relative_path.empty()) {
        return false;
    }

    const auto iterator = relative_path.begin();
    if (iterator == relative_path.end()) {
        return false;
    }

    const auto head = iterator->generic_string();
    return head != "." && head != "..";
}

std::filesystem::path BundledResourcesRoot(const std::filesystem::path& repo_root) {
    return repo_root / "resources" / "Milkdrop2";
}

std::filesystem::path DefaultPresetRoot(const std::filesystem::path& repo_root) {
    return BundledResourcesRoot(repo_root) / "presets";
}

std::filesystem::path DefaultStartupPreset(const std::filesystem::path& repo_root) {
    return BundledResourcesRoot(repo_root) / "startuppreset" / "BeatDrop Music Visualizer Startup Preset.milk";
}

std::filesystem::path BeatDropConfigFilePath() {
    NSArray<NSURL*>* urls = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                   inDomains:NSUserDomainMask];
    NSURL* app_support_url = urls.firstObject;
    if (app_support_url == nil) {
        return std::filesystem::path("beatdrop.ini");
    }

    NSURL* beatdrop_directory_url = [app_support_url URLByAppendingPathComponent:@"BeatDrop Mac" isDirectory:YES];
    return std::filesystem::path([[beatdrop_directory_url path] UTF8String]) / "beatdrop.ini";
}

std::filesystem::path ResolveStoredPresetPath(std::string stored_value, const std::filesystem::path& repo_root) {
    stored_value = TrimCopy(stored_value);
    if (stored_value.empty()) {
        return {};
    }

    std::replace(stored_value.begin(), stored_value.end(), '\\', '/');
    std::filesystem::path candidate(stored_value);
    if (candidate.is_absolute()) {
        return NormalizePath(candidate);
    }

    const std::string generic_path = candidate.generic_string();
    if (StartsWithCaseInsensitive(generic_path, "BeatDrop Resources/")) {
        const auto suffix = generic_path.substr(std::string("BeatDrop Resources/").size());
        return NormalizePath(BundledResourcesRoot(repo_root) / std::filesystem::path(suffix));
    }

    if (StartsWithCaseInsensitive(generic_path, "resources/")) {
        return NormalizePath(repo_root / candidate);
    }

    return NormalizePath(repo_root / candidate);
}

std::string EncodeStoredPresetPath(const std::filesystem::path& path, const std::filesystem::path& repo_root) {
    if (path.empty()) {
        return {};
    }

    const auto normalized_path = NormalizePath(path);
    const auto relative_to_resources = normalized_path.lexically_relative(BundledResourcesRoot(repo_root));
    if (IsRelativeDescendant(relative_to_resources)) {
        std::string stored = (std::filesystem::path("BeatDrop Resources") / relative_to_resources).generic_string();
        std::replace(stored.begin(), stored.end(), '/', '\\');
        return stored;
    }

    return normalized_path.generic_string();
}

std::shared_ptr<beatdrop::core::IniConfigStore> CreateConfigStore(const std::filesystem::path& repo_root) {
    auto config_store = std::make_shared<beatdrop::core::IniConfigStore>(BeatDropConfigFilePath());
    (void)config_store->load();
    (void)config_store->import_from_file(repo_root / "resources" / "beatdrop.ini", false);

    const auto defaultPresetRoot = DefaultPresetRoot(repo_root);
    const auto defaultStartupPreset = DefaultStartupPreset(repo_root);

    if (!config_store->has_key("settings.szPresetDir")) {
        config_store->set_string("settings.szPresetDir", EncodeStoredPresetPath(defaultPresetRoot, repo_root));
    }
    if (!config_store->has_key("settings.szPresetStartup")) {
        config_store->set_string("settings.szPresetStartup", EncodeStoredPresetPath(defaultStartupPreset, repo_root));
    }
    if (!config_store->has_key("settings.bEnablePresetStartup")) {
        config_store->set_bool("settings.bEnablePresetStartup", true);
    }
    if (!config_store->has_key("settings.bSequentialPresetOrder")) {
        config_store->set_bool("settings.bSequentialPresetOrder", false);
    }
    if (!config_store->has_key("settings.bAlwaysOnTop")) {
        config_store->set_bool("settings.bAlwaysOnTop", false);
    }
    if (!config_store->has_key("settings.bBorderlessOnStartup")) {
        config_store->set_bool("settings.bBorderlessOnStartup", false);
    }
    if (!config_store->has_key("settings.bFullscreenOnStartup")) {
        config_store->set_bool("settings.bFullscreenOnStartup", false);
    }
    if (!config_store->has_key("settings.bEnableSyphonOutput")) {
        config_store->set_bool("settings.bEnableSyphonOutput", true);
    }
    if (!config_store->has_key("settings.nWindowPosX")) {
        config_store->set_int("settings.nWindowPosX", 50);
    }
    if (!config_store->has_key("settings.nWindowPosY")) {
        config_store->set_int("settings.nWindowPosY", 50);
    }
    if (!config_store->has_key("settings.nWindowWidth")) {
        config_store->set_int("settings.nWindowWidth", static_cast<std::int64_t>(kWindowWidth));
    }
    if (!config_store->has_key("settings.nWindowHeight")) {
        config_store->set_int("settings.nWindowHeight", static_cast<std::int64_t>(kWindowHeight));
    }

    (void)config_store->save();
    return config_store;
}

NSRect VisibleFrameForScreen(NSScreen* screen) {
    return screen != nil ? [screen visibleFrame] : NSMakeRect(0.0, 0.0, kWindowWidth, kWindowHeight);
}

NSSize MinimumWindowSizeForScreen(NSScreen* screen) {
    const NSRect visible_frame = VisibleFrameForScreen(screen);
    return NSMakeSize(std::min(980.0, NSWidth(visible_frame)), std::min(720.0, NSHeight(visible_frame)));
}

NSRect WindowFrameFromConfig(const beatdrop::core::IniConfigStore* config_store, NSScreen* screen) {
    const NSRect visible_frame = VisibleFrameForScreen(screen);
    const NSSize minimum_size = MinimumWindowSizeForScreen(screen);

    CGFloat width = kWindowWidth;
    CGFloat height = kWindowHeight;
    CGFloat x = NSMinX(visible_frame) + 50.0;
    CGFloat top_offset = 50.0;

    if (config_store != nullptr) {
        width = static_cast<CGFloat>(config_store->get_int("settings.nWindowWidth", static_cast<std::int64_t>(kWindowWidth)));
        height = static_cast<CGFloat>(config_store->get_int("settings.nWindowHeight", static_cast<std::int64_t>(kWindowHeight)));
        x = static_cast<CGFloat>(config_store->get_int("settings.nWindowPosX", 50));
        top_offset = static_cast<CGFloat>(config_store->get_int("settings.nWindowPosY", 50));
    }

    width = std::clamp(width, minimum_size.width, NSWidth(visible_frame));
    height = std::clamp(height, minimum_size.height, NSHeight(visible_frame));
    x = std::clamp(x, NSMinX(visible_frame), NSMaxX(visible_frame) - width);

    CGFloat y = NSMaxY(visible_frame) - top_offset - height;
    y = std::clamp(y, NSMinY(visible_frame), NSMaxY(visible_frame) - height);

    return NSMakeRect(x, y, width, height);
}

void PersistWindowFrameToConfig(beatdrop::core::IniConfigStore& config_store, NSWindow* window) {
    if (window == nil || ([window styleMask] & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen) {
        return;
    }

    const NSRect frame = [window frame];
    const NSRect visible_frame = VisibleFrameForScreen([window screen]);

    config_store.set_int("settings.nWindowPosX", static_cast<std::int64_t>(std::llround(NSMinX(frame))));
    config_store.set_int(
        "settings.nWindowPosY",
        static_cast<std::int64_t>(std::llround(NSMaxY(visible_frame) - NSMaxY(frame))));
    config_store.set_int("settings.nWindowWidth", static_cast<std::int64_t>(std::llround(NSWidth(frame))));
    config_store.set_int("settings.nWindowHeight", static_cast<std::int64_t>(std::llround(NSHeight(frame))));
    (void)config_store.save();
}

std::string SanitizeFilenameComponent(std::string value) {
    if (value.empty()) {
        return "Visualizer";
    }

    for (char& character : value) {
        if (character == '/' || character == '\\' || character == ':' || character == '*' ||
            character == '?' || character == '"' || character == '<' || character == '>' ||
            character == '|') {
            character = '_';
        }
    }

    return value;
}

std::filesystem::path BeatDropScreenshotDirectory() {
    NSArray<NSURL*>* urls = [[NSFileManager defaultManager] URLsForDirectory:NSPicturesDirectory
                                                                   inDomains:NSUserDomainMask];
    NSURL* pictures_url = urls.firstObject;
    if (pictures_url == nil) {
        return std::filesystem::path("screenshots");
    }

    return std::filesystem::path([[pictures_url path] UTF8String]) / "BeatDrop" / "screenshots";
}

std::filesystem::path BuildScreenshotPath(const std::string& preset_name) {
    const auto screenshot_directory = BeatDropScreenshotDirectory();
    std::error_code error;
    std::filesystem::create_directories(screenshot_directory, error);

    const std::string safe_name = SanitizeFilenameComponent(preset_name);
    std::time_t now = std::time(nullptr);
    std::tm local_time {};
    localtime_r(&now, &local_time);

    char filename[512];
    std::snprintf(
        filename,
        sizeof(filename),
        "BeatDrop-%02d%02d%04d-%02d%02d%02d-%s.png",
        local_time.tm_mday,
        local_time.tm_mon + 1,
        local_time.tm_year + 1900,
        local_time.tm_hour,
        local_time.tm_min,
        local_time.tm_sec,
        safe_name.c_str());

    return screenshot_directory / filename;
}

NSColor* BeatDropInk(CGFloat alpha = 1.0) {
    return [NSColor colorWithCalibratedRed:0.08 green:0.09 blue:0.12 alpha:alpha];
}

NSColor* BeatDropSky(CGFloat alpha = 1.0) {
    return [NSColor colorWithCalibratedRed:0.20 green:0.66 blue:0.89 alpha:alpha];
}

NSColor* BeatDropAmber(CGFloat alpha = 1.0) {
    return [NSColor colorWithCalibratedRed:0.97 green:0.67 blue:0.22 alpha:alpha];
}

NSColor* BeatDropMint(CGFloat alpha = 1.0) {
    return [NSColor colorWithCalibratedRed:0.53 green:0.88 blue:0.76 alpha:alpha];
}

NSColor* BeatDropRose(CGFloat alpha = 1.0) {
    return [NSColor colorWithCalibratedRed:0.91 green:0.39 blue:0.42 alpha:alpha];
}

void FillRoundedRect(NSRect rect, CGFloat radius, NSColor* color) {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}

void DrawLabel(NSString* text, NSPoint origin, NSFont* font, NSColor* color) {
    NSDictionary* attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    };
    [text drawAtPoint:origin withAttributes:attributes];
}

void DrawCenteredText(NSString* text, NSRect rect, NSFont* font, NSColor* color) {
    NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;

    NSDictionary* attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph,
    };

    [text drawInRect:rect withAttributes:attributes];
}

void DrawTextBlock(NSString* text, NSRect rect, NSFont* font, NSColor* color) {
    NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;

    NSDictionary* attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph,
    };

    [text drawInRect:rect withAttributes:attributes];
}

void DrawFittedLine(NSString* text, NSRect rect, NSFont* font, NSColor* color, NSTextAlignment alignment = NSTextAlignmentLeft) {
    NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = alignment;
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;

    NSDictionary* attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph,
    };

    [text drawInRect:rect withAttributes:attributes];
}

std::string DefaultDeviceName(const beatdrop::core::AudioModeInfo& mode) {
    for (const auto& device : mode.devices) {
        if (device.is_default) {
            return device.name;
        }
    }

    return mode.devices.empty() ? std::string("None") : mode.devices.front().name;
}

const beatdrop::core::AudioModeInfo* FindMode(
    const std::vector<beatdrop::core::AudioModeInfo>& modes,
    beatdrop::core::AudioInputMode input_mode) {
    const auto iterator = std::find_if(
        modes.begin(),
        modes.end(),
        [&](const beatdrop::core::AudioModeInfo& mode) {
            return mode.mode == input_mode;
        });

    return iterator == modes.end() ? nullptr : &(*iterator);
}

bool ShouldAutoStart(const beatdrop::core::AudioModeInfo* mode) {
    return mode != nullptr &&
        mode->platform_supported &&
        mode->permission_state == beatdrop::core::CapturePermissionState::granted;
}

void RequestScreenCaptureAccessIfNeeded() {
    if (CGPreflightScreenCaptureAccess()) {
        return;
    }

    (void)CGRequestScreenCaptureAccess();
}

void RequestMicrophoneAccessIfNeeded() {
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusNotDetermined) {
        return;
    }

    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL granted) {
                                 (void)granted;
                             }];
}

beatdrop::core::RenderSurfaceDescriptor SurfaceDescriptorForView(NSView* view) {
    beatdrop::core::RenderSurfaceDescriptor descriptor;
    if (view == nil) {
        return descriptor;
    }

    const NSRect bounds = [view bounds];
    const double scale = [view window] != nil ? [[view window] backingScaleFactor] : 1.0;
    descriptor.width_px = static_cast<std::uint32_t>(std::max(1.0, std::round(NSWidth(bounds) * scale)));
    descriptor.height_px = static_cast<std::uint32_t>(std::max(1.0, std::round(NSHeight(bounds) * scale)));
    descriptor.scale_factor = scale;
    return descriptor;
}

float ClampUnit(float value) {
    return std::clamp(value, 0.0F, 1.0F);
}

void FillEllipse(NSRect rect, NSColor* color) {
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:rect] fill];
}

void DrawRenderedFrame(NSRect rect, const beatdrop::macos::MacPresetEngine& preset_engine) {
    if (!preset_engine.has_latest_frame()) {
        return;
    }

    const auto& pixels = preset_engine.latest_frame_rgba();
    const std::size_t width = preset_engine.latest_frame_width();
    const std::size_t height = preset_engine.latest_frame_height();
    if (pixels.empty() || width == 0 || height == 0) {
        return;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == nullptr) {
        return;
    }

    CGDataProviderRef provider =
        CGDataProviderCreateWithData(nullptr, pixels.data(), pixels.size(), nullptr);
    if (provider == nullptr) {
        CGColorSpaceRelease(color_space);
        return;
    }

    CGImageRef image = CGImageCreate(
        width,
        height,
        8,
        32,
        width * 4,
        color_space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault,
        provider,
        nullptr,
        false,
        kCGRenderingIntentDefault);

    if (image != nullptr) {
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:28.0 yRadius:28.0] addClip];
        CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
        CGContextDrawImage(
            context,
            CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, rect.size.height),
            image);
        [NSGraphicsContext restoreGraphicsState];
        CGImageRelease(image);
    }

    CGDataProviderRelease(provider);
    CGColorSpaceRelease(color_space);
}

void DrawReactiveHalo(NSRect rect, const beatdrop::core::PresetEngineState& presetState, double t) {
    const CGFloat span = std::min(NSWidth(rect), NSHeight(rect));
    const CGFloat centerX = NSMinX(rect) + NSWidth(rect) * 0.40;
    const CGFloat centerY = NSMinY(rect) + NSHeight(rect) * 0.50;
    const CGFloat wobble = static_cast<CGFloat>(std::sin(t * 1.3) * 8.0);
    const CGFloat bassRadius = span * (0.18 + ClampUnit(presetState.bass_energy) * 0.24);
    const CGFloat midRadius = span * (0.12 + ClampUnit(presetState.mid_energy) * 0.18);
    const CGFloat trebleRadius = span * (0.08 + ClampUnit(presetState.treble_energy) * 0.14);

    FillEllipse(NSMakeRect(centerX - bassRadius + wobble, centerY - bassRadius, bassRadius * 2.0, bassRadius * 2.0),
                [BeatDropAmber(0.14 + ClampUnit(presetState.bass_energy) * 0.18) colorWithAlphaComponent:0.16 + ClampUnit(presetState.bass_energy) * 0.16]);
    FillEllipse(NSMakeRect(centerX - midRadius - wobble * 0.5, centerY - midRadius * 1.1, midRadius * 2.0, midRadius * 2.0),
                [BeatDropSky(0.12 + ClampUnit(presetState.mid_energy) * 0.18) colorWithAlphaComponent:0.14 + ClampUnit(presetState.mid_energy) * 0.14]);
    FillEllipse(NSMakeRect(centerX - trebleRadius, centerY - trebleRadius + wobble * 0.4, trebleRadius * 2.0, trebleRadius * 2.0),
                [BeatDropMint(0.14 + ClampUnit(presetState.treble_energy) * 0.22) colorWithAlphaComponent:0.16 + ClampUnit(presetState.treble_energy) * 0.16]);
}

void DrawReactiveWave(NSRect rect, const beatdrop::core::PresetEngineState& presetState, double t) {
    NSBezierPath* path = [NSBezierPath bezierPath];
    [path setLineWidth:3.0];
    [[BeatDropMint(0.9) colorWithAlphaComponent:0.9] setStroke];

    const CGFloat width = NSWidth(rect);
    const CGFloat height = NSHeight(rect);
    const CGFloat midY = NSMinY(rect) + height * 0.5;

    if (presetState.supports_live_visualization && !presetState.waveform_preview.empty()) {
        for (std::size_t index = 0; index < presetState.waveform_preview.size(); ++index) {
            const CGFloat x = NSMinX(rect) +
                width * static_cast<CGFloat>(index) / static_cast<CGFloat>(presetState.waveform_preview.size() - 1);
            const CGFloat y = midY - static_cast<CGFloat>(presetState.waveform_preview[index]) * (height * 0.42F);

            if (index == 0) {
                [path moveToPoint:NSMakePoint(x, y)];
            } else {
                [path lineToPoint:NSMakePoint(x, y)];
            }
        }
    } else {
        for (NSInteger i = 0; i <= 160; ++i) {
            const CGFloat x = NSMinX(rect) + width * static_cast<CGFloat>(i) / 160.0;
            const double phase = t * 1.7 + static_cast<double>(i) * 0.18;
            const double amplitude = std::sin(phase) * 24.0 + std::sin(phase * 0.5) * 18.0;
            const CGFloat y = midY + static_cast<CGFloat>(amplitude);

            if (i == 0) {
                [path moveToPoint:NSMakePoint(x, y)];
            } else {
                [path lineToPoint:NSMakePoint(x, y)];
            }
        }
    }

    [path stroke];
}

NSRect TakeTopRect(NSRect& remaining, CGFloat height, CGFloat gap = 0.0) {
    const CGFloat actualHeight = std::min(height, NSHeight(remaining));
    const NSRect slice = NSMakeRect(NSMinX(remaining), NSMinY(remaining), NSWidth(remaining), actualHeight);
    remaining.origin.y += actualHeight + gap;
    remaining.size.height = std::max(0.0, NSHeight(remaining) - actualHeight - gap);
    return slice;
}

NSRect TakeBottomRect(NSRect& remaining, CGFloat height, CGFloat gap = 0.0) {
    const CGFloat actualHeight = std::min(height, NSHeight(remaining));
    const NSRect slice = NSMakeRect(NSMinX(remaining), NSMaxY(remaining) - actualHeight, NSWidth(remaining), actualHeight);
    remaining.size.height = std::max(0.0, NSHeight(remaining) - actualHeight - gap);
    return slice;
}

NSRect TakeRightRect(NSRect& remaining, CGFloat width, CGFloat gap = 0.0) {
    const CGFloat actualWidth = std::min(width, NSWidth(remaining));
    const NSRect slice = NSMakeRect(NSMaxX(remaining) - actualWidth, NSMinY(remaining), actualWidth, NSHeight(remaining));
    remaining.size.width = std::max(0.0, NSWidth(remaining) - actualWidth - gap);
    return slice;
}

} // namespace

@interface BeatDropPortView : NSView <NSDraggingDestination>
- (instancetype)initWithFrame:(NSRect)frameRect
                       status:(beatdrop::core::ProjectStatus)status
                  configStore:(std::shared_ptr<beatdrop::core::IniConfigStore>)configStore;
- (void)prepareConfigStore;
- (void)persistPresetSession;
- (void)restorePresetSessionFromConfig;
- (void)showTransientMessage:(NSString*)message;
- (BOOL)saveScreenshot;
- (void)syncPresetEngineFromSession;
- (void)toggleSyphonOutput;
@end

@implementation BeatDropPortView {
    beatdrop::core::ProjectStatus _status;
    std::unique_ptr<beatdrop::macos::MacAudioCaptureService> _audioService;
    std::shared_ptr<beatdrop::core::IniConfigStore> _configStore;
    std::unique_ptr<beatdrop::macos::MacPresetEngine> _presetEngine;
    std::unique_ptr<beatdrop::macos::MacSyphonOutputPublisher> _outputPublisher;
    std::unique_ptr<beatdrop::core::PresetSession> _presetSession;
    std::unique_ptr<beatdrop::core::RuntimeCoordinator> _runtimeCoordinator;
    std::vector<beatdrop::core::AudioModeInfo> _audioModes;
    beatdrop::core::PresetEngineState _presetState;
    beatdrop::core::PresetSessionState _presetSessionState;
    std::filesystem::path _loadedPresetLibraryRoot;
    std::filesystem::path _repoRoot;
    beatdrop::core::RuntimeDispatchStats _runtimeStats;
    CFAbsoluteTime _startTime;
    CFAbsoluteTime _toastExpirationTime;
    NSTimer* _timer;
    NSString* _toastMessage;
    NSUInteger _frameCounter;
    BOOL _renderFullscreen;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                       status:(beatdrop::core::ProjectStatus)status
                  configStore:(std::shared_ptr<beatdrop::core::IniConfigStore>)configStore {
    self = [super initWithFrame:frameRect];
    if (self) {
        _status = std::move(status);
        _repoRoot = _status.repo_root.empty() ? std::filesystem::path(BEATDROP_SOURCE_DIR) : _status.repo_root;
        _configStore = std::move(configStore);
        _audioService = std::make_unique<beatdrop::macos::MacAudioCaptureService>();
        _presetEngine = std::make_unique<beatdrop::macos::MacPresetEngine>();
        _outputPublisher = std::make_unique<beatdrop::macos::MacSyphonOutputPublisher>();
        _presetSession = std::make_unique<beatdrop::core::PresetSession>();
        _presetEngine->set_render_surface(beatdrop::core::RenderSurfaceDescriptor{
            static_cast<std::uint32_t>(std::max(1.0, std::round(NSWidth(frameRect)))),
            static_cast<std::uint32_t>(std::max(1.0, std::round(NSHeight(frameRect)))),
            1.0,
        });
        _outputPublisher->set_surface(beatdrop::core::RenderSurfaceDescriptor{
            static_cast<std::uint32_t>(std::max(1.0, std::round(NSWidth(frameRect)))),
            static_cast<std::uint32_t>(std::max(1.0, std::round(NSHeight(frameRect)))),
            1.0,
        });
        const bool enable_syphon_output = _configStore != nullptr &&
            _configStore->get_bool("settings.bEnableSyphonOutput", true);
        (void)_outputPublisher->set_enabled(enable_syphon_output);
        [self restorePresetSessionFromConfig];
        _audioModes = _audioService->describe_modes();
        if (_audioService) {
            const auto* systemOutputMode = FindMode(_audioModes, beatdrop::core::AudioInputMode::system_output);
            const auto* microphoneMode = FindMode(_audioModes, beatdrop::core::AudioInputMode::microphone);

            if (systemOutputMode != nullptr && systemOutputMode->platform_supported) {
                RequestScreenCaptureAccessIfNeeded();
            }

            if (ShouldAutoStart(systemOutputMode)) {
                _audioService->start_capture(beatdrop::core::AudioInputMode::system_output);
            }

            if (microphoneMode != nullptr && microphoneMode->platform_supported) {
                RequestMicrophoneAccessIfNeeded();
            }

            _audioModes = _audioService->describe_modes();
        }
        if (_audioService && _presetEngine) {
            _runtimeCoordinator = std::make_unique<beatdrop::core::RuntimeCoordinator>(*_audioService, *_presetEngine);
        }
        [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
        _startTime = CFAbsoluteTimeGetCurrent();
        _toastExpirationTime = 0.0;
        _frameCounter = 0;
        _timer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 60.0)
                                                  target:self
                                                selector:@selector(tick:)
                                                userInfo:nil
                                                 repeats:YES];
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)prepareConfigStore {
    if (_configStore) {
        return;
    }

    _configStore = CreateConfigStore(_repoRoot);
}

- (void)persistPresetSession {
    if (!_configStore || !_presetSession) {
        return;
    }

    _presetSessionState = _presetSession->describe_state();
    const auto fallbackPresetRoot = DefaultPresetRoot(_repoRoot);
    const auto fallbackStartupPreset = DefaultStartupPreset(_repoRoot);

    _configStore->set_string(
        "settings.szPresetDir",
        EncodeStoredPresetPath(
            _presetSessionState.library_loaded ? _presetSessionState.library_root : fallbackPresetRoot,
            _repoRoot));
    _configStore->set_string(
        "settings.szPresetStartup",
        EncodeStoredPresetPath(
            _presetSessionState.has_active_preset ? _presetSessionState.active_preset_path : fallbackStartupPreset,
            _repoRoot));
    _configStore->set_bool("settings.bEnablePresetStartup", _presetSessionState.has_active_preset);
    _configStore->set_bool(
        "settings.bSequentialPresetOrder",
        _presetSessionState.selection_mode == beatdrop::core::PresetSelectionMode::sequential);
    (void)_configStore->save();
}

- (void)restorePresetSessionFromConfig {
    if (!_presetSession || !_presetEngine) {
        return;
    }

    [self prepareConfigStore];

    const auto defaultPresetRoot = DefaultPresetRoot(_repoRoot);
    const auto defaultStartupPreset = DefaultStartupPreset(_repoRoot);
    const bool use_sequential_order = _configStore != nullptr &&
        _configStore->get_bool("settings.bSequentialPresetOrder", false);

    _presetSession->set_selection_mode(
        use_sequential_order
            ? beatdrop::core::PresetSelectionMode::sequential
            : beatdrop::core::PresetSelectionMode::random);

    std::filesystem::path configuredPresetRoot = defaultPresetRoot;
    std::filesystem::path configuredStartupPreset = defaultStartupPreset;
    bool enableStartupPreset = true;

    if (_configStore) {
        configuredPresetRoot = ResolveStoredPresetPath(
            _configStore->get_string("settings.szPresetDir", EncodeStoredPresetPath(defaultPresetRoot, _repoRoot)),
            _repoRoot);
        configuredStartupPreset = ResolveStoredPresetPath(
            _configStore->get_string(
                "settings.szPresetStartup",
                EncodeStoredPresetPath(defaultStartupPreset, _repoRoot)),
            _repoRoot);
        enableStartupPreset = _configStore->get_bool("settings.bEnablePresetStartup", true);
    }

    std::error_code error;
    if (!std::filesystem::is_directory(configuredPresetRoot, error)) {
        configuredPresetRoot = defaultPresetRoot;
    }

    error.clear();
    if (!std::filesystem::is_regular_file(configuredStartupPreset, error)) {
        configuredStartupPreset = defaultStartupPreset;
    }

    bool startupPresetLoaded = false;
    if (enableStartupPreset) {
        error.clear();
        if (std::filesystem::is_regular_file(configuredStartupPreset, error)) {
            startupPresetLoaded = _presetSession->load_library(configuredStartupPreset);
        }
    }

    if (!startupPresetLoaded) {
        bool libraryLoaded = _presetSession->load_library(configuredPresetRoot);
        if (!libraryLoaded && configuredPresetRoot != defaultPresetRoot) {
            libraryLoaded = _presetSession->load_library(defaultPresetRoot);
        }
        if (libraryLoaded) {
            (void)_presetSession->activate_random();
        }
    }

    _presetSessionState = _presetSession->describe_state();
    [self syncPresetEngineFromSession];
    [self persistPresetSession];
}

- (void)showTransientMessage:(NSString*)message {
    _toastMessage = [message copy];
    _toastExpirationTime = CFAbsoluteTimeGetCurrent() + 5.0;
    [self setNeedsDisplay:YES];
}

- (BOOL)saveScreenshot {
    NSBitmapImageRep* bitmap = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
    if (bitmap == nil) {
        [self showTransientMessage:@"Screenshot failed: no backing bitmap was available."];
        return NO;
    }

    [self cacheDisplayInRect:self.bounds toBitmapImageRep:bitmap];
    NSData* png_data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (png_data == nil) {
        [self showTransientMessage:@"Screenshot failed: PNG encoding returned no data."];
        return NO;
    }

    const auto screenshot_path = BuildScreenshotPath(
        _presetState.active_preset_name.empty() ? std::string("Visualizer") : _presetState.active_preset_name);
    NSString* output_path = [NSString stringWithUTF8String:screenshot_path.string().c_str()];
    if (output_path == nil || ![png_data writeToFile:output_path atomically:YES]) {
        [self showTransientMessage:@"Screenshot failed: the PNG file could not be written."];
        return NO;
    }

    [self showTransientMessage:[NSString stringWithFormat:@"Screenshot saved: %@", [output_path lastPathComponent]]];
    return YES;
}

- (void)syncPresetEngineFromSession {
    if (!_presetSession || !_presetEngine) {
        return;
    }

    _presetSessionState = _presetSession->describe_state();
    if (_presetSessionState.library_loaded) {
        if (_loadedPresetLibraryRoot != _presetSessionState.library_root) {
            _presetEngine->load_preset_library(_presetSessionState.library_root);
            _loadedPresetLibraryRoot = _presetSessionState.library_root;
        }
        if (_presetSessionState.has_active_preset) {
            _presetEngine->set_active_preset(_presetSessionState.active_preset_path);
        }
    }
    _presetState = _presetEngine->describe_state();
}

- (BOOL)loadPresetSource:(const std::filesystem::path&)source {
    if (!_presetSession) {
        return NO;
    }

    const bool loaded = _presetSession->load_library(source);
    _presetSessionState = _presetSession->describe_state();
    if (loaded) {
        [self syncPresetEngineFromSession];
        [self persistPresetSession];
    }

    [self setNeedsDisplay:YES];
    return loaded ? YES : NO;
}

- (void)advancePresetNext {
    if (_presetSession && _presetSession->activate_next()) {
        [self syncPresetEngineFromSession];
        [self persistPresetSession];
        [self setNeedsDisplay:YES];
    } else if (_presetSession) {
        _presetSessionState = _presetSession->describe_state();
        [self setNeedsDisplay:YES];
    }
}

- (void)advancePresetPrevious {
    if (_presetSession && _presetSession->activate_previous()) {
        [self syncPresetEngineFromSession];
        [self persistPresetSession];
        [self setNeedsDisplay:YES];
    } else if (_presetSession) {
        _presetSessionState = _presetSession->describe_state();
        [self setNeedsDisplay:YES];
    }
}

- (void)advancePresetRandom {
    if (_presetSession && _presetSession->activate_random()) {
        [self syncPresetEngineFromSession];
        [self persistPresetSession];
        [self setNeedsDisplay:YES];
    } else if (_presetSession) {
        _presetSessionState = _presetSession->describe_state();
        [self setNeedsDisplay:YES];
    }
}

- (void)togglePresetOrderMode {
    if (!_presetSession) {
        return;
    }

    const auto currentMode = _presetSession->describe_state().selection_mode;
    const auto nextMode = currentMode == beatdrop::core::PresetSelectionMode::random
        ? beatdrop::core::PresetSelectionMode::sequential
        : beatdrop::core::PresetSelectionMode::random;
    _presetSession->set_selection_mode(nextMode);
    _presetSessionState = _presetSession->describe_state();
    [self persistPresetSession];
    [self setNeedsDisplay:YES];
}

- (void)toggleSyphonOutput {
    if (!_outputPublisher) {
        return;
    }

    const bool next_state = !_outputPublisher->enabled();
    if (!_outputPublisher->set_enabled(next_state)) {
        [self showTransientMessage:@"Syphon could not be enabled in this build."];
        return;
    }

    if (_configStore) {
        _configStore->set_bool("settings.bEnableSyphonOutput", next_state);
        (void)_configStore->save();
    }

    [self showTransientMessage:next_state ? @"Syphon output enabled." : @"Syphon output disabled."];
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (_presetEngine) {
        _presetEngine->set_render_surface(SurfaceDescriptorForView(self));
        _presetState = _presetEngine->describe_state();
    }
    if (_outputPublisher) {
        _outputPublisher->set_surface(SurfaceDescriptorForView(self));
    }
}

- (void)dealloc {
    [_timer invalidate];
    _timer = nil;
    if (_audioService) {
        _audioService->stop_capture();
        _audioService.reset();
    }
    _runtimeCoordinator.reset();
    _configStore.reset();
    _presetSession.reset();
    _outputPublisher.reset();
    _presetEngine.reset();
}

- (BOOL)isFlipped {
    return YES;
}

- (void)tick:(NSTimer*)timer {
    (void)timer;
    _frameCounter += 1;
    if (_presetEngine) {
        _presetEngine->set_render_surface(SurfaceDescriptorForView(self));
    }
    if (_outputPublisher) {
        _outputPublisher->set_surface(SurfaceDescriptorForView(self));
    }
    if (_runtimeCoordinator) {
        _runtimeStats = _runtimeCoordinator->tick(1.0 / 60.0);
    }
    if (_presetEngine) {
        _presetState = _presetEngine->describe_state();
    }
    if (_outputPublisher && _presetEngine && _presetEngine->has_publishable_texture()) {
        (void)_outputPublisher->publish_texture(
            _presetEngine->publisher_context_handle(),
            _presetEngine->publisher_texture_name(),
            _presetEngine->latest_frame_width(),
            _presetEngine->latest_frame_height(),
            _presetEngine->publisher_texture_flipped());
    }
    if (_frameCounter % 30 == 0 && _audioService) {
        _audioModes = _audioService->describe_modes();
    }
    [self setNeedsDisplay:YES];
}

- (void)keyDown:(NSEvent*)event {
    NSString* characters = [event charactersIgnoringModifiers];
    if (characters.length == 0) {
        [super keyDown:event];
        return;
    }

    const unichar key = [characters characterAtIndex:0];
    switch (key) {
    case 27: // Escape
        if (_renderFullscreen) {
            _renderFullscreen = NO;
            [self showTransientMessage:@"Render fullscreen OFF"];
            return;
        }
        break;
    case NSLeftArrowFunctionKey:
        [self advancePresetPrevious];
        return;
    case NSRightArrowFunctionKey:
        [self advancePresetNext];
        return;
    case ' ':
        [self advancePresetRandom];
        return;
    default:
        break;
    }

    switch (std::tolower(static_cast<unsigned char>(key))) {
    case 'r':
        [self advancePresetRandom];
        return;
    case 's':
        [self togglePresetOrderMode];
        return;
    case 'o':
        [self toggleSyphonOutput];
        return;
    case 'f':
        _renderFullscreen = !_renderFullscreen;
        [self showTransientMessage:_renderFullscreen ? @"Render fullscreen ON (press F or Esc to exit)" : @"Render fullscreen OFF"];
        return;
    case 'x':
        if (([event modifierFlags] & NSEventModifierFlagControl) != 0 ||
            ([event modifierFlags] & NSEventModifierFlagCommand) != 0) {
            [self saveScreenshot];
            return;
        }
        break;
    default:
        break;
    }

    [super keyDown:event];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard* pasteboard = [sender draggingPasteboard];
    NSArray<NSURL*>* urls = [pasteboard readObjectsForClasses:@[ [NSURL class] ]
                                                     options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    for (NSURL* url in urls) {
        if (![url isFileURL]) {
            continue;
        }

        const std::filesystem::path path([[url path] UTF8String]);
        std::error_code error;
        if (std::filesystem::is_directory(path, error)) {
            return NSDragOperationCopy;
        }
        if (!error && std::filesystem::is_regular_file(path) && LowercaseCopy(path.extension().string()) == ".milk") {
            return NSDragOperationCopy;
        }
    }

    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard* pasteboard = [sender draggingPasteboard];
    NSArray<NSURL*>* urls = [pasteboard readObjectsForClasses:@[ [NSURL class] ]
                                                     options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    for (NSURL* url in urls) {
        if (![url isFileURL]) {
            continue;
        }

        const std::filesystem::path path([[url path] UTF8String]);
        std::error_code error;
        if (std::filesystem::is_directory(path, error)) {
            return [self loadPresetSource:path];
        }
        if (!error && std::filesystem::is_regular_file(path) && LowercaseCopy(path.extension().string()) == ".milk") {
            return [self loadPresetSource:path];
        }
    }

    return NO;
}

- (void)drawBackgroundInRect:(NSRect)bounds {
    NSGradient* gradient = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithCalibratedRed:0.97 green:0.94 blue:0.89 alpha:1.0], 0.0,
        [NSColor colorWithCalibratedRed:0.85 green:0.92 blue:0.96 alpha:1.0], 0.55,
        [NSColor colorWithCalibratedRed:0.99 green:0.78 blue:0.63 alpha:1.0], 1.0,
        nil];
    [gradient drawInRect:bounds angle:112.0];

    FillRoundedRect(NSInsetRect(bounds, 26.0, 26.0), 36.0, [BeatDropInk(0.93) colorWithAlphaComponent:0.93]);
}

- (void)drawAnimatedBarsInRect:(NSRect)rect time:(double)t {
    const NSInteger barCount = 48;
    const CGFloat gap = 8.0;
    const CGFloat totalGap = gap * (barCount - 1);
    const CGFloat barWidth = (NSWidth(rect) - totalGap) / barCount;
    const float peak = ClampUnit(_presetState.audio_peak);

    for (NSInteger i = 0; i < barCount; ++i) {
        const CGFloat x = NSMinX(rect) + i * (barWidth + gap);
        double energy = 0.10 + std::fabs(std::sin(t * 1.4 + i * 0.31) * 0.36);
        if (_presetState.supports_live_visualization) {
            energy = std::max<double>(energy * 0.18, _presetState.energy_bars[static_cast<std::size_t>(i)]);
            energy = std::min(1.0, energy + peak * 0.18);
        }

        const CGFloat height = static_cast<CGFloat>(energy) * NSHeight(rect);
        const NSRect barRect = NSMakeRect(x, NSMaxY(rect) - height, barWidth, height);
        NSColor* color = (i % 3 == 0)
            ? [BeatDropAmber(0.72 + _presetState.bass_energy * 0.24) colorWithAlphaComponent:0.82 + _presetState.bass_energy * 0.14]
            : ((i % 3 == 1)
                ? [BeatDropSky(0.72 + _presetState.mid_energy * 0.24) colorWithAlphaComponent:0.80 + _presetState.mid_energy * 0.16]
                : [BeatDropRose(0.68 + _presetState.treble_energy * 0.24) colorWithAlphaComponent:0.78 + _presetState.treble_energy * 0.16]);
        FillRoundedRect(barRect, barWidth * 0.45, color);
    }
}

- (void)drawStatsInRect:(NSRect)bounds {
    if (NSWidth(bounds) <= 0.0 || NSHeight(bounds) <= 0.0) {
        return;
    }

    const CGFloat gap = 14.0;
    const CGFloat cardWidth = std::max(120.0, (NSWidth(bounds) - gap * 2.0) / 3.0);
    CGFloat x = NSMinX(bounds);

    struct StatCard {
        NSString* title;
        NSString* value;
        NSColor* color;
    };

    const StatCard cards[] = {
        { @"Presets", [NSString stringWithFormat:@"%zu", _status.resources.preset_count], BeatDropAmber(1.0) },
        { @"Textures", [NSString stringWithFormat:@"%zu", _status.resources.texture_count], BeatDropSky(1.0) },
        { @"Shaders", [NSString stringWithFormat:@"%zu", _status.resources.shader_count], BeatDropMint(1.0) },
    };

    for (const auto& card : cards) {
        const NSRect rect = NSMakeRect(x, NSMinY(bounds), cardWidth, NSHeight(bounds));
        FillRoundedRect(rect, 22.0, [card.color colorWithAlphaComponent:0.12]);
        DrawLabel(card.title,
                  NSMakePoint(x + 16.0, NSMinY(rect) + 14.0),
                  [NSFont fontWithName:@"Avenir Next Demi Bold" size:14.0],
                  [NSColor colorWithWhite:0.92 alpha:0.78]);
        DrawLabel(card.value,
                  NSMakePoint(x + 16.0, NSMinY(rect) + 34.0),
                  [NSFont fontWithName:@"Avenir Next Condensed Heavy" size:32.0],
                  [NSColor colorWithWhite:0.98 alpha:1.0]);
        x += cardWidth + gap;
    }
}

- (void)drawCapabilityChipsInRect:(NSRect)bounds {
    if (_status.replacement_areas.empty() || NSHeight(bounds) <= 0.0 || NSWidth(bounds) <= 0.0) {
        return;
    }

    const CGFloat gapBetweenCards = 14.0;
    const CGFloat chipHeight = std::max(
        62.0,
        std::min(78.0, (NSHeight(bounds) - gapBetweenCards * (_status.replacement_areas.size() - 1)) /
            static_cast<CGFloat>(_status.replacement_areas.size())));
    CGFloat y = NSMinY(bounds);

    for (const auto& gap : _status.replacement_areas) {
        const NSRect chipRect = NSMakeRect(NSMinX(bounds), y, NSWidth(bounds), chipHeight);
        FillRoundedRect(chipRect, 18.0, [NSColor colorWithCalibratedWhite:1.0 alpha:0.06]);

        NSColor* accent = (gap.status == beatdrop::core::WorkStatus::ready)
            ? [BeatDropMint(1.0) colorWithAlphaComponent:0.92]
            : [BeatDropAmber(1.0) colorWithAlphaComponent:0.92];
        FillRoundedRect(NSMakeRect(NSMinX(chipRect) + 16.0, NSMinY(chipRect) + 16.0, 10.0, chipHeight - 32.0), 5.0, accent);

        DrawLabel(ToNSString(gap.subsystem),
                  NSMakePoint(NSMinX(chipRect) + 38.0, NSMinY(chipRect) + 12.0),
                  [NSFont fontWithName:@"Avenir Next Demi Bold" size:16.0],
                  [NSColor colorWithWhite:0.99 alpha:1.0]);

        DrawTextBlock(ToNSString(gap.current_backend + " -> " + gap.target_backend),
                      NSMakeRect(NSMinX(chipRect) + 38.0, NSMinY(chipRect) + 30.0, NSWidth(chipRect) - 190.0, chipHeight - 36.0),
                      [NSFont fontWithName:@"Menlo" size:11.0],
                      [NSColor colorWithWhite:0.90 alpha:0.75]);

        NSString* statusText = [ToNSString(UppercaseCopy(std::string(beatdrop::core::to_string(gap.status)))) stringByReplacingOccurrencesOfString:@"_" withString:@" "];
        DrawCenteredText(statusText,
                         NSMakeRect(NSMaxX(chipRect) - 144.0, NSMinY(chipRect) + 16.0, 118.0, 22.0),
                         [NSFont fontWithName:@"Avenir Next Demi Bold" size:12.0],
                         accent);

        y += chipHeight + gapBetweenCards;
    }
}

- (void)drawPhaseSummaryInRect:(NSRect)bounds {
    const auto activePhase = std::find_if(
        _status.delivery_phases.begin(),
        _status.delivery_phases.end(),
        [](const beatdrop::core::DeliveryPhase& phase) {
            return phase.status == beatdrop::core::WorkStatus::in_progress;
        });

    if (activePhase == _status.delivery_phases.end()) {
        return;
    }

    FillRoundedRect(bounds, 24.0, [BeatDropSky(0.14) colorWithAlphaComponent:0.14]);

    DrawLabel(@"CURRENT PHASE",
              NSMakePoint(NSMinX(bounds) + 20.0, NSMinY(bounds) + 18.0),
              [NSFont fontWithName:@"Avenir Next Demi Bold" size:12.0],
              BeatDropSky(1.0));

    DrawLabel(ToNSString(activePhase->name),
              NSMakePoint(NSMinX(bounds) + 20.0, NSMinY(bounds) + 38.0),
              [NSFont fontWithName:@"Avenir Next Demi Bold" size:18.0],
              [NSColor colorWithWhite:0.99 alpha:1.0]);

    DrawTextBlock(ToNSString(activePhase->outcome),
                  NSMakeRect(NSMinX(bounds) + 20.0, NSMinY(bounds) + 62.0, NSWidth(bounds) - 40.0, NSHeight(bounds) - 76.0),
                  [NSFont fontWithName:@"Avenir Next Regular" size:13.0],
                  [NSColor colorWithWhite:0.90 alpha:0.74]);
}

- (void)drawRendererSummaryInRect:(NSRect)bounds {
    if (!_presetEngine) {
        return;
    }

    FillRoundedRect(bounds, 24.0, [BeatDropAmber(0.12) colorWithAlphaComponent:0.12]);

    NSString* readiness = _presetState.backend_available
        ? @"RENDERER LIVE"
        : (_presetState.supports_live_visualization ? @"FALLBACK LIVE" : @"SEAM ACTIVE");
    NSString* engineName = ToNSString(_presetEngine->engine_name());
    NSString* presets = ToNSString(
        std::string("Presets: ") + std::to_string(_presetState.preset_count) +
        " | Active: " + (_presetState.active_preset_name.empty() ? std::string("none") : _presetState.active_preset_name));
    NSString* surface = ToNSString(
        std::string("Surface: ") + std::to_string(_presetState.surface.width_px) +
        "x" + std::to_string(_presetState.surface.height_px) +
        " @" + std::to_string(_presetState.surface.scale_factor));
    NSString* audio = ToNSString(
        std::string("Audio frames: ") + std::to_string(_presetState.audio_frames_ingested) +
        " | Dispatched: " + std::to_string(_runtimeStats.total_audio_frames_dispatched));
    NSString* energy = ToNSString(
        std::string("Peak/RMS: ") + std::to_string(_presetState.audio_peak) +
        " / " + std::to_string(_presetState.audio_rms) +
        " | Bands: " + std::to_string(_presetState.bass_energy) +
        "," + std::to_string(_presetState.mid_energy) +
        "," + std::to_string(_presetState.treble_energy));
    NSString* presetSession = ToNSString(
        std::string("Order: ") + std::string(beatdrop::core::to_string(_presetSessionState.selection_mode)) +
        " | Rating: " + std::to_string(_presetSessionState.active_rating) +
        " | History: " + std::to_string(_presetSessionState.history_size));
    NSString* presetLibrary = ToNSString(
        std::string("Library: ") +
        (_presetSessionState.library_root.empty() ? std::string("none") : _presetSessionState.library_root.filename().generic_string()));
    NSString* output = ToNSString(
        std::string("Output: ") +
        (_outputPublisher ? _outputPublisher->backend_name() : std::string("none")) +
        " | " +
        (_outputPublisher && _outputPublisher->enabled() ? std::string("enabled") : std::string("disabled")) +
        " | Clients: " +
        (_outputPublisher && _outputPublisher->has_clients() ? std::string("yes") : std::string("no")));
    const CGFloat leftInset = NSMinX(bounds) + 18.0;
    const CGFloat textWidth = std::max(0.0, NSWidth(bounds) - 36.0);
    CGFloat y = NSMinY(bounds) + 16.0;

    DrawFittedLine(@"RENDERER",
                   NSMakeRect(leftInset, y, std::max(0.0, textWidth - 124.0), 18.0),
                   [NSFont fontWithName:@"Avenir Next Demi Bold" size:15.0],
                   [NSColor colorWithWhite:0.98 alpha:1.0]);

    DrawCenteredText(readiness,
                     NSMakeRect(NSMaxX(bounds) - 138.0, y, 118.0, 18.0),
                     [NSFont fontWithName:@"Avenir Next Demi Bold" size:11.0],
                     BeatDropAmber(1.0));

    y += 22.0;
    DrawFittedLine(engineName,
                   NSMakeRect(leftInset, y, textWidth, 18.0),
                   [NSFont fontWithName:@"Menlo" size:11.5],
                   [NSColor colorWithWhite:0.90 alpha:0.80]);

    y += 18.0;
    DrawFittedLine(presets,
                   NSMakeRect(leftInset, y, textWidth, 18.0),
                   [NSFont fontWithName:@"Avenir Next Regular" size:12.5],
                   [NSColor colorWithWhite:0.92 alpha:0.78]);

    y += 18.0;
    DrawFittedLine(surface,
                   NSMakeRect(leftInset, y, textWidth, 18.0),
                   [NSFont fontWithName:@"Avenir Next Regular" size:12.5],
                   [NSColor colorWithWhite:0.92 alpha:0.78]);

    y += 18.0;
    DrawFittedLine(audio,
                   NSMakeRect(leftInset, y, textWidth, 18.0),
                   [NSFont fontWithName:@"Avenir Next Regular" size:12.5],
                   [NSColor colorWithWhite:0.92 alpha:0.78]);

    y += 18.0;
    DrawFittedLine(energy,
                   NSMakeRect(leftInset, y, textWidth, 18.0),
                   [NSFont fontWithName:@"Avenir Next Regular" size:11.5],
                   [NSColor colorWithWhite:0.92 alpha:0.70]);

    y += 18.0;
    DrawFittedLine(presetSession,
                   NSMakeRect(leftInset, y, textWidth, 18.0),
                   [NSFont fontWithName:@"Avenir Next Regular" size:11.5],
                   [NSColor colorWithWhite:0.92 alpha:0.70]);

    y += 18.0;
    DrawFittedLine(presetLibrary,
                   NSMakeRect(leftInset, y, textWidth, 18.0),
                   [NSFont fontWithName:@"Avenir Next Regular" size:11.5],
                   [NSColor colorWithWhite:0.92 alpha:0.70]);

    y += 18.0;
    DrawFittedLine(output,
                   NSMakeRect(leftInset, y, textWidth, 18.0),
                   [NSFont fontWithName:@"Avenir Next Regular" size:11.5],
                   [NSColor colorWithWhite:0.92 alpha:0.70]);

    y += 20.0;
    DrawTextBlock(ToNSString(
                      _presetSessionState.detail + " " + _presetState.detail + " " +
                      (_outputPublisher ? _outputPublisher->detail() : std::string())),
                  NSMakeRect(leftInset, y, NSWidth(bounds) - 36.0, NSMaxY(bounds) - y - 16.0),
                  [NSFont fontWithName:@"Avenir Next Regular" size:10.5],
                  [NSColor colorWithWhite:0.92 alpha:0.62]);
}

- (void)drawAudioModeCardsInRect:(NSRect)bounds {
    if (_audioModes.empty() || NSHeight(bounds) <= 0.0) {
        return;
    }

    const CGFloat gapBetweenCards = 16.0;
    const CGFloat cardHeight = std::max(
        118.0,
        (NSHeight(bounds) - gapBetweenCards * (_audioModes.size() - 1)) / static_cast<CGFloat>(_audioModes.size()));
    CGFloat y = NSMinY(bounds);

    for (const auto& mode : _audioModes) {
        const NSRect cardRect = NSMakeRect(NSMinX(bounds), y, NSWidth(bounds), cardHeight);
        FillRoundedRect(cardRect, 24.0, [NSColor colorWithCalibratedWhite:1.0 alpha:0.06]);

        NSColor* accent = mode.platform_supported ? BeatDropSky(0.95) : BeatDropRose(0.95);
        NSString* headline = ToNSString(UppercaseCopy(std::string(beatdrop::core::to_string(mode.mode))));
        NSString* readiness = mode.capture_ready
            ? @"LIVE PCM"
            : (mode.platform_supported ? @"PLATFORM READY" : @"UNAVAILABLE");
        const std::size_t bufferedFrames = (mode.capture_ready && _audioService)
            ? _audioService->buffered_frame_count()
            : 0;
        const CGFloat textWidth = std::max(0.0, NSWidth(cardRect) - 36.0);

        DrawFittedLine(headline,
                       NSMakeRect(NSMinX(cardRect) + 18.0, NSMinY(cardRect) + 16.0, std::max(0.0, textWidth - 124.0), 18.0),
                       [NSFont fontWithName:@"Avenir Next Demi Bold" size:15.0],
                       [NSColor colorWithWhite:0.98 alpha:1.0]);

        DrawCenteredText(readiness,
                         NSMakeRect(NSMaxX(cardRect) - 144.0, NSMinY(cardRect) + 16.0, 118.0, 18.0),
                         [NSFont fontWithName:@"Avenir Next Demi Bold" size:11.0],
                         accent);

        NSString* backend = ToNSString(mode.backend_name);
        NSString* permission = ToNSString(std::string("Permission: ") + std::string(beatdrop::core::to_string(mode.permission_state)));
        NSString* devices = ToNSString(std::string("Devices: ") + std::to_string(mode.devices.size()) + " | Default: " + DefaultDeviceName(mode));
        NSString* buffered = ToNSString(std::string("Buffered frames: ") + std::to_string(bufferedFrames));

        DrawFittedLine(backend,
                       NSMakeRect(NSMinX(cardRect) + 18.0, NSMinY(cardRect) + 38.0, textWidth, 18.0),
                       [NSFont fontWithName:@"Menlo" size:11.5],
                       [NSColor colorWithWhite:0.90 alpha:0.80]);

        DrawFittedLine(permission,
                       NSMakeRect(NSMinX(cardRect) + 18.0, NSMinY(cardRect) + 56.0, textWidth, 18.0),
                       [NSFont fontWithName:@"Avenir Next Regular" size:12.5],
                       [NSColor colorWithWhite:0.92 alpha:0.78]);

        DrawFittedLine(devices,
                       NSMakeRect(NSMinX(cardRect) + 18.0, NSMinY(cardRect) + 74.0, textWidth, 18.0),
                       [NSFont fontWithName:@"Avenir Next Regular" size:12.5],
                       [NSColor colorWithWhite:0.92 alpha:0.78]);

        DrawFittedLine(buffered,
                       NSMakeRect(NSMinX(cardRect) + 18.0, NSMinY(cardRect) + 92.0, textWidth, 18.0),
                       [NSFont fontWithName:@"Avenir Next Regular" size:12.5],
                       [NSColor colorWithWhite:0.92 alpha:0.78]);

        DrawTextBlock(ToNSString(mode.detail),
                      NSMakeRect(NSMinX(cardRect) + 18.0, NSMinY(cardRect) + 110.0, NSWidth(cardRect) - 36.0, std::max(18.0, cardHeight - 122.0)),
                      [NSFont fontWithName:@"Avenir Next Regular" size:11.5],
                      [NSColor colorWithWhite:0.92 alpha:0.62]);

        y += cardHeight + gapBetweenCards;
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;

    if (_toastMessage != nil && CFAbsoluteTimeGetCurrent() > _toastExpirationTime) {
        _toastMessage = nil;
    }

    const NSRect bounds = self.bounds;
    const NSRect frame = NSInsetRect(bounds, 26.0, 26.0);
    const double t = CFAbsoluteTimeGetCurrent() - _startTime;

    if (_renderFullscreen) {
        [[NSColor blackColor] setFill];
        NSRectFill(bounds);
        if (_presetEngine && _presetEngine->has_latest_frame()) {
            DrawRenderedFrame(bounds, *_presetEngine);
        } else {
            [self drawBackgroundInRect:bounds];
            DrawReactiveHalo(bounds, _presetState, t);
        }
        if (_toastMessage != nil) {
            const CGFloat toastWidth = std::min(404.0, std::max(220.0, NSWidth(bounds) - 96.0));
            const NSRect toastRect = NSMakeRect(
                (NSWidth(bounds) - toastWidth) / 2.0, 24.0, toastWidth, 48.0);
            FillRoundedRect(toastRect, 18.0, [NSColor colorWithCalibratedWhite:0.0 alpha:0.6]);
            DrawTextBlock(_toastMessage,
                          NSInsetRect(toastRect, 18.0, 12.0),
                          [NSFont fontWithName:@"Avenir Next Demi Bold" size:12.5],
                          [NSColor colorWithWhite:0.98 alpha:0.94]);
        }
        return;
    }

    [self drawBackgroundInRect:bounds];

    const CGFloat sectionGap = 22.0;
    NSRect contentRect = NSInsetRect(frame, 18.0, 18.0);
    const CGFloat sidebarWidth = std::clamp(NSWidth(contentRect) * 0.30, 340.0, 400.0);
    NSRect sidebarRect = TakeRightRect(contentRect, sidebarWidth, sectionGap);
    NSRect footerRect = TakeBottomRect(contentRect, 82.0, 18.0);
    NSRect headerRect = TakeTopRect(contentRect, 132.0, 20.0);
    NSRect bodyRect = contentRect;
    CGFloat infoWidth = std::clamp(NSWidth(bodyRect) * 0.44, 420.0, 560.0);
    if (NSWidth(bodyRect) - infoWidth < 280.0) {
        infoWidth = std::max(320.0, NSWidth(bodyRect) - 280.0);
    }
    const NSRect capabilityRect = NSMakeRect(NSMinX(bodyRect), NSMinY(bodyRect), infoWidth, NSHeight(bodyRect));
    NSRect visualColumnRect = NSMakeRect(
        NSMinX(bodyRect) + infoWidth + sectionGap,
        NSMinY(bodyRect),
        std::max(0.0, NSWidth(bodyRect) - infoWidth - sectionGap),
        NSHeight(bodyRect));
    NSRect statsRect = TakeTopRect(visualColumnRect, 84.0, 16.0);
    const NSRect visualizerCardRect = visualColumnRect;
    NSRect visualizerContentRect = NSInsetRect(visualizerCardRect, 18.0, 18.0);
    const NSRect titleStripRect = TakeTopRect(visualizerContentRect, 28.0, 12.0);
    const NSRect waveRect = TakeBottomRect(visualizerContentRect, 82.0, 0.0);
    const NSRect barsRect = visualizerContentRect;
    NSRect sidebarFlowRect = sidebarRect;
    const NSRect phaseRect = TakeTopRect(sidebarFlowRect, 112.0, 16.0);
    const NSRect rendererRect = TakeTopRect(sidebarFlowRect, 252.0, 16.0);
    const NSRect audioCardsRect = sidebarFlowRect;

    FillRoundedRect(visualizerCardRect, 28.0, [NSColor colorWithCalibratedWhite:1.0 alpha:0.05]);
    if (_presetEngine && _presetEngine->has_latest_frame()) {
        DrawRenderedFrame(visualizerCardRect, *_presetEngine);
        FillRoundedRect(NSInsetRect(waveRect, -10.0, -12.0), 18.0, [BeatDropInk(0.34) colorWithAlphaComponent:0.34]);
        DrawReactiveWave(waveRect, _presetState, t);
    } else {
        DrawReactiveHalo(barsRect, _presetState, t);
        [self drawAnimatedBarsInRect:barsRect time:t];
        DrawReactiveWave(waveRect, _presetState, t);
    }
    [self drawStatsInRect:statsRect];
    [self drawRendererSummaryInRect:rendererRect];
    [self drawPhaseSummaryInRect:phaseRect];
    [self drawAudioModeCardsInRect:audioCardsRect];

    DrawLabel(@"BeatDrop Mac Port",
              NSMakePoint(NSMinX(headerRect), NSMinY(headerRect) + 8.0),
              [NSFont fontWithName:@"Avenir Next Condensed Heavy" size:42.0],
              [NSColor colorWithWhite:0.99 alpha:1.0]);

    DrawTextBlock(
        _presetState.backend_available
            ? @"Native macOS shell with live system audio capture and libprojectM rendering."
            : @"Native macOS shell with live system audio capture and a real fallback visualizer path.",
        NSMakeRect(NSMinX(headerRect), NSMinY(headerRect) + 54.0, NSWidth(headerRect), 24.0),
        [NSFont fontWithName:@"Avenir Next Regular" size:16.0],
        [NSColor colorWithWhite:0.92 alpha:0.80]);

    DrawTextBlock(@"Target feature parity: MilkDrop preset compatibility, reactive audio capture, and Syphon-friendly output.",
                  NSMakeRect(NSMinX(headerRect), NSMinY(headerRect) + 78.0, NSWidth(headerRect), 24.0),
                  [NSFont fontWithName:@"Avenir Next Regular" size:16.0],
                  [NSColor colorWithWhite:0.92 alpha:0.68]);

    DrawTextBlock(ToNSString(_status.current_focus),
                  NSMakeRect(NSMinX(headerRect), NSMinY(headerRect) + 104.0, NSWidth(headerRect), 22.0),
                  [NSFont fontWithName:@"Avenir Next Regular" size:14.0],
                  [NSColor colorWithWhite:0.92 alpha:0.64]);

    FillRoundedRect(NSMakeRect(NSMinX(headerRect), NSMaxY(headerRect) - 38.0, 170.0, 34.0), 17.0, [BeatDropSky(0.18) colorWithAlphaComponent:0.18]);
    DrawCenteredText(@"PHASE 6 ACTIVE",
                     NSMakeRect(NSMinX(headerRect) + 10.0, NSMaxY(headerRect) - 30.0, 150.0, 18.0),
                     [NSFont fontWithName:@"Avenir Next Demi Bold" size:12.0],
                     BeatDropSky(1.0));

    DrawFittedLine(ToNSString(
                       _presetState.active_preset_name.empty()
                           ? (_presetState.backend_available
                                  ? std::string("libprojectM live render")
                                  : std::string("Fallback visualizer"))
                           : std::string("Active preset: ") + _presetState.active_preset_name),
                   titleStripRect,
                   [NSFont fontWithName:@"Avenir Next Demi Bold" size:14.0],
                   [NSColor colorWithWhite:0.97 alpha:0.88]);

    DrawTextBlock(@"Controls: Left/Right browse, Space or R randomize, S toggles order, O toggles Syphon, drop a .milk file or preset folder to reload.",
                  NSMakeRect(NSMinX(footerRect), NSMinY(footerRect) + 6.0, NSWidth(footerRect), 20.0),
                  [NSFont fontWithName:@"Avenir Next Regular" size:13.0],
                  [NSColor colorWithWhite:0.92 alpha:0.66]);

    DrawTextBlock(@"Capture: Ctrl+X or Cmd+X saves a PNG screenshot of the live macOS renderer.",
                  NSMakeRect(NSMinX(footerRect), NSMinY(footerRect) + 30.0, NSWidth(footerRect), 20.0),
                  [NSFont fontWithName:@"Avenir Next Regular" size:13.0],
                  [NSColor colorWithWhite:0.92 alpha:0.66]);

    [self drawCapabilityChipsInRect:capabilityRect];

    if (_toastMessage != nil) {
        const CGFloat toastWidth = std::min(404.0, std::max(220.0, NSWidth(frame) - 96.0));
        const NSRect toastRect = NSMakeRect(NSMaxX(frame) - toastWidth - 34.0, NSMinY(headerRect), toastWidth, 48.0);
        FillRoundedRect(toastRect, 18.0, [BeatDropAmber(0.16) colorWithAlphaComponent:0.16]);
        DrawTextBlock(_toastMessage,
                      NSInsetRect(toastRect, 18.0, 12.0),
                      [NSFont fontWithName:@"Avenir Next Demi Bold" size:12.5],
                      [NSColor colorWithWhite:0.98 alpha:0.94]);
    }
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation AppDelegate {
    NSWindow* _window;
    std::shared_ptr<beatdrop::core::IniConfigStore> _configStore;
    std::filesystem::path _repoRoot;
}

- (void)persistWindowFrame {
    if (_configStore && _window != nil) {
        PersistWindowFrameToConfig(*_configStore, _window);
    }
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;

    beatdrop::core::ProjectStatus status = beatdrop::core::collect_project_status(BEATDROP_SOURCE_DIR);
    _repoRoot = status.repo_root.empty() ? std::filesystem::path(BEATDROP_SOURCE_DIR) : status.repo_root;
    _configStore = CreateConfigStore(_repoRoot);

    const bool startBorderless = _configStore != nullptr &&
        _configStore->get_bool("settings.bBorderlessOnStartup", false);
    const bool startFullscreen = _configStore != nullptr &&
        _configStore->get_bool("settings.bFullscreenOnStartup", false);
    const bool alwaysOnTop = _configStore != nullptr &&
        _configStore->get_bool("settings.bAlwaysOnTop", false);

    const NSRect frame = WindowFrameFromConfig(_configStore.get(), [NSScreen mainScreen]);
    const NSWindowStyleMask styleMask = startBorderless
        ? (NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
        : (NSWindowStyleMaskTitled |
           NSWindowStyleMaskClosable |
           NSWindowStyleMaskMiniaturizable |
           NSWindowStyleMaskResizable);

    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:styleMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"BeatDrop Music Visualizer"];
    [_window setDelegate:self];
    [_window setMovableByWindowBackground:startBorderless];
    [_window setLevel:alwaysOnTop ? NSFloatingWindowLevel : NSNormalWindowLevel];
    [_window setMinSize:MinimumWindowSizeForScreen([NSScreen mainScreen])];
    BeatDropPortView* portView = [[BeatDropPortView alloc] initWithFrame:frame
                                                                  status:std::move(status)
                                                             configStore:_configStore];
    [_window setContentView:portView];
    [_window makeFirstResponder:portView];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self persistWindowFrame];

    if (startFullscreen) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_window toggleFullScreen:nil];
        });
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

- (void)windowDidMove:(NSNotification*)notification {
    (void)notification;
    [self persistWindowFrame];
}

- (void)windowDidResize:(NSNotification*)notification {
    (void)notification;
    [self persistWindowFrame];
}

- (void)windowDidEnterFullScreen:(NSNotification*)notification {
    (void)notification;
    if (_configStore) {
        _configStore->set_bool("settings.bFullscreenOnStartup", true);
        (void)_configStore->save();
    }
}

- (void)windowDidExitFullScreen:(NSNotification*)notification {
    (void)notification;
    if (_configStore) {
        _configStore->set_bool("settings.bFullscreenOnStartup", false);
        (void)_configStore->save();
    }
    [self persistWindowFrame];
}

@end

NSMenu* CreateMainMenu() {
    NSMenu* menuBar = [[NSMenu alloc] init];
    NSMenuItem* appMenuItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appMenuItem];

    NSMenu* appMenu = [[NSMenu alloc] init];
    NSString* quitTitle = [@"Quit " stringByAppendingString:[[NSProcessInfo processInfo] processName]];
    NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:quitTitle
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    [appMenuItem setSubmenu:appMenu];

    return menuBar;
}

int main(int argc, const char* argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app setDelegate:delegate];
        [app setMainMenu:CreateMainMenu()];
        [app run];
    }

    return 0;
}
