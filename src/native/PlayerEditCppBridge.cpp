#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <cwctype>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr wchar_t kProcessExe[] = L"G1R-Win64-Shipping.exe";
constexpr DWORD kProcessAccess =
    PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE;

struct Paths {
    fs::path win64Dir;
    fs::path actions;
    fs::path state;
    fs::path diag;
    fs::path pid;
};

struct GameContext {
    DWORD pid = 0;
    HANDLE process = nullptr;
    uint64_t moduleBase = 0;
    uint64_t moduleSize = 0;
    GameContext() = default;
    GameContext(const GameContext&) = delete;
    GameContext& operator=(const GameContext&) = delete;
    GameContext(GameContext&& other) noexcept {
        pid = other.pid;
        process = other.process;
        moduleBase = other.moduleBase;
        moduleSize = other.moduleSize;
        other.process = nullptr;
    }
    GameContext& operator=(GameContext&& other) noexcept {
        if (this != &other) {
            if (process) {
                CloseHandle(process);
            }
            pid = other.pid;
            process = other.process;
            moduleBase = other.moduleBase;
            moduleSize = other.moduleSize;
            other.process = nullptr;
        }
        return *this;
    }
    ~GameContext() {
        if (process) {
            CloseHandle(process);
        }
    }
};

struct ProcessCandidate {
    DWORD pid = 0;
    bool pathMatches = false;
    bool hasWindow = false;
};

struct AttributeDef {
    const char* key;
    uint32_t groupOffset;
    uint32_t baseOffset;
    uint32_t currentOffset;
};

constexpr AttributeDef kAttributes[] = {
    {"Health", 0x0, 0x48, 0x4C},
    {"MaxHealth", 0x0, 0x58, 0x5C},
    {"Level", 0x10, 0x48, 0x4C},
    {"Experience", 0x10, 0x58, 0x5C},
    {"SkillPoints", 0x10, 0x68, 0x6C},
    {"Mana", 0x18, 0x48, 0x4C},
    {"MaxMana", 0x18, 0x58, 0x5C},
    {"Dexterity", 0x28, 0x48, 0x4C},
    {"Strength", 0x30, 0x48, 0x4C},
};

std::string NowText() {
    std::time_t now = std::time(nullptr);
    std::tm local{};
    localtime_s(&local, &now);
    std::ostringstream out;
    out << std::put_time(&local, "%Y-%m-%d %H:%M:%S");
    return out.str();
}

std::string Trim(std::string value) {
    const char* ws = " \t\r\n";
    const auto start = value.find_first_not_of(ws);
    if (start == std::string::npos) {
        return "";
    }
    const auto end = value.find_last_not_of(ws);
    return value.substr(start, end - start + 1);
}

std::string UpperAscii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::toupper(ch));
    });
    return value;
}

std::wstring LowerWide(std::wstring value) {
    std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {
        return static_cast<wchar_t>(std::towlower(ch));
    });
    return value;
}

std::string Hex(uint64_t value) {
    std::ostringstream out;
    out << "0x" << std::uppercase << std::hex << value;
    return out.str();
}

std::string FloatText(float value) {
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::fixed << std::setprecision(3) << value;
    std::string text = out.str();
    while (text.size() > 1 && text.back() == '0') {
        text.pop_back();
    }
    if (!text.empty() && text.back() == '.') {
        text.pop_back();
    }
    return text;
}

std::vector<std::string> SplitPipe(const std::string& line) {
    std::vector<std::string> parts;
    std::stringstream ss(line);
    std::string part;
    while (std::getline(ss, part, '|')) {
        parts.push_back(part);
    }
    return parts;
}

bool ParseFloat(const std::string& text, float& value) {
    const std::string trimmed = Trim(text);
    if (trimmed.empty()) {
        return false;
    }
    const char* first = trimmed.data();
    const char* last = trimmed.data() + trimmed.size();
    const auto parsed = std::from_chars(first, last, value, std::chars_format::general);
    return parsed.ec == std::errc{} && parsed.ptr == last;
}

void WriteText(const fs::path& path, const std::string& text, bool append) {
    std::ofstream out(path, std::ios::binary | (append ? std::ios::app : std::ios::trunc));
    if (out) {
        out << text;
    }
}

