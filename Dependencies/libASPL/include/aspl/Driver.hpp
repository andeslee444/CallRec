// Minimal libASPL Driver stub
//
// In the real libASPL, Driver implements the AudioServerPlugIn interface
// and delegates to Plugin/Device/Stream objects. This stub provides the
// minimal API surface our PluginEntry.cpp uses.
#pragma once

#include <memory>
#include <CoreAudio/AudioServerPlugIn.h>
#include "Context.hpp"
#include "Plugin.hpp"
#include "Storage.hpp"

namespace aspl {

class Driver : public std::enable_shared_from_this<Driver> {
public:
    Driver(std::shared_ptr<Context> context = {},
           std::shared_ptr<Plugin> plugin = {},
           std::shared_ptr<Storage> storage = {})
        : context_(context ? context : std::make_shared<Context>()),
          plugin_(plugin ? plugin : std::make_shared<Plugin>()),
          storage_(storage ? storage : std::make_shared<Storage>())
    {
        // In the real libASPL this sets up the AudioServerPlugInDriverInterface
        // vtable. For stub purposes we just store a reference pointer.
        reference_ = this;
    }

    virtual ~Driver() = default;

    // Returns the AudioServerPlugInDriverRef that coreaudiod expects
    // from the factory function. In a real driver this points to the
    // COM-like interface vtable.
    void* GetReference() {
        return static_cast<void*>(&reference_);
    }

    std::shared_ptr<Context> GetContext() const { return context_; }
    std::shared_ptr<Plugin> GetPlugin() const { return plugin_; }
    std::shared_ptr<Storage> GetStorage() const { return storage_; }

private:
    std::shared_ptr<Context> context_;
    std::shared_ptr<Plugin> plugin_;
    std::shared_ptr<Storage> storage_;
    Driver* reference_ = nullptr;
};

} // namespace aspl
