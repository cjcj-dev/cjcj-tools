// Test-only adapter to the fixed, read-only native baseline. Never linked into
// cjtrace-recover and never installed or packaged. No grammar lives here.
#include "CangjieDemangle.h"
#include <iostream>
#include <string>

int main()
{
    std::string symbol;
    while (std::getline(std::cin, symbol)) {
        const auto info = Cangjie::Demangle(symbol);
        const auto package = info.GetPkgName();
        std::cout << package << (package.empty() ? "" : ".") << info.GetFullName() << '\n';
    }
    return std::cin.bad() ? 1 : 0;
}
