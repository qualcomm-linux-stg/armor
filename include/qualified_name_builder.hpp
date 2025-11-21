#pragma once

#include <string>

#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"

class QualifiedNameBuilder {
public:
    void push(llvm::StringRef Name);
    void pop();
    llvm::StringRef get() const;
    std::string getAsString() const;

private:
    llvm::SmallString<256> buffer;
    llvm::SmallVector<size_t, 16> offsets;
};
