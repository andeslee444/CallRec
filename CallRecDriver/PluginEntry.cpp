// CallRec Virtual Audio Driver — Entry Point
//
// This AudioServerPlugin provides a virtual input device ("CallRec Virtual Mic")
// that reads audio from POSIX shared memory written by the CallRec app.
// It routes different audio to different client apps:
//   - Voice Memos → mixed audio (both sides of the call)
//   - Teams/Zoom  → mic-only audio (prevents echo back into the call)
//   - Others      → mic-only (safe default)

#include <CoreAudio/AudioServerPlugIn.h>
#include <aspl/Driver.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Device.hpp>
#include <aspl/Stream.hpp>

#include "SmartRouter.hpp"

#include <memory>

namespace {

std::shared_ptr<aspl::Driver> g_driver;

void InitializeDriver()
{
    // Create context with tracing for debug builds
    auto context = std::make_shared<aspl::Context>();

    // Configure virtual device: input-only, mono, 48kHz Float32
    aspl::DeviceParameters deviceParams;
    deviceParams.Name = CALLREC_DEVICE_NAME;
    deviceParams.Manufacturer = CALLREC_DEVICE_MANUFACTURER;
    deviceParams.DeviceUID = CALLREC_DEVICE_UID;
    deviceParams.ModelUID = "com.callrec.virtual-mic.model";
    deviceParams.SampleRate = CALLREC_SAMPLE_RATE;
    deviceParams.ChannelCount = CALLREC_CHANNELS;
    deviceParams.EnableMixing = false;  // We handle per-client routing ourselves
    deviceParams.CanBeDefault = true;
    deviceParams.CanBeDefaultForSystemSounds = false;
    deviceParams.Latency = 0;
    deviceParams.SafetyOffset = 0;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);

    // Create input stream: mono Float32 @ 48kHz
    aspl::StreamParameters streamParams;
    streamParams.Direction = aspl::Direction::Input;
    streamParams.StartingChannel = 1;

    // Float32 mono 48kHz linear PCM
    AudioStreamBasicDescription format = {};
    format.mSampleRate = CALLREC_SAMPLE_RATE;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat
                        | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagsNativeEndian;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = CALLREC_CHANNELS;
    format.mBytesPerFrame = format.mChannelsPerFrame * (format.mBitsPerChannel / 8);
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = format.mBytesPerFrame * format.mFramesPerPacket;
    streamParams.Format = format;
    streamParams.Latency = 0;

    auto stream = std::make_shared<aspl::Stream>(context, device, streamParams);
    device->AddStreamAsync(stream);

    // Attach our SmartRouter as the IO handler for per-client routing
    auto router = std::make_shared<CallRec::SmartRouter>();
    device->SetIOHandler(router);

    // Build plugin and driver
    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    g_driver = std::make_shared<aspl::Driver>(context, plugin);
}

} // anonymous namespace

// ─── Plugin Entry Point ──────────────────────────────────────
// Declared in Info.plist as the factory function.
// coreaudiod calls this when loading the plugin bundle.
extern "C" void* CallRecDriverCreate(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    (void)allocator;

    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    if (!g_driver) {
        InitializeDriver();
    }

    return g_driver->GetReference();
}
