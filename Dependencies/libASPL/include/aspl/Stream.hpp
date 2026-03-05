// Minimal libASPL Stream stub
#pragma once

#include <memory>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudioTypes/CoreAudioTypes.h>
#include "Context.hpp"
#include "Direction.hpp"

namespace aspl {

class Device; // forward

struct StreamParameters {
    Direction Direction = Direction::Output;
    UInt32 StartingChannel = 1;
    AudioStreamBasicDescription Format = {
        .mSampleRate = 44100,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
        .mBitsPerChannel = 16,
        .mChannelsPerFrame = 2,
        .mBytesPerFrame = 4,
        .mFramesPerPacket = 1,
        .mBytesPerPacket = 4,
    };
    UInt32 Latency = 0;
};

class Stream : public std::enable_shared_from_this<Stream> {
public:
    Stream(std::shared_ptr<const Context> context,
           std::shared_ptr<Device> device,
           const StreamParameters& params = {})
        : context_(context), params_(params) {
        (void)device;
    }
    virtual ~Stream() = default;

    Direction GetDirection() const { return params_.Direction; }
    Float64 GetSampleRate() const { return params_.Format.mSampleRate; }
    UInt32 GetChannelCount() const { return params_.Format.mChannelsPerFrame; }

private:
    std::shared_ptr<const Context> context_;
    StreamParameters params_;
};

} // namespace aspl
