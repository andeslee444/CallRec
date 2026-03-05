// Minimal libASPL Device stub
#pragma once

#include <memory>
#include <string>
#include <vector>
#include <CoreAudio/AudioServerPlugIn.h>
#include "Context.hpp"
#include "Stream.hpp"
#include "IORequestHandler.hpp"
#include "Client.hpp"

namespace aspl {

struct DeviceParameters {
    std::string Name = "libASPL Device";
    std::string Manufacturer = "libASPL";
    std::string DeviceUID;
    std::string ModelUID = "libaspl";
    std::string SerialNumber;
    UInt32 SampleRate = 44100;
    UInt32 ChannelCount = 2;
    UInt32 Latency = 0;
    UInt32 SafetyOffset = 0;
    bool CanBeDefault = true;
    bool CanBeDefaultForSystemSounds = true;
    bool EnableMixing = true;
    bool EnableRealtimeTracing = false;
    bool ClockIsStable = true;
    UInt32 ClockDomain = 0;
    UInt32 ZeroTimeStampPeriod = 0;
};

class Device : public std::enable_shared_from_this<Device> {
public:
    Device(std::shared_ptr<const Context> context,
           const DeviceParameters& params = {})
        : context_(context), params_(params) {}
    virtual ~Device() = default;

    const DeviceParameters& GetParameters() const { return params_; }

    void AddStream(std::shared_ptr<Stream> stream) {
        streams_.push_back(std::move(stream));
    }

    void SetIOHandler(std::shared_ptr<IORequestHandler> handler) {
        ioHandler_ = std::move(handler);
    }

    IORequestHandler* GetIOHandler() const { return ioHandler_.get(); }

    UInt32 GetClientCount() const { return static_cast<UInt32>(clients_.size()); }

private:
    std::shared_ptr<const Context> context_;
    DeviceParameters params_;
    std::vector<std::shared_ptr<Stream>> streams_;
    std::shared_ptr<IORequestHandler> ioHandler_;
    std::vector<std::shared_ptr<Client>> clients_;
};

} // namespace aspl
