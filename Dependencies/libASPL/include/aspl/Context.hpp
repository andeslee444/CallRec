// Minimal libASPL Context stub for offline compilation
#pragma once

#include <memory>
#include <string>

namespace aspl {

class Context : public std::enable_shared_from_this<Context> {
public:
    Context() = default;
    virtual ~Context() = default;
};

} // namespace aspl