void WriteDiag(const Paths& paths, const std::string& message) {
    WriteText(paths.diag, "[" + NowText() + "] " + message + "\r\n", true);
}

void WriteState(
    const Paths& paths,
    const std::string& state,
    const std::string& message,
    const std::string& attr = "",
    const std::string& base = "",
    const std::string& current = "") {
    std::ostringstream out;
    out << "STATE=" << state << "\r\n";
    out << "MESSAGE=" << message << "\r\n";
    if (!attr.empty()) {
        out << "ATTR=" << attr << "\r\n";
    }
    if (!base.empty()) {
        out << "BASE=" << base << "\r\n";
    }
    if (!current.empty()) {
        out << "CURRENT=" << current << "\r\n";
    }
    out << "UPDATED=" << static_cast<long long>(std::time(nullptr)) << "\r\n";
    WriteText(paths.state, out.str(), false);
}

bool IsProcessAlive(DWORD pid) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) {
        return false;
    }
    DWORD code = 0;
    const bool alive = GetExitCodeProcess(process, &code) && code == STILL_ACTIVE;
    CloseHandle(process);
    return alive;
}

std::optional<std::wstring> QueryProcessPath(DWORD pid) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) {
        return std::nullopt;
    }

    std::wstring buffer(32768, L'\0');
    DWORD size = static_cast<DWORD>(buffer.size());
    if (!QueryFullProcessImageNameW(process, 0, buffer.data(), &size)) {
        CloseHandle(process);
        return std::nullopt;
    }

    CloseHandle(process);
    buffer.resize(size);
    return buffer;
}

BOOL CALLBACK EnumWindowsForPid(HWND hwnd, LPARAM lParam) {
    auto* data = reinterpret_cast<std::pair<DWORD, bool>*>(lParam);
    DWORD windowPid = 0;
    GetWindowThreadProcessId(hwnd, &windowPid);
    if (windowPid == data->first && IsWindowVisible(hwnd) && GetWindowTextLengthW(hwnd) > 0) {
        data->second = true;
        return FALSE;
    }
    return TRUE;
}

bool ProcessHasVisibleWindow(DWORD pid) {
    std::pair<DWORD, bool> data{pid, false};
    EnumWindows(EnumWindowsForPid, reinterpret_cast<LPARAM>(&data));
    return data.second;
}

std::optional<DWORD> FindProcessId(const fs::path& win64Dir) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) {
        return std::nullopt;
    }

    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    const std::wstring target = LowerWide(kProcessExe);
    const std::wstring expectedPath = LowerWide(fs::absolute(win64Dir / kProcessExe).wstring());
    std::vector<ProcessCandidate> candidates;

    for (BOOL ok = Process32FirstW(snap, &entry); ok; ok = Process32NextW(snap, &entry)) {
        if (LowerWide(entry.szExeFile) == target) {
            ProcessCandidate candidate;
            candidate.pid = entry.th32ProcessID;
            if (const auto path = QueryProcessPath(candidate.pid)) {
                candidate.pathMatches = LowerWide(*path) == expectedPath;
            }
            candidate.hasWindow = ProcessHasVisibleWindow(candidate.pid);
            candidates.push_back(candidate);
        }
    }

    CloseHandle(snap);
    if (candidates.empty()) {
        return std::nullopt;
    }

    std::sort(candidates.begin(), candidates.end(), [](const ProcessCandidate& a, const ProcessCandidate& b) {
        if (a.pathMatches != b.pathMatches) {
            return a.pathMatches > b.pathMatches;
        }
        if (a.hasWindow != b.hasWindow) {
            return a.hasWindow > b.hasWindow;
        }
        return a.pid > b.pid;
    });
    return candidates.front().pid;
}

void FillModuleInfo(GameContext& ctx) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, ctx.pid);
    if (snap == INVALID_HANDLE_VALUE) {
        throw std::runtime_error("module snapshot failed");
    }

    MODULEENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    const std::wstring target = LowerWide(kProcessExe);
    for (BOOL ok = Module32FirstW(snap, &entry); ok; ok = Module32NextW(snap, &entry)) {
        if (LowerWide(entry.szModule) == target) {
            ctx.moduleBase = reinterpret_cast<uint64_t>(entry.modBaseAddr);
            ctx.moduleSize = static_cast<uint64_t>(entry.modBaseSize);
            CloseHandle(snap);
            return;
        }
    }

    CloseHandle(snap);
    throw std::runtime_error("main module not found");
}

