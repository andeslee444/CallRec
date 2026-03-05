#ifndef CALLREC_SMART_ROUTER_HPP
#define CALLREC_SMART_ROUTER_HPP

// SmartRouter — Per-client audio routing for the virtual input device.
//
// When an app reads from "CallRec Virtual Mic":
//   - Voice Memos → gets mixed audio (mic + call participants)
//   - Teams/Zoom  → gets mic-only audio (no echo back into call)
//   - Other apps  → gets mic-only audio (safe default)
//
// This is implemented via OnReadClientInput, which receives a Client
// object whose GetBundleID() identifies the requesting app.

#include <aspl/IORequestHandler.hpp>
#include <aspl/Client.hpp>
#include <aspl/Stream.hpp>

#include "SharedMemoryReader.hpp"
#include "../Common/AudioConstants.h"

#include <string>
#include <unordered_map>
#include <mutex>

namespace CallRec {

class SmartRouter : public aspl::IORequestHandler {
public:
    SmartRouter();
    ~SmartRouter() override;

    // Called on the real-time IO thread when a client reads input audio.
    void OnReadClientInput(
        const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override;

private:
    // Determine routing for a client. Caches result per bundle ID.
    int GetRoute(const std::shared_ptr<aspl::Client>& client);

    SharedMemoryReader mReader;

    // Cache: bundle ID → route (CALLREC_ROUTE_MIC_ONLY or CALLREC_ROUTE_MIXED)
    // Populated on first IO from each client. Lock-free read path after first lookup.
    std::unordered_map<UInt32, int> mClientRoutes;
    std::mutex mRouteMutex;  // Only locked on cache miss (first IO from new client)
};

} // namespace CallRec

#endif // CALLREC_SMART_ROUTER_HPP
