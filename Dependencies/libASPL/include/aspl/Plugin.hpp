// Minimal libASPL Plugin stub
#pragma once

#include <memory>
#include <vector>
#include "Context.hpp"
#include "Device.hpp"

namespace aspl {

class Plugin : public std::enable_shared_from_this<Plugin> {
public:
    Plugin(std::shared_ptr<const Context> context = {})
        : context_(context) {}
    virtual ~Plugin() = default;

    void AddDevice(std::shared_ptr<Device> device) {
        devices_.push_back(std::move(device));
    }

private:
    std::shared_ptr<const Context> context_;
    std::vector<std::shared_ptr<Device>> devices_;
};

} // namespace aspl