GameContext OpenGameProcess(const fs::path& win64Dir) {
    const auto pid = FindProcessId(win64Dir);
    if (!pid) {
        throw std::runtime_error("game process not found");
    }

    GameContext ctx;
    ctx.pid = *pid;
    ctx.process = OpenProcess(kProcessAccess, FALSE, ctx.pid);
    if (!ctx.process) {
        throw std::runtime_error("failed to open game process");
    }
    FillModuleInfo(ctx);
    return ctx;
}

std::vector<uint8_t> ReadBytes(HANDLE process, uint64_t address, size_t count) {
    std::vector<uint8_t> buffer(count);
    SIZE_T read = 0;
    if (!ReadProcessMemory(process, reinterpret_cast<LPCVOID>(address), buffer.data(), count, &read) ||
        read != count) {
        throw std::runtime_error("read memory failed " + Hex(address));
    }
    return buffer;
}

uint64_t ReadU64(HANDLE process, uint64_t address) {
    const auto bytes = ReadBytes(process, address, sizeof(uint64_t));
    uint64_t value = 0;
    std::memcpy(&value, bytes.data(), sizeof(value));
    return value;
}

int32_t ReadI32(HANDLE process, uint64_t address) {
    const auto bytes = ReadBytes(process, address, sizeof(int32_t));
    int32_t value = 0;
    std::memcpy(&value, bytes.data(), sizeof(value));
    return value;
}

float ReadF32(HANDLE process, uint64_t address) {
    const auto bytes = ReadBytes(process, address, sizeof(float));
    float value = 0.0f;
    std::memcpy(&value, bytes.data(), sizeof(value));
    return value;
}

void WriteF32(HANDLE process, uint64_t address, float value) {
    uint8_t bytes[sizeof(float)]{};
    std::memcpy(bytes, &value, sizeof(value));
    SIZE_T written = 0;
    if (!WriteProcessMemory(process, reinterpret_cast<LPVOID>(address), bytes, sizeof(bytes), &written) ||
        written != sizeof(bytes)) {
        throw std::runtime_error("write memory failed " + Hex(address));
    }
}

uint64_t FindPattern(const GameContext& ctx, const std::vector<uint8_t>& pattern, const std::vector<bool>& mask) {
    const uint64_t chunkSize = 0x400000;
    const uint64_t overlap = static_cast<uint64_t>(pattern.size());
    std::vector<uint8_t> tail;

    for (uint64_t offset = 0; offset < ctx.moduleSize;) {
        const size_t count = static_cast<size_t>(std::min(chunkSize, ctx.moduleSize - offset));
        std::vector<uint8_t> chunk;
        try {
            chunk = ReadBytes(ctx.process, ctx.moduleBase + offset, count);
        } catch (...) {
            offset += count;
            tail.clear();
            continue;
        }

        std::vector<uint8_t> scan;
        scan.reserve(tail.size() + chunk.size());
        scan.insert(scan.end(), tail.begin(), tail.end());
        scan.insert(scan.end(), chunk.begin(), chunk.end());

        const uint64_t scanBase = ctx.moduleBase + offset - static_cast<uint64_t>(tail.size());
        if (scan.size() >= pattern.size()) {
            for (size_t i = 0; i <= scan.size() - pattern.size(); ++i) {
                bool matched = true;
                for (size_t j = 0; j < pattern.size(); ++j) {
                    if (mask[j] && scan[i + j] != pattern[j]) {
                        matched = false;
                        break;
                    }
                }
                if (matched) {
                    return scanBase + static_cast<uint64_t>(i);
                }
            }
        }

        const size_t keep = static_cast<size_t>(std::min<uint64_t>(overlap, scan.size()));
        tail.assign(scan.end() - keep, scan.end());
        offset += count;
    }
    return 0;
}

