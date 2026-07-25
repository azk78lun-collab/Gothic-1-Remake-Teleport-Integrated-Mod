#include <windows.h>

#include <cwchar>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

fs::path ModuleDirectory() {
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCWSTR>(&ModuleDirectory), &module)) {
        return {};
    }

    std::vector<wchar_t> buffer(32768);
    const DWORD length = GetModuleFileNameW(module, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0 || length >= buffer.size()) {
        return {};
    }
    return fs::path(std::wstring(buffer.data(), length)).parent_path();
}

fs::path PowerShellPath() {
    wchar_t windowsDirectory[MAX_PATH]{};
    const UINT length = GetWindowsDirectoryW(windowsDirectory, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) {
        return {};
    }
    return fs::path(std::wstring(windowsDirectory, length)) /
        L"System32\\WindowsPowerShell\\v1.0\\powershell.exe";
}

void WriteStatus(const fs::path& directory, const std::string& state, DWORD errorCode = 0) {
    if (directory.empty()) {
        return;
    }
    std::ofstream out(directory / "TeleportUiNative_status.txt", std::ios::binary | std::ios::trunc);
    if (!out) {
        return;
    }
    out << "STATE=" << state << "\r\n";
    out << "ERROR=" << errorCode << "\r\n";
}

bool ProcessMatchesPath(DWORD pid, const fs::path& expectedPath) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) {
        return false;
    }

    DWORD exitCode = 0;
    if (!GetExitCodeProcess(process, &exitCode) || exitCode != STILL_ACTIVE) {
        CloseHandle(process);
        return false;
    }

    std::vector<wchar_t> buffer(32768);
    DWORD length = static_cast<DWORD>(buffer.size());
    if (!QueryFullProcessImageNameW(process, 0, buffer.data(), &length)) {
        CloseHandle(process);
        return false;
    }
    CloseHandle(process);

    const fs::path actualPath(std::wstring(buffer.data(), length));
    const std::wstring actual = fs::absolute(actualPath).lexically_normal().wstring();
    const std::wstring expected = fs::absolute(expectedPath).lexically_normal().wstring();
    return _wcsicmp(actual.c_str(), expected.c_str()) == 0;
}

}  // namespace

extern "C" __declspec(dllexport) int TeleportEnsureBridge(void*) {
    const fs::path directory = ModuleDirectory();
    try {
        const fs::path bridgePath = directory / "TeleportCppBridge.exe";
        const fs::path win64Directory = directory.parent_path().parent_path();
        const fs::path pidPath = win64Directory / "TeleportMod_cpp_bridge.pid";
        const fs::path actionsPath = win64Directory / "TeleportMod_cpp_actions.txt";

        if (directory.empty() || !fs::exists(bridgePath) || win64Directory.empty()) {
            WriteStatus(directory, "BRIDGE_FAILED_PATH", ERROR_FILE_NOT_FOUND);
            return 0;
        }

        DWORD oldPid = 0;
        if (fs::exists(pidPath)) {
            std::ifstream pidFile(pidPath);
            pidFile >> oldPid;
        }
        if (oldPid != 0 && ProcessMatchesPath(oldPid, bridgePath)) {
            WriteStatus(directory, "BRIDGE_ALREADY_RUNNING");
            return 0;
        }
        if (fs::exists(pidPath)) {
            fs::remove(pidPath);
        }

        // A newly started bridge reads from offset zero. Remove commands left by
        // an earlier game session before launching it.
        std::ofstream actions(actionsPath, std::ios::binary | std::ios::trunc);
        if (!actions) {
            WriteStatus(directory, "BRIDGE_FAILED_ACTION_RESET", ERROR_ACCESS_DENIED);
            return 0;
        }
        actions.close();

        std::wstring commandLine = L"\"" + bridgePath.wstring() +
            L"\" -Win64Dir \"" + win64Directory.wstring() + L"\"";
        std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
        mutableCommand.push_back(L'\0');

        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION process{};

        const BOOL created = CreateProcessW(
            bridgePath.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr, directory.c_str(),
            &startup, &process);
        if (!created) {
            WriteStatus(directory, "BRIDGE_FAILED_CREATE_PROCESS", GetLastError());
            return 0;
        }

        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        WriteStatus(directory, "BRIDGE_LAUNCHED");
    } catch (...) {
        WriteStatus(directory, "BRIDGE_FAILED_EXCEPTION", ERROR_UNHANDLED_EXCEPTION);
    }
    return 0;
}

extern "C" __declspec(dllexport) int TeleportLaunchUI(void*) {
    const fs::path directory = ModuleDirectory();
    const fs::path scriptPath = directory / "TeleportModUI.ps1";
    const fs::path powershellPath = PowerShellPath();

    if (directory.empty() || !fs::exists(scriptPath) || !fs::exists(powershellPath)) {
        WriteStatus(directory, "FAILED_PATH", ERROR_FILE_NOT_FOUND);
        return 0;
    }

    std::wstring commandLine = L"\"" + powershellPath.wstring() +
        L"\" -STA -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass "
        L"-WindowStyle Hidden -File \"" + scriptPath.wstring() + L"\"";
    std::vector<wchar_t> mutableCommand(commandLine.begin(), commandLine.end());
    mutableCommand.push_back(L'\0');

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION process{};

    const BOOL created = CreateProcessW(
        powershellPath.c_str(), mutableCommand.data(), nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr, directory.c_str(),
        &startup, &process);
    if (!created) {
        WriteStatus(directory, "FAILED_CREATE_PROCESS", GetLastError());
        return 0;
    }

    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    WriteStatus(directory, "LAUNCHED");
    return 0;
}
