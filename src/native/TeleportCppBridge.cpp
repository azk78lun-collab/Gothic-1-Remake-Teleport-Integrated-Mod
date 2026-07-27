#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <cwctype>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <locale>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr wchar_t kProcessExe[] = L"G1R-Win64-Shipping.exe";
constexpr char kBridgeVersion[] = "5.17-single-instance";
constexpr DWORD kProcessAccess =
    PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION | PROCESS_VM_READ | PROCESS_VM_WRITE;

struct Paths {
    fs::path win64Dir;
    fs::path actions;
    fs::path luaActions;
    fs::path status;
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
    std::wstring path;
};

struct GEngineInfo {
    uint64_t pointerAddress = 0;
    uint64_t gEngine = 0;
};

struct RootInfo {
    uint64_t gEngine = 0;
    uint64_t localPlayersArray = 0;
    uint64_t localPlayersData = 0;
    uint64_t localPlayer = 0;
    uint64_t playerController = 0;
    uint64_t pawn = 0;
    uint64_t root = 0;
};

struct FlightState {
    bool enabled = false;
    double speed = 600.0;
    double targetSpeed = 600.0;
    uint64_t rotationAddress = 0;
    std::optional<GameContext> context;
    std::chrono::steady_clock::time_point lastTick{};
    bool moving = false;
    bool positionInitialized = false;
    double targetX = 0.0;
    double targetY = 0.0;
    double targetZ = 0.0;
    bool interactionPaused = false;
    bool interactionKeyWasDown = false;
    std::chrono::steady_clock::time_point pauseUntil{};
    bool refreshPending = false;
    std::chrono::steady_clock::time_point refreshAt{};
    std::string refreshReason;
    int externalCorrectionFrames = 0;
};

std::string NowText() {
    std::time_t now = std::time(nullptr);
    std::tm local{};
    localtime_s(&local, &now);
    std::ostringstream out;
    out << std::put_time(&local, "%Y-%m-%d %H:%M:%S");
    return out.str();
}

