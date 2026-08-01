#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>

namespace fs = std::filesystem;

using Entry = int (*)(void*);

int wmain(int argc, wchar_t** argv) {
    if (argc != 3) {
        std::wcerr << L"usage: NativeSmoke <dll> <runtime-root>\n";
        return 2;
    }
    const fs::path dllPath = fs::absolute(argv[1]);
    const fs::path runtimeRoot = fs::absolute(argv[2]);
    HMODULE module = LoadLibraryW(dllPath.c_str());
    if (!module) {
        std::wcerr << L"LoadLibrary failed: " << GetLastError() << L"\n";
        return 3;
    }
    const auto initialize =
        reinterpret_cast<Entry>(GetProcAddress(module, "TeleportLiteInitialize"));
    const auto dispatch =
        reinterpret_cast<Entry>(GetProcAddress(module, "TeleportLiteDispatch"));
    const auto shutdown =
        reinterpret_cast<Entry>(GetProcAddress(module, "TeleportLiteShutdown"));
    if (!initialize || !dispatch || !shutdown) {
        std::wcerr << L"required export missing\n";
        FreeLibrary(module);
        return 4;
    }
    initialize(nullptr);
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    {
        std::ofstream command(runtimeRoot / "TeleportLite_command.txt",
                              std::ios::binary | std::ios::trunc);
        command << "LIST\n";
    }
    dispatch(nullptr);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    shutdown(nullptr);
    FreeLibrary(module);
    if (!fs::exists(runtimeRoot / "TeleportLite_nodes.tsv") ||
        !fs::exists(runtimeRoot / "TeleportLite_status.txt") ||
        !fs::exists(runtimeRoot / "TeleportLite_native_diag.txt")) {
        std::wcerr << L"expected runtime files missing\n";
        return 5;
    }
    std::wcout << L"native hidden-load smoke test passed\n";
    return 0;
}