uint64_t ResolveGEngine(const GameContext& ctx) {
    const std::vector<uint8_t> pattern = {
        0x48, 0x8B, 0x05, 0, 0, 0, 0, 0x48, 0x8B, 0x88, 0x80, 0x0A, 0x00, 0x00};
    const std::vector<bool> mask = {
        true, true, true, false, false, false, false, true, true, true, true, true, true, true};

    const uint64_t match = FindPattern(ctx, pattern, mask);
    if (!match) {
        throw std::runtime_error("pGEngine pattern not found");
    }
    const int32_t disp = ReadI32(ctx.process, match + 3);
    const uint64_t pointerAddress = static_cast<uint64_t>(static_cast<int64_t>(match) + 7 + disp);
    const uint64_t gEngine = ReadU64(ctx.process, pointerAddress);
    if (!gEngine) {
        throw std::runtime_error("GEngine is null, save may not be loaded");
    }
    return gEngine;
}

const AttributeDef* FindAttribute(const std::string& key) {
    for (const auto& attr : kAttributes) {
        if (UpperAscii(attr.key) == UpperAscii(key)) {
            return &attr;
        }
    }
    return nullptr;
}

uint64_t ResolveAttributeStruct(const GameContext& ctx, const AttributeDef& attr) {
    const uint64_t gEngine = ResolveGEngine(ctx);
    uint64_t ptr = ReadU64(ctx.process, gEngine + 0x10A8);
    const uint32_t chain[] = {0x38, 0x0, 0x30, 0x298, 0x218, 0x10, 0x1090, attr.groupOffset};
    for (uint32_t offset : chain) {
        if (!ptr) {
            throw std::runtime_error("attribute pointer chain hit null");
        }
        ptr = ReadU64(ctx.process, ptr + offset);
    }
    if (!ptr) {
        throw std::runtime_error("attribute struct is null");
    }
    return ptr;
}

void ReadAttribute(const Paths& paths, const std::string& key) {
    const AttributeDef* attr = FindAttribute(key);
    if (!attr) {
        throw std::runtime_error("unsupported attribute: " + key);
    }

    GameContext ctx = OpenGameProcess(paths.win64Dir);
    const uint64_t base = ResolveAttributeStruct(ctx, *attr);
    const float baseValue = ReadF32(ctx.process, base + attr->baseOffset);
    const float currentValue = ReadF32(ctx.process, base + attr->currentOffset);

    WriteDiag(paths, "READ attr=" + std::string(attr->key) + " struct=" + Hex(base) +
                         " base=" + FloatText(baseValue) + " current=" + FloatText(currentValue));
    WriteState(paths, "OK", "attribute read", attr->key, FloatText(baseValue), FloatText(currentValue));
}

void WriteAttribute(const Paths& paths, const std::string& key, const std::string& slot, float value) {
    const AttributeDef* attr = FindAttribute(key);
    if (!attr) {
        throw std::runtime_error("unsupported attribute: " + key);
    }

    const std::string mode = UpperAscii(slot);
    if (mode != "BASE" && mode != "CURRENT" && mode != "BOTH") {
        throw std::runtime_error("slot must be Base, Current, or Both");
    }

    GameContext ctx = OpenGameProcess(paths.win64Dir);
    const uint64_t base = ResolveAttributeStruct(ctx, *attr);
    if (mode == "BASE" || mode == "BOTH") {
        WriteF32(ctx.process, base + attr->baseOffset, value);
    }
    if (mode == "CURRENT" || mode == "BOTH") {
        WriteF32(ctx.process, base + attr->currentOffset, value);
    }

    const float baseValue = ReadF32(ctx.process, base + attr->baseOffset);
    const float currentValue = ReadF32(ctx.process, base + attr->currentOffset);
    WriteDiag(paths, "WRITE attr=" + std::string(attr->key) + " slot=" + mode +
                         " value=" + FloatText(value) + " struct=" + Hex(base) +
                         " base=" + FloatText(baseValue) + " current=" + FloatText(currentValue));
    WriteState(paths, "OK", "attribute write sent", attr->key, FloatText(baseValue), FloatText(currentValue));
}