std::string Hex(uint64_t value) {
    std::ostringstream out;
    out << "0x" << std::uppercase << std::hex << value;
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

std::wstring BridgeMutexName(const fs::path& win64Dir) {
    std::error_code ec;
    fs::path normalized = fs::weakly_canonical(win64Dir, ec);
    if (ec) {
        normalized = win64Dir.lexically_normal();
    }

    const std::wstring key = LowerWide(normalized.wstring());
    uint64_t hash = 14695981039346656037ULL;
    for (const wchar_t ch : key) {
        hash ^= static_cast<uint64_t>(ch);
        hash *= 1099511628211ULL;
    }

    std::wostringstream name;
    name << L"Local\\G1RTeleportCppBridge_"
         << std::uppercase << std::hex << std::setw(16) << std::setfill(L'0') << hash;
    return name.str();
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

bool ParseDouble(const std::string& text, double& value) {
    const std::string trimmed = Trim(text);
    if (trimmed.empty()) {
        return false;
    }
    const char* first = trimmed.data();
    const char* last = trimmed.data() + trimmed.size();
    const auto parsed = std::from_chars(first, last, value, std::chars_format::general);
    return parsed.ec == std::errc{} && parsed.ptr == last;
}

bool ParseU64(const std::string& text, uint64_t& value) {
    std::string trimmed = Trim(text);
    if (trimmed.empty()) {
        return false;
    }
    int base = 10;
    if (trimmed.size() > 2 && trimmed[0] == '0' && (trimmed[1] == 'x' || trimmed[1] == 'X')) {
        trimmed.erase(0, 2);
        base = 16;
    }
    if (trimmed.empty()) {
        return false;
    }
    const char* first = trimmed.data();
    const char* last = trimmed.data() + trimmed.size();
    const auto parsed = std::from_chars(first, last, value, base);
    return parsed.ec == std::errc{} && parsed.ptr == last && value != 0;
}

void WriteText(const fs::path& path, const std::string& text, bool append) {
    std::ofstream out(path, std::ios::binary | (append ? std::ios::app : std::ios::trunc));
    if (!out) {
        return;
    }
    out << text;
}

void WriteDiag(const Paths& paths, const std::string& message) {
    WriteText(paths.diag, "[" + NowText() + "] " + message + "\r\n", true);
}

void WriteState(const Paths& paths, const std::string& state, const std::string& message) {
    std::ostringstream out;
    out << "STATE=" << state << "\r\n";
    out << "MESSAGE=" << message << "\r\n";
    out << "UPDATED=" << static_cast<long long>(std::time(nullptr)) << "\r\n";
    WriteText(paths.status, out.str(), false);
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

bool IsGameForeground(DWORD pid) {
    const HWND foreground = GetForegroundWindow();
    if (!foreground) {
        return false;
    }
    DWORD foregroundPid = 0;
    GetWindowThreadProcessId(foreground, &foregroundPid);
    return foregroundPid == pid;
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
                candidate.path = *path;
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
    auto pid = FindProcessId(win64Dir);
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

double ReadF64(HANDLE process, uint64_t address) {
    const auto bytes = ReadBytes(process, address, sizeof(double));
    double value = 0.0;
    std::memcpy(&value, bytes.data(), sizeof(value));
    return value;
}

float ReadF32(HANDLE process, uint64_t address) {
    const auto bytes = ReadBytes(process, address, sizeof(float));
    float value = 0.0f;
    std::memcpy(&value, bytes.data(), sizeof(value));
    return value;
}

void WriteF64(HANDLE process, uint64_t address, double value) {
    uint8_t bytes[sizeof(double)]{};
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

GEngineInfo ResolveGEngine(const GameContext& ctx) {
    static uint64_t cachedPointerAddress = 0;
    if (cachedPointerAddress != 0) {
        try {
            const uint64_t gEngine = ReadU64(ctx.process, cachedPointerAddress);
            if (gEngine) {
                return {cachedPointerAddress, gEngine};
            }
        } catch (...) {
            cachedPointerAddress = 0;
        }
    }

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

    cachedPointerAddress = pointerAddress;
    return {pointerAddress, gEngine};
}

RootInfo ResolveRoot(const GameContext& ctx) {
    const auto ge = ResolveGEngine(ctx);

    RootInfo info;
    info.gEngine = ge.gEngine;
    info.localPlayersArray = ReadU64(ctx.process, info.gEngine + 0x10A8);
    if (!info.localPlayersArray) {
        throw std::runtime_error("LocalPlayers array is null");
    }
    info.localPlayersData = ReadU64(ctx.process, info.localPlayersArray + 0x38);
    if (!info.localPlayersData) {
        throw std::runtime_error("LocalPlayers data is null");
    }
    info.localPlayer = ReadU64(ctx.process, info.localPlayersData);
    if (!info.localPlayer) {
        throw std::runtime_error("LocalPlayer is null");
    }
    info.playerController = ReadU64(ctx.process, info.localPlayer + 0x30);
    if (!info.playerController) {
        throw std::runtime_error("PlayerController is null");
    }
    info.pawn = ReadU64(ctx.process, info.playerController + 0x2D0);
    if (!info.pawn) {
        throw std::runtime_error("Pawn is null");
    }
    info.root = ReadU64(ctx.process, info.pawn + 0x1A0);
    if (!info.root) {
        throw std::runtime_error("RootComponent is null");
    }

    return info;
}

double Distance(double ax, double ay, double az, double bx, double by, double bz) {
    const double dx = ax - bx;
    const double dy = ay - by;
    const double dz = az - bz;
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

std::string VecText(double x, double y, double z) {
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::fixed << std::setprecision(1) << x << "," << y << "," << z;
    return out.str();
}

std::string ScalarText(double value) {
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::fixed << std::setprecision(1) << value;
    return out.str();
}

void InvokeTeleport(const Paths& paths, double x, double y, double z, const std::string& name) {
    WriteState(paths, "BUSY", "cpp bridge resolving player");
    GameContext ctx = OpenGameProcess(paths.win64Dir);
    const auto root = ResolveRoot(ctx);
    const uint64_t coord = root.root + 0x1F0;

    const double beforeX = ReadF64(ctx.process, coord);
    const double beforeY = ReadF64(ctx.process, coord + 8);
    const double beforeZ = ReadF64(ctx.process, coord + 16);

    std::ostringstream resolved;
    resolved << "REQUEST name=" << name << " target=" << VecText(x, y, z)
             << " pid=" << ctx.pid << " module=" << Hex(ctx.moduleBase)
             << " root=" << Hex(root.root) << " pawn=" << Hex(root.pawn)
             << " pc=" << Hex(root.playerController) << " before=" << VecText(beforeX, beforeY, beforeZ);
    WriteDiag(paths, resolved.str());
    WriteState(paths, "BUSY", "cpp bridge writing");

    for (int i = 0; i <= 150; ++i) {
        WriteF64(ctx.process, coord, x);
        WriteF64(ctx.process, coord + 8, y);
        WriteF64(ctx.process, coord + 16, z);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }

    const double afterX = ReadF64(ctx.process, coord);
    const double afterY = ReadF64(ctx.process, coord + 8);
    const double afterZ = ReadF64(ctx.process, coord + 16);
    const double dist0 = Distance(afterX, afterY, afterZ, x, y, z);

    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    const double after250X = ReadF64(ctx.process, coord);
    const double after250Y = ReadF64(ctx.process, coord + 8);
    const double after250Z = ReadF64(ctx.process, coord + 16);
    const double dist250 = Distance(after250X, after250Y, after250Z, x, y, z);

    std::this_thread::sleep_for(std::chrono::milliseconds(750));
    const double after1000X = ReadF64(ctx.process, coord);
    const double after1000Y = ReadF64(ctx.process, coord + 8);
    const double after1000Z = ReadF64(ctx.process, coord + 16);
    const double dist1000 = Distance(after1000X, after1000Y, after1000Z, x, y, z);

    std::ostringstream result;
    result << "READBACK name=" << name
           << " after=" << VecText(afterX, afterY, afterZ) << " dist=" << ScalarText(dist0)
           << " after250=" << VecText(after250X, after250Y, after250Z) << " dist250=" << ScalarText(dist250)
           << " after1000=" << VecText(after1000X, after1000Y, after1000Z)
           << " dist1000=" << ScalarText(dist1000);
    WriteDiag(paths, result.str());

    if (dist0 < 250.0 && dist1000 < 250.0) {
        WriteDiag(paths, "SUCCESS name=" + name + " readback held at target");
        WriteState(paths, "SUCCESS", "cpp bridge held: " + name);
    } else if (dist0 < 250.0) {
        WriteDiag(paths, "FAILED name=" + name + " wrote target but snapped back");
        WriteState(paths, "FAILED", "cpp write snapped back after 1000ms");
    } else {
        WriteDiag(paths, "FAILED name=" + name + " readback not at target");
        WriteState(paths, "FAILED", "cpp readback not at target");
    }
}

bool KeyDown(int virtualKey) {
    return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
}

void ReadControlRotation(const GameContext& ctx, uint64_t address, double& pitch, double& yaw) {
    pitch = ReadF64(ctx.process, address);
    yaw = ReadF64(ctx.process, address + sizeof(double));
    const bool doublesValid = std::isfinite(pitch) && std::isfinite(yaw) &&
                              std::abs(pitch) <= 360000.0 && std::abs(yaw) <= 360000.0;
    if (!doublesValid) {
        pitch = static_cast<double>(ReadF32(ctx.process, address));
        yaw = static_cast<double>(ReadF32(ctx.process, address + sizeof(float)));
    }
    if (!std::isfinite(pitch) || !std::isfinite(yaw) ||
        std::abs(pitch) > 360000.0 || std::abs(yaw) > 360000.0) {
        throw std::runtime_error("ControlRotation readback is invalid");
    }
}

void DisableFlight(const Paths& paths, FlightState& flight, const std::string& reason, bool failed) {
    const bool wasEnabled = flight.enabled;
    flight.enabled = false;
    flight.moving = false;
    flight.positionInitialized = false;
    flight.interactionPaused = false;
    flight.interactionKeyWasDown = false;
    flight.refreshPending = false;
    flight.refreshReason.clear();
    flight.externalCorrectionFrames = 0;
    flight.rotationAddress = 0;
    flight.context.reset();
    if (wasEnabled || failed) {
        WriteDiag(paths, std::string("FLIGHT disabled reason=") + reason);
    }
    WriteState(paths, failed ? "FAILED" : "IDLE", reason);
}

void PauseFlightMotion(const Paths& paths, FlightState& flight,
                       std::chrono::milliseconds duration, const std::string& reason) {
    if (!flight.enabled) {
        return;
    }

    const auto requestedUntil = std::chrono::steady_clock::now() + duration;
    if (requestedUntil > flight.pauseUntil) {
        flight.pauseUntil = requestedUntil;
    }
    const auto requestedRefreshAt = requestedUntil + std::chrono::milliseconds(250);
    if (!flight.refreshPending || requestedRefreshAt > flight.refreshAt) {
        flight.refreshAt = requestedRefreshAt;
        flight.refreshReason = reason;
    }
    flight.refreshPending = true;
    if (!flight.interactionPaused) {
        WriteDiag(paths, "FLIGHT motion paused reason=" + reason +
                         " duration_ms=" + std::to_string(duration.count()));
    }
    flight.interactionPaused = true;
    flight.moving = false;
    flight.positionInitialized = false;
    flight.externalCorrectionFrames = 0;
}

void ResumeFlightMotion(const Paths& paths, FlightState& flight, const std::string& reason) {
    if (!flight.enabled) {
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    flight.interactionPaused = false;
    flight.pauseUntil = now;
    flight.moving = false;
    flight.positionInitialized = false;
    flight.externalCorrectionFrames = 0;
    flight.lastTick = now;

    // The interaction can restore walking/collision. Ask Lua for one safe
    // no-clip refresh, but let C++ resume immediately from the live position.
    flight.refreshPending = true;
    flight.refreshAt = now;
    flight.refreshReason = reason;
    WriteDiag(paths, "FLIGHT interaction completed reason=" + reason);
    WriteState(paths, "IDLE", "camera flight resumed after interaction");
}

void EnableFlight(const Paths& paths, FlightState& flight, double speed, uint64_t rotationAddress) {
    FlightState replacement;
    replacement.speed = std::clamp(speed, 60.0, 6000.0);
    replacement.targetSpeed = replacement.speed;
    replacement.rotationAddress = rotationAddress;
    replacement.context = OpenGameProcess(paths.win64Dir);

    double pitch = 0.0;
    double yaw = 0.0;
    ReadControlRotation(*replacement.context, replacement.rotationAddress, pitch, yaw);
    const auto root = ResolveRoot(*replacement.context);
    const uint64_t coord = root.root + 0x1F0;
    (void)ReadF64(replacement.context->process, coord);
    (void)ReadF64(replacement.context->process, coord + 8);
    (void)ReadF64(replacement.context->process, coord + 16);

    replacement.enabled = true;
    replacement.interactionKeyWasDown = KeyDown('F');
    replacement.lastTick = std::chrono::steady_clock::now();
    flight = std::move(replacement);

    std::ostringstream message;
    message << "FLIGHT enabled pid=" << flight.context->pid
            << " speed=" << ScalarText(flight.speed)
            << " rotation=" << Hex(flight.rotationAddress)
            << " pitch=" << ScalarText(pitch) << " yaw=" << ScalarText(yaw);
    WriteDiag(paths, message.str());
    WriteState(paths, "IDLE", "camera flight ready");
}

void UpdateFlight(const Paths& paths, FlightState& flight) {
    if (!flight.enabled || !flight.context) {
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    double deltaSeconds = std::chrono::duration<double>(now - flight.lastTick).count();
    flight.lastTick = now;
    deltaSeconds = std::clamp(deltaSeconds, 0.0, 0.05);
    const double speedBlend = 1.0 - std::exp(-12.0 * deltaSeconds);
    flight.speed += (flight.targetSpeed - flight.speed) * speedBlend;
    if (std::abs(flight.targetSpeed - flight.speed) < 0.1) {
        flight.speed = flight.targetSpeed;
    }

    if (!IsGameForeground(flight.context->pid)) {
        flight.interactionKeyWasDown = KeyDown('F');
        flight.moving = false;
        flight.positionInitialized = false;
        flight.externalCorrectionFrames = 0;
        return;
    }

    // Trigger the generic interaction guard once per physical key press. The
    // old level-triggered check renewed the pause every 16 ms while F was held.
    const bool interactionKeyDown = KeyDown('F');
    if (interactionKeyDown && !flight.interactionKeyWasDown) {
        PauseFlightMotion(paths, flight, std::chrono::milliseconds(650), "interaction key F edge");
    }
    flight.interactionKeyWasDown = interactionKeyDown;

    const double forwardInput = (KeyDown('W') ? 1.0 : 0.0) - (KeyDown('S') ? 1.0 : 0.0);
    const double rightInput = (KeyDown('D') ? 1.0 : 0.0) - (KeyDown('A') ? 1.0 : 0.0);

    if (flight.interactionPaused) {
        // Do not chase the pawn/root pointer during an interaction transition.
        // Some lockpick animations temporarily replace or invalidate that chain.
        flight.positionInitialized = false;

        if (now < flight.pauseUntil) {
            return;
        }

        flight.interactionPaused = false;
        flight.lastTick = now;
        WriteDiag(paths, "FLIGHT motion resumed after interaction guard");
        deltaSeconds = 0.0;
    }

    if (flight.refreshPending && now >= flight.refreshAt && !KeyDown('F')) {
        std::string reason = flight.refreshReason;
        std::replace(reason.begin(), reason.end(), '|', '_');
        std::replace(reason.begin(), reason.end(), '\r', ' ');
        std::replace(reason.begin(), reason.end(), '\n', ' ');
        WriteText(paths.luaActions, "NOCLIP_REFRESH|" + reason + "\r\n", true);
        flight.refreshPending = false;
        flight.refreshReason.clear();
        WriteDiag(paths, "FLIGHT queued no-clip refresh reason=" + reason);
    }

    if (forwardInput == 0.0 && rightInput == 0.0) {
        if (flight.moving) {
            WriteDiag(paths, "FLIGHT input stopped");
        }
        flight.moving = false;
        flight.positionInitialized = false;
        flight.externalCorrectionFrames = 0;
        return;
    }

    double pitch = 0.0;
    double yaw = 0.0;
    ReadControlRotation(*flight.context, flight.rotationAddress, pitch, yaw);
    constexpr double kPi = 3.14159265358979323846;
    const double pitchRadians = pitch * kPi / 180.0;
    const double yawRadians = yaw * kPi / 180.0;
    const double cosPitch = std::cos(pitchRadians);
    const double sinPitch = std::sin(pitchRadians);
    const double cosYaw = std::cos(yawRadians);
    const double sinYaw = std::sin(yawRadians);

    double directionX = forwardInput * cosPitch * cosYaw + rightInput * -sinYaw;
    double directionY = forwardInput * cosPitch * sinYaw + rightInput * cosYaw;
    double directionZ = forwardInput * sinPitch;
    const double length = std::sqrt(directionX * directionX + directionY * directionY + directionZ * directionZ);
    if (length <= 0.000001) {
        return;
    }
    directionX /= length;
    directionY /= length;
    directionZ /= length;

    const auto root = ResolveRoot(*flight.context);
    const uint64_t coord = root.root + 0x1F0;
    const double x = ReadF64(flight.context->process, coord);
    const double y = ReadF64(flight.context->process, coord + 8);
    const double z = ReadF64(flight.context->process, coord + 16);
    if (flight.positionInitialized) {
        const double drift = Distance(x, y, z, flight.targetX, flight.targetY, flight.targetZ);
        const double driftTolerance = std::clamp(flight.speed * 0.05, 150.0, 300.0);
        if (drift > driftTolerance) {
            ++flight.externalCorrectionFrames;
            if (flight.externalCorrectionFrames >= 2) {
                std::ostringstream reason;
                reason << "external root motion drift=" << ScalarText(drift)
                       << " tolerance=" << ScalarText(driftTolerance);
                PauseFlightMotion(paths, flight, std::chrono::milliseconds(1800), reason.str());
                flight.targetX = x;
                flight.targetY = y;
                flight.targetZ = z;
                return;
            }
        } else {
            flight.externalCorrectionFrames = 0;
        }
    }
    if (!flight.positionInitialized) {
        flight.targetX = x;
        flight.targetY = y;
        flight.targetZ = z;
        flight.positionInitialized = true;
        flight.externalCorrectionFrames = 0;
    }
    const double distance = flight.speed * deltaSeconds;
    flight.targetX += directionX * distance;
    flight.targetY += directionY * distance;
    flight.targetZ += directionZ * distance;
    WriteF64(flight.context->process, coord, flight.targetX);
    WriteF64(flight.context->process, coord + 8, flight.targetY);
    WriteF64(flight.context->process, coord + 16, flight.targetZ);

    if (!flight.moving) {
        std::ostringstream message;
        message << "FLIGHT input started pitch=" << ScalarText(pitch)
                << " yaw=" << ScalarText(yaw)
                << " direction=" << VecText(directionX, directionY, directionZ);
        WriteDiag(paths, message.str());
    }
    flight.moving = true;
}

void ProcessLine(const Paths& paths, FlightState& flight, const std::string& rawLine) {
    const std::string line = Trim(rawLine);
    if (line.empty()) {
        return;
    }

    const auto parts = SplitPipe(line);
    if (parts.empty()) {
        return;
    }

    const std::string cmd = UpperAscii(Trim(parts[0]));
    if (cmd == "FLIGHT_DISABLE") {
        DisableFlight(paths, flight, "camera flight disabled", false);
        return;
    }
    if (cmd == "FLIGHT_ENABLE") {
        if (parts.size() < 3) {
            throw std::runtime_error("FLIGHT_ENABLE requires speed and rotation address");
        }
        double speed = 0.0;
        uint64_t rotationAddress = 0;
        if (!ParseDouble(parts[1], speed) || !ParseU64(parts[2], rotationAddress)) {
            throw std::runtime_error("FLIGHT_ENABLE has invalid arguments");
        }
        EnableFlight(paths, flight, speed, rotationAddress);
        return;
    }
    if (cmd == "FLIGHT_SPEED") {
        if (parts.size() < 2) {
            throw std::runtime_error("FLIGHT_SPEED requires a speed");
        }
        if (!flight.enabled) {
            throw std::runtime_error("camera flight is not enabled");
        }
        double speed = 0.0;
        if (!ParseDouble(parts[1], speed)) {
            throw std::runtime_error("FLIGHT_SPEED has invalid speed");
        }
        flight.targetSpeed = std::clamp(speed, 60.0, 6000.0);
        flight.lastTick = std::chrono::steady_clock::now();
        WriteDiag(paths, "FLIGHT speed target=" + ScalarText(flight.targetSpeed) +
                         " current=" + ScalarText(flight.speed));
        WriteState(paths, "IDLE", "camera flight speed updated");
        return;
    }
    if (cmd == "FLIGHT_PAUSE") {
        if (!flight.enabled) {
            return;
        }
        double durationMs = 2500.0;
        if (parts.size() >= 2 && !ParseDouble(parts[1], durationMs)) {
            throw std::runtime_error("FLIGHT_PAUSE has invalid duration");
        }
        durationMs = std::clamp(durationMs, 250.0, 10000.0);
        const std::string reason = parts.size() >= 3 ? Trim(parts[2]) : "external interaction";
        PauseFlightMotion(paths, flight,
                          std::chrono::milliseconds(static_cast<long long>(durationMs)),
                          reason.empty() ? "external interaction" : reason);
        WriteState(paths, "IDLE", "camera flight paused for interaction");
        return;
    }
    if (cmd == "FLIGHT_RESUME") {
        const std::string reason = parts.size() >= 2 ? Trim(parts[1]) : "external interaction complete";
        ResumeFlightMotion(paths, flight, reason.empty() ? "external interaction complete" : reason);
        return;
    }
    if (cmd == "FLIGHT_REBASE") {
        if (!flight.enabled) {
            return;
        }
        flight.moving = false;
        flight.positionInitialized = false;
        flight.externalCorrectionFrames = 0;
        flight.lastTick = std::chrono::steady_clock::now();
        WriteDiag(paths, "FLIGHT rebased after no-clip state refresh");
        WriteState(paths, "IDLE", "camera flight restored after interaction");
        return;
    }
    if (parts.size() < 4) {
        return;
    }
    if (cmd != "TELEPORT_COORD" && cmd != "TP_COORD") {
        return;
    }

    std::string fieldLog = "ACTION cmd=" + cmd;
    if (parts.size() >= 4) {
        fieldLog += " x=[" + Trim(parts[1]) + "] y=[" + Trim(parts[2]) + "] z=[" + Trim(parts[3]) + "]";
    }
    WriteDiag(paths, fieldLog);

    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
    if (!ParseDouble(parts[1], x)) {
        throw std::runtime_error("invalid X coordinate");
    }
    if (!ParseDouble(parts[2], y)) {
        throw std::runtime_error("invalid Y coordinate");
    }
    if (!ParseDouble(parts[3], z)) {
        throw std::runtime_error("invalid Z coordinate");
    }

    const std::string name = parts.size() >= 5 ? Trim(parts[4]) : "coordinate";
    flight.moving = false;
    flight.positionInitialized = false;
    InvokeTeleport(paths, x, y, z, name.empty() ? "coordinate" : name);
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
    const uint64_t count64 = end - start;
    if (count64 > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
        throw std::runtime_error("action range too large");
    }

    std::string text(static_cast<size_t>(count64), '\0');
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
    paths.actions = paths.win64Dir / "TeleportMod_cpp_actions.txt";
    paths.luaActions = paths.win64Dir / "TeleportMod_actions.txt";
    paths.status = paths.win64Dir / "TeleportMod_cpp_status.txt";
    paths.diag = paths.win64Dir / "TeleportMod_cpp_diag.txt";
    paths.pid = paths.win64Dir / "TeleportMod_cpp_bridge.pid";
    FlightState flight;
    HANDLE singletonMutex = nullptr;

    try {
        const DWORD bridgePid = GetCurrentProcessId();
        const std::wstring mutexName = BridgeMutexName(paths.win64Dir);
        singletonMutex = CreateMutexW(nullptr, TRUE, mutexName.c_str());
        if (!singletonMutex) {
            WriteState(paths, "FAILED", "cpp bridge singleton mutex creation failed");
            return 1;
        }
        if (GetLastError() == ERROR_ALREADY_EXISTS) {
            std::ostringstream message;
            message << "SINGLETON rejected duplicate pid=" << bridgePid;
            WriteDiag(paths, message.str());
            WriteState(paths, "IDLE", "cpp bridge already running; duplicate rejected");
            CloseHandle(singletonMutex);
            singletonMutex = nullptr;
            return 0;
        }

        WriteText(paths.pid, std::to_string(bridgePid), false);
        // Because the UI deletes the actions file on startup, anything currently in
        // the file was written by the user in this session (e.g. they clicked
        // teleport before the bridge finished launching). We MUST start reading
        // from offset 0 to catch those fast first-clicks.
        uint64_t lastLength = 0;
        WriteText(paths.diag, "[" + NowText() + "] TeleportCppBridge v" +
                                  std::string(kBridgeVersion) + " started pid=" +
                                  std::to_string(bridgePid) + " singleton=owner\r\n", false);
        WriteState(paths, "IDLE", "cpp bridge started; singleton owner pid=" +
                                  std::to_string(bridgePid));
        bool wasWaitingForGame = false;

        while (true) {
            const bool flightHasProcess = flight.enabled && flight.context.has_value();
            if (!flightHasProcess && !FindProcessId(paths.win64Dir)) {
                WriteState(paths, "IDLE", "waiting for game process");
                wasWaitingForGame = true;
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }
            if (wasWaitingForGame) {
                WriteState(paths, "IDLE", "cpp bridge ready");
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
                        ProcessLine(paths, flight, line);
                    } catch (const std::exception& ex) {
                        WriteDiag(paths, std::string("ERROR ") + ex.what());
                        WriteState(paths, "FAILED", ex.what());
                    }
                }
            }

            if (flight.enabled) {
                try {
                    UpdateFlight(paths, flight);
                } catch (const std::exception& ex) {
                    DisableFlight(paths, flight, std::string("camera flight stopped: ") + ex.what(), true);
                }
            }

            std::this_thread::sleep_for(std::chrono::milliseconds(flight.enabled ? 16 : 200));
        }
    } catch (const std::exception& ex) {
        WriteDiag(paths, std::string("FATAL ") + ex.what());
        WriteState(paths, "FAILED", ex.what());
        try {
            fs::remove(paths.pid);
        } catch (...) {
        }
        if (singletonMutex) {
            CloseHandle(singletonMutex);
            singletonMutex = nullptr;
        }
        return 1;
    }
}
