// Minimal libASPL Client stub
#pragma once

#include <memory>
#include <string>
#include <CoreAudio/AudioServerPlugIn.h>

namespace aspl {

class Client : public std::enable_shared_from_this<Client> {
public:
    Client() = default;
    virtual ~Client() = default;

    virtual UInt32 GetClientID() const { return clientID_; }
    virtual pid_t GetProcessID() const { return processID_; }
    virtual std::string GetBundleID() const { return bundleID_; }
    virtual bool GetIsNativeEndian() const { return true; }

    void SetClientID(UInt32 id) { clientID_ = id; }
    void SetProcessID(pid_t pid) { processID_ = pid; }
    void SetBundleID(const std::string& bid) { bundleID_ = bid; }

private:
    UInt32 clientID_ = 0;
    pid_t processID_ = 0;
    std::string bundleID_;
};

} // namespace aspl