void ProcessLine(const Paths& paths, const std::string& rawLine) {
    const std::string line = Trim(rawLine);
    if (line.empty()) {
        return;
    }

    const auto parts = SplitPipe(line);
    const std::string cmd = parts.empty() ? "" : UpperAscii(Trim(parts[0]));
    if (cmd == "ATTR_READ") {
        if (parts.size() < 2) {
            throw std::runtime_error("ATTR_READ requires AttributeKey");
        }
        ReadAttribute(paths, Trim(parts[1]));
    } else if (cmd == "ATTR_WRITE") {
        if (parts.size() < 4) {
            throw std::runtime_error("ATTR_WRITE requires AttributeKey|Base/Current/Both|value");
        }
        float value = 0.0f;
        if (!ParseFloat(parts[3], value)) {
            throw std::runtime_error("invalid attribute value");
        }
        WriteAttribute(paths, Trim(parts[1]), Trim(parts[2]), value);
    }
}

fs::path ArgPath(int argc, wchar_t** argv) {
    for (int i = 1; i < argc; ++i) {
        const std::wstring key = LowerWide(argv[i]);
        if ((key == L"-win64dir" || key == L"--win64" || key == L"/win64dir") && i + 1 < argc) {
            return fs::absolute(fs::path(argv[i + 1]));
        }
    }
    return fs::current_path();
}

std::string ReadRange(const fs::path& path, uint64_t start, uint64_t end) {
    if (end <= start) {
        return "";
    }
    std::string text(static_cast<size_t>(end - start), '\0');
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return "";
    }
    in.seekg(static_cast<std::streamoff>(start), std::ios::beg);
    in.read(text.data(), static_cast<std::streamsize>(text.size()));
    text.resize(static_cast<size_t>(in.gcount()));
    return text;
}

std::vector<std::string> SplitLines(const std::string& text) {
    std::vector<std::string> lines;
    std::stringstream ss(text);
    std::string line;
    while (std::getline(ss, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        lines.push_back(line);
    }
    return lines;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    Paths paths;
    paths.win64Dir = ArgPath(argc, argv);
    paths.actions = paths.win64Dir / "TeleportMod_player_actions.txt";
    paths.state = paths.win64Dir / "TeleportMod_player_state.txt";
    paths.diag = paths.win64Dir / "TeleportMod_player_diag.txt";
    paths.pid = paths.win64Dir / "TeleportMod_player_bridge.pid";

    try {
        if (fs::exists(paths.pid)) {
            std::ifstream oldPidFile(paths.pid);
            DWORD oldPid = 0;
            oldPidFile >> oldPid;
            if (oldPid && IsProcessAlive(oldPid)) {
                WriteState(paths, "IDLE", "player edit bridge already running");
                return 0;
            }
            fs::remove(paths.pid);
        }

        WriteText(paths.pid, std::to_string(GetCurrentProcessId()), false);
        if (!fs::exists(paths.actions)) {
            WriteText(paths.actions, "", false);
        }
        WriteText(paths.diag, "[" + NowText() + "] PlayerEditCppBridge started\r\n", false);
        WriteState(paths, "IDLE", "player edit bridge started");

        uint64_t lastLength = fs::exists(paths.actions) ? fs::file_size(paths.actions) : 0;
        bool wasWaitingForGame = false;
        while (true) {
            if (!FindProcessId(paths.win64Dir)) {
                WriteState(paths, "IDLE", "waiting for game process");
                wasWaitingForGame = true;
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }
            if (wasWaitingForGame) {
                WriteState(paths, "IDLE", "player edit bridge ready");
                WriteDiag(paths, "game process detected");
                wasWaitingForGame = false;
            }

            if (!fs::exists(paths.actions)) {
                WriteText(paths.actions, "", false);
                lastLength = 0;
            }

            const uint64_t length = fs::file_size(paths.actions);
            if (length < lastLength) {
                lastLength = 0;
            }
            if (length > lastLength) {
                const std::string text = ReadRange(paths.actions, lastLength, length);
                lastLength = length;
                for (const auto& line : SplitLines(text)) {
                    try {
                        ProcessLine(paths, line);
                    } catch (const std::exception& ex) {
                        WriteDiag(paths, std::string("ERROR ") + ex.what());
                        WriteState(paths, "FAILED", ex.what());
                    }
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
    } catch (const std::exception& ex) {
        WriteDiag(paths, std::string("FATAL ") + ex.what());
        WriteState(paths, "FAILED", ex.what());
        try {
            fs::remove(paths.pid);
        } catch (...) {
        }
        return 1;
    }
}
