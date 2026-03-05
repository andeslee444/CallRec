// SmartRouter — Routes different audio to different client apps.
//
// The key insight: this is a virtual INPUT device, so each app calls
// ReadInput independently. We can fill different data for each caller.
// Voice Memos gets the mixed stream (both sides), while Teams/Zoom
// get mic-only (preventing their own audio from echoing back).

#include "SmartRouter.hpp"
#include <cstring>

namespace CallRec {

SmartRouter::SmartRouter()
{
    // Try initial attach. If the app isn't running yet, we'll retry
    // lazily on each IO call.
    mReader.TryAttach();
}

SmartRouter::~SmartRouter() = default;

void SmartRouter::OnReadClientInput(
    const std::shared_ptr<aspl::Client>& client,
    const std::shared_ptr<aspl::Stream>& stream,
    Float64 zeroTimestamp,
    Float64 timestamp,
    void* bytes,
    UInt32 bytesCount)
{
    (void)stream;
    (void)zeroTimestamp;
    (void)timestamp;

    auto* dest = static_cast<float*>(bytes);
    UInt32 frameCount = bytesCount / sizeof(float);

    // Ensure we're attached to shared memory
    if (!mReader.IsAlive()) {
        mReader.TryAttach();
        if (!mReader.IsAlive()) {
            // App not running — output silence
            memset(dest, 0, bytesCount);
            return;
        }
    }

    // Route based on client identity
    int route = GetRoute(client);

    if (route == CALLREC_ROUTE_MIXED) {
        mReader.ReadMixed(dest, frameCount);
    } else {
        mReader.ReadMicOnly(dest, frameCount);
    }
}

int SmartRouter::GetRoute(const std::shared_ptr<aspl::Client>& client)
{
    if (!client) {
        return CALLREC_ROUTE_MIC_ONLY;
    }

    UInt32 clientID = client->GetClientID();

    // Fast path: check cache without lock (safe because we only ever
    // add entries, never remove, and UInt32 reads are atomic on all archs)
    {
        // Note: unordered_map::find is NOT thread-safe with concurrent insert.
        // Since AddClient/RemoveClient are infrequent and non-realtime,
        // we accept the brief lock here.
        std::lock_guard<std::mutex> lock(mRouteMutex);

        auto it = mClientRoutes.find(clientID);
        if (it != mClientRoutes.end()) {
            return it->second;
        }
    }

    // Cache miss — determine route from bundle ID
    std::string bundleID = client->GetBundleID();
    int route = CALLREC_ROUTE_MIC_ONLY;  // Safe default

    if (bundleID == CALLREC_BUNDLE_VOICE_MEMOS) {
        route = CALLREC_ROUTE_MIXED;
    }
    // Teams and Zoom get mic-only (already the default, but explicit for clarity)
    // else if (bundleID == CALLREC_BUNDLE_TEAMS || bundleID == CALLREC_BUNDLE_ZOOM) {
    //     route = CALLREC_ROUTE_MIC_ONLY;
    // }

    // Cache the result
    {
        std::lock_guard<std::mutex> lock(mRouteMutex);
        mClientRoutes[clientID] = route;
    }

    return route;
}

} // namespace CallRec
