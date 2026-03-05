#ifndef CALLREC_AUDIO_CONSTANTS_H
#define CALLREC_AUDIO_CONSTANTS_H

// ─── Audio Format ────────────────────────────────────────────
#define CALLREC_SAMPLE_RATE       48000
#define CALLREC_CHANNELS          1        // mono
#define CALLREC_BIT_DEPTH         32       // Float32
#define CALLREC_BYTES_PER_SAMPLE  4        // sizeof(Float32)

// ─── Ring Buffer Sizing ──────────────────────────────────────
// 1 second of audio at 48kHz mono Float32 = 192KB
// We use 2 seconds per ring buffer for comfortable headroom
#define CALLREC_RING_BUFFER_FRAMES    (CALLREC_SAMPLE_RATE * 2)  // 96000 frames
#define CALLREC_RING_BUFFER_BYTES     (CALLREC_RING_BUFFER_FRAMES * CALLREC_BYTES_PER_SAMPLE)

// ─── Shared Memory ───────────────────────────────────────────
#define CALLREC_SHM_NAME          "/callrec_audio_bridge"

// Heartbeat: app writes timestamp every 100ms, driver considers
// data stale after 500ms of no heartbeat update
#define CALLREC_HEARTBEAT_INTERVAL_MS   100
#define CALLREC_HEARTBEAT_TIMEOUT_MS    500

// ─── Virtual Device Identity ─────────────────────────────────
#define CALLREC_DEVICE_UID            "com.callrec.virtual-mic"
#define CALLREC_DEVICE_NAME           "CallRec Virtual Mic"
#define CALLREC_DEVICE_MANUFACTURER   "CallRec"
#define CALLREC_DRIVER_BUNDLE_ID      "com.callrec.driver"

// ─── Monitored App Bundle IDs ────────────────────────────────
#define CALLREC_BUNDLE_ZOOM           "us.zoom.xos"
#define CALLREC_BUNDLE_TEAMS          "com.microsoft.teams2"
#define CALLREC_BUNDLE_VOICE_MEMOS    "com.apple.VoiceMemos"

// ─── Routing Identifiers ────────────────────────────────────
#define CALLREC_ROUTE_MIC_ONLY    0
#define CALLREC_ROUTE_MIXED       1

// ─── Bluetooth Latency ──────────────────────────────────────
#define CALLREC_BT_DEFAULT_LATENCY_MS     150
#define CALLREC_BT_MAX_LATENCY_MS         500
#define CALLREC_USB_DEFAULT_LATENCY_MS    20

// ─── Cache Line Alignment ────────────────────────────────────
#define CALLREC_CACHE_LINE_SIZE   64

#endif // CALLREC_AUDIO_CONSTANTS_H
