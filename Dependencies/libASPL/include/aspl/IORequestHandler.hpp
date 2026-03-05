// Minimal libASPL IORequestHandler stub
#pragma once

#include <memory>
#include <CoreAudio/AudioServerPlugIn.h>
#include "Client.hpp"
#include "Stream.hpp"

namespace aspl {

class IORequestHandler {
public:
    virtual ~IORequestHandler() = default;

    // Called on the real-time IO thread when a client reads input from the device.
    virtual void OnReadClientInput(
        const std::shared_ptr<Client>& client,
        const std::shared_ptr<Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount)
    {
        (void)client; (void)stream; (void)zeroTimestamp;
        (void)timestamp; (void)bytes; (void)bytesCount;
    }

    // Called to process data returned by ReadClientInput before passing to client.
    virtual void OnProcessClientInput(
        const std::shared_ptr<Client>& client,
        const std::shared_ptr<Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount)
    {
        (void)client; (void)stream; (void)zeroTimestamp;
        (void)timestamp; (void)frames; (void)frameCount; (void)channelCount;
    }

    // Called when a client writes output to the device.
    virtual void OnWriteClientOutput(
        const std::shared_ptr<Client>& client,
        const std::shared_ptr<Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount)
    {
        (void)client; (void)stream; (void)zeroTimestamp;
        (void)timestamp; (void)frames; (void)frameCount; (void)channelCount;
    }
};

} // namespace aspl
