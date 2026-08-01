#define _WIN32_WINNT 0x0601
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cwctype>
#include <cstdint>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iterator>
#include <locale>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#pragma comment(linker, \
    "\"/manifestdependency:type='win32' name='Microsoft.Windows.Common-Controls' " \
    "version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' " \
    "language='*'\"")

namespace fs = std::filesystem;

namespace {

constexpr wchar_t kWindowClass[] = L"G1RTeleportLiteWindow";
constexpr wchar_t kWindowTitleEn[] = L"Gothic 1 Remake Teleport Lite";
constexpr wchar_t kWindowTitleZh[] = L"哥特王朝重制版：瞬移 Lite";
constexpr wchar_t kCommandFile[] = L"TeleportLite_command.txt";
constexpr wchar_t kNodesFile[] = L"TeleportLite_nodes.tsv";
constexpr wchar_t kHotkeysFile[] = L"TeleportLite_hotkeys.tsv";
constexpr wchar_t kSettingsFile[] = L"TeleportLite_settings.ini";
constexpr wchar_t kStatusFile[] = L"TeleportLite_status.txt";
constexpr wchar_t kDiagFile[] = L"TeleportLite_native_diag.txt";
constexpr wchar_t kDefaultNodesRelative[] = L"data\\TeleportLite_default_nodes.tsv";
constexpr wchar_t kFlightStatusFile[] = L"FreeFlightF7_status.txt";
constexpr wchar_t kFlightNativeStatusFile[] = L"FreeFlightF7_native_status.txt";
constexpr auto kCooldown = std::chrono::seconds(4);

enum ControlId {
    IDC_SEARCH_LABEL = 100,
    IDC_SEARCH = 101,
    IDC_COUNT = 102,
    IDC_LANGUAGE = 103,
    IDC_NAME_ZH_LABEL = 110,
    IDC_NAME_ZH = 111,
    IDC_NAME_EN_LABEL = 112,
    IDC_NAME_EN = 113,
    IDC_COORD_LABEL = 114,
    IDC_COORD = 115,
    IDC_SAVE_CURRENT = 120,
    IDC_TELEPORT_COORD = 121,
    IDC_RENAME = 122,
    IDC_DELETE = 123,
    IDC_IMPORT = 124,
    IDC_EXPORT = 125,
    IDC_LIST = 200,
    IDC_STATUS = 201,
};

enum MenuId {
    IDM_TELEPORT = 300,
    IDM_RENAME = 301,
    IDM_DELETE = 302,
    IDM_COPY_COORDS = 303,
    IDM_BIND_BASE = 400,
    IDM_CLEAR_BASE = 420,
};

constexpr UINT WM_TL_REFRESH = WM_APP + 1;
constexpr UINT WM_TL_STATUS = WM_APP + 2;
constexpr UINT WM_TL_TOGGLE = WM_APP + 3;

struct Paths {
    fs::path moduleDir;
    fs::path win64Dir;
    fs::path command;
    fs::path nodes;
    fs::path defaultNodes;
    fs::path hotkeys;
    fs::path settings;
    fs::path status;
    fs::path diag;
};

struct Node {
    std::string id;
    std::wstring groupZh;
    std::wstring groupEn;
    std::wstring nameZh;
    std::wstring nameEn;
    double x = 0.0;
    double y = 0.0;
    double z = 0.0;
};

enum class RequestType {
    Teleport,
    Save,
    Hotkey,
    List,
};

struct Request {
    RequestType type = RequestType::List;
    Node node;
    std::wstring nameZh;
    std::wstring nameEn;
    int hotkey = -1;
};

struct RootInfo {
    uintptr_t pawn = 0;
    uintptr_t root = 0;
    uintptr_t coordinates = 0;
};

HINSTANCE g_instance = nullptr;
Paths g_paths;
std::atomic<bool> g_stop{false};
std::atomic<bool> g_initialized{false};
std::thread g_worker;
std::thread g_uiThread;
std::mutex g_lifecycleMutex;
std::mutex g_nodesMutex;
std::mutex g_queueMutex;
std::mutex g_logMutex;
std::condition_variable g_queueCv;
std::deque<Request> g_requests;
std::vector<Node> g_nodes;
std::map<int, std::string> g_hotkeys;
std::chrono::steady_clock::time_point g_cooldownUntil{};
uintptr_t g_enginePointerAddress = 0;

HWND g_window = nullptr;
HWND g_searchLabel = nullptr;
HWND g_search = nullptr;
HWND g_count = nullptr;
HWND g_language = nullptr;
HWND g_nameZhLabel = nullptr;
HWND g_nameZh = nullptr;
HWND g_nameEnLabel = nullptr;
HWND g_nameEn = nullptr;
HWND g_coordLabel = nullptr;
HWND g_coord = nullptr;
HWND g_saveCurrent = nullptr;
HWND g_teleportCoord = nullptr;
HWND g_rename = nullptr;
HWND g_delete = nullptr;
HWND g_import = nullptr;
HWND g_export = nullptr;
HWND g_list = nullptr;
HWND g_status = nullptr;
std::vector<std::string> g_visibleNodeIds;
bool g_english = true;

std::string NowText() {
    SYSTEMTIME time{};
    GetLocalTime(&time);
    char buffer[64]{};
    std::snprintf(buffer, sizeof(buffer), "%04u-%02u-%02u %02u:%02u:%02u.%03u",
                  time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
                  time.wSecond, time.wMilliseconds);
    return buffer;
}

std::wstring Utf8ToWide(const std::string& value) {
    if (value.empty()) return {};
    const int length = MultiByteToWideChar(
        CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
        nullptr, 0);
    if (length <= 0) return {};
    std::wstring result(static_cast<size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                        static_cast<int>(value.size()), result.data(), length);
    return result;
}

std::string WideToUtf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int length = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
        nullptr, 0, nullptr, nullptr);
    if (length <= 0) return {};
    std::string result(static_cast<size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                        static_cast<int>(value.size()), result.data(), length,
                        nullptr, nullptr);
    return result;
}

std::string TrimAscii(std::string value) {
    constexpr char whitespace[] = " \t\r\n";
    const size_t first = value.find_first_not_of(whitespace);
    if (first == std::string::npos) return {};
    const size_t last = value.find_last_not_of(whitespace);
    return value.substr(first, last - first + 1);
}

std::wstring TrimWide(std::wstring value) {
    constexpr wchar_t whitespace[] = L" \t\r\n";
    const size_t first = value.find_first_not_of(whitespace);
    if (first == std::wstring::npos) return {};
    const size_t last = value.find_last_not_of(whitespace);
    return value.substr(first, last - first + 1);
}

std::vector<std::string> Split(const std::string& value, char separator) {
    std::vector<std::string> result;
    size_t start = 0;
    while (start <= value.size()) {
        const size_t end = value.find(separator, start);
        result.push_back(value.substr(start, end == std::string::npos
                                                ? std::string::npos
                                                : end - start));
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return result;
}

bool ParseDouble(const std::string& text, double& value) {
    try {
        size_t consumed = 0;
        value = std::stod(TrimAscii(text), &consumed);
        const std::string trimmed = TrimAscii(text);
        return consumed == trimmed.size() && std::isfinite(value);
    } catch (...) {
        return false;
    }
}

std::string NumberText(double value) {
    std::ostringstream output;
    output.imbue(std::locale::classic());
    output << std::fixed << std::setprecision(0) << value;
    return output.str();
}

std::wstring CoordinateText(const Node& node) {
    std::wostringstream output;
    output.imbue(std::locale::classic());
    output << L"X: " << std::fixed << std::setprecision(0) << node.x
           << L" | Y: " << node.y << L" | Z: " << node.z;
    return output.str();
}

fs::path ModuleDirectory() {
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCWSTR>(&ModuleDirectory), &module)) {
        return {};
    }
    std::vector<wchar_t> buffer(32768);
    const DWORD length =
        GetModuleFileNameW(module, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0 || length >= buffer.size()) return {};
    return fs::path(std::wstring(buffer.data(), length)).parent_path();
}

void WriteText(const fs::path& path, const std::string& text, bool append) {
    std::ofstream output(path, std::ios::binary |
                                   (append ? std::ios::app : std::ios::trunc));
    if (output) output << text;
}

void Diag(const std::string& message) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    if (!g_paths.diag.empty()) {
        WriteText(g_paths.diag, "[" + NowText() + "] " + message + "\r\n", true);
    }
    OutputDebugStringA(("[TeleportLite] " + message + "\n").c_str());
}

void WriteStatusFile(const std::string& state, const std::string& message) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    if (!g_paths.status.empty()) {
        WriteText(g_paths.status,
                  "STATE=" + state + "\r\nMESSAGE=" + message +
                      "\r\nVERSION=1.0.0-test\r\n",
                  false);
    }
}

void SetUiStatus(const std::wstring& message) {
    HWND window = g_window;
    HWND status = g_status;
    if (window && status && IsWindow(window) && IsWindow(status)) {
        SetWindowTextW(status, message.c_str());
        PostMessageW(window, WM_TL_STATUS, 0, 0);
    }
}

std::wstring GetWindowTextString(HWND control) {
    if (!control) return {};
    const int length = GetWindowTextLengthW(control);
    if (length <= 0) return {};
    std::wstring result(static_cast<size_t>(length + 1), L'\0');
    GetWindowTextW(control, result.data(), length + 1);
    result.resize(static_cast<size_t>(length));
    return result;
}

std::wstring LowerWide(std::wstring value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](wchar_t ch) { return static_cast<wchar_t>(std::towlower(ch)); });
    return value;
}

bool IsAccessible(uintptr_t address, size_t size, bool write) {
    if (address < 0x10000 || size == 0 || address > UINTPTR_MAX - size) return false;
    MEMORY_BASIC_INFORMATION info{};
    if (VirtualQuery(reinterpret_cast<LPCVOID>(address), &info, sizeof(info)) !=
        sizeof(info)) {
        return false;
    }
    const uintptr_t start = reinterpret_cast<uintptr_t>(info.BaseAddress);
    const uintptr_t end = start + info.RegionSize;
    if (info.State != MEM_COMMIT || address < start || address + size > end ||
        (info.Protect & PAGE_GUARD) || (info.Protect & PAGE_NOACCESS)) {
        return false;
    }
    const DWORD protection = info.Protect & 0xff;
    if (write) {
        return protection == PAGE_READWRITE || protection == PAGE_WRITECOPY ||
               protection == PAGE_EXECUTE_READWRITE ||
               protection == PAGE_EXECUTE_WRITECOPY;
    }
    return protection == PAGE_READONLY || protection == PAGE_READWRITE ||
           protection == PAGE_WRITECOPY || protection == PAGE_EXECUTE_READ ||
           protection == PAGE_EXECUTE_READWRITE ||
           protection == PAGE_EXECUTE_WRITECOPY;
}

template <typename T>
bool SafeRead(uintptr_t address, T& value) {
    if (!IsAccessible(address, sizeof(T), false)) return false;
    __try {
        std::memcpy(&value, reinterpret_cast<const void*>(address), sizeof(T));
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

template <typename T>
bool SafeWrite(uintptr_t address, const T& value) {
    if (!IsAccessible(address, sizeof(T), true)) return false;
    __try {
        std::memcpy(reinterpret_cast<void*>(address), &value, sizeof(T));
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

bool ReadPointer(uintptr_t address, uintptr_t& value) {
    value = 0;
    return SafeRead(address, value) && value >= 0x10000;
}

uintptr_t FindEnginePointerAddress() {
    HMODULE module = GetModuleHandleW(nullptr);
    if (!module) return 0;
    const uintptr_t base = reinterpret_cast<uintptr_t>(module);
    IMAGE_DOS_HEADER dos{};
    if (!SafeRead(base, dos) || dos.e_magic != IMAGE_DOS_SIGNATURE) return 0;
    IMAGE_NT_HEADERS64 nt{};
    if (!SafeRead(base + static_cast<uintptr_t>(dos.e_lfanew), nt) ||
        nt.Signature != IMAGE_NT_SIGNATURE) {
        return 0;
    }
    const uintptr_t sectionTable =
        base + static_cast<uintptr_t>(dos.e_lfanew) +
        offsetof(IMAGE_NT_HEADERS64, OptionalHeader) +
        nt.FileHeader.SizeOfOptionalHeader;
    IMAGE_SECTION_HEADER textSection{};
    bool found = false;
    for (WORD index = 0; index < nt.FileHeader.NumberOfSections; ++index) {
        IMAGE_SECTION_HEADER section{};
        if (!SafeRead(sectionTable + index * sizeof(section), section)) return 0;
        char name[9]{};
        std::memcpy(name, section.Name, 8);
        if (std::strcmp(name, ".text") == 0) {
            textSection = section;
            found = true;
            break;
        }
    }
    if (!found) return 0;
    const uint8_t pattern[] = {
        0x48, 0x8B, 0x05, 0, 0, 0, 0, 0x48, 0x8B, 0x88, 0x80, 0x0A, 0x00, 0x00};
    const bool exact[] = {
        true, true, true, false, false, false, false,
        true, true, true, true, true, true, true};
    const uintptr_t start = base + textSection.VirtualAddress;
    const size_t size =
        std::max<size_t>(textSection.Misc.VirtualSize, textSection.SizeOfRawData);
    if (!IsAccessible(start, size, false) || size < sizeof(pattern)) return 0;
    const auto* bytes = reinterpret_cast<const uint8_t*>(start);
    for (size_t offset = 0; offset + sizeof(pattern) <= size; ++offset) {
        bool match = true;
        for (size_t index = 0; index < sizeof(pattern); ++index) {
            if (exact[index] && bytes[offset + index] != pattern[index]) {
                match = false;
                break;
            }
        }
        if (!match) continue;
        int32_t displacement = 0;
        if (!SafeRead(start + offset + 3, displacement)) return 0;
        return static_cast<uintptr_t>(
            static_cast<int64_t>(start + offset + 7) + displacement);
    }
    return 0;
}

bool ResolveRoot(RootInfo& result) {
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (!g_enginePointerAddress) {
            g_enginePointerAddress = FindEnginePointerAddress();
            if (!g_enginePointerAddress) return false;
        }
        uintptr_t engine = 0;
        uintptr_t localPlayers = 0;
        uintptr_t localPlayersData = 0;
        uintptr_t localPlayer = 0;
        uintptr_t controller = 0;
        uintptr_t pawn = 0;
        uintptr_t root = 0;
        if (ReadPointer(g_enginePointerAddress, engine) &&
            ReadPointer(engine + 0x10A8, localPlayers) &&
            ReadPointer(localPlayers + 0x38, localPlayersData) &&
            ReadPointer(localPlayersData, localPlayer) &&
            ReadPointer(localPlayer + 0x30, controller) &&
            ReadPointer(controller + 0x2D0, pawn) &&
            ReadPointer(pawn + 0x1A0, root)) {
            const uintptr_t coordinates = root + 0x1F0;
            if (IsAccessible(coordinates, sizeof(double) * 3, true)) {
                result = {pawn, root, coordinates};
                return true;
            }
        }
        g_enginePointerAddress = 0;
    }
    return false;
}

bool ReadCurrentLocation(Node& node) {
    RootInfo root{};
    if (!ResolveRoot(root)) return false;
    return SafeRead(root.coordinates, node.x) &&
           SafeRead(root.coordinates + sizeof(double), node.y) &&
           SafeRead(root.coordinates + sizeof(double) * 2, node.z) &&
           std::isfinite(node.x) && std::isfinite(node.y) && std::isfinite(node.z);
}

double Distance(const Node& a, const Node& b) {
    const double dx = a.x - b.x;
    const double dy = a.y - b.y;
    const double dz = a.z - b.z;
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

bool FileStateIsOn(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) return false;
    std::string line;
    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (TrimAscii(line) == "STATE=ON") return true;
    }
    return false;
}

bool FreeFlightIsOn() {
    return FileStateIsOn(g_paths.win64Dir / kFlightStatusFile) ||
           FileStateIsOn(g_paths.win64Dir / kFlightNativeStatusFile);
}

std::optional<Node> FindNodeByIdLocked(const std::string& id) {
    const auto found = std::find_if(g_nodes.begin(), g_nodes.end(),
                                    [&](const Node& node) { return node.id == id; });
    if (found == g_nodes.end()) return std::nullopt;
    return *found;
}

bool LoadNodeFile(const fs::path& path, std::vector<Node>& nodes,
                  std::wstring& error, bool allowLegacy) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        error = L"Cannot open node file.";
        return false;
    }
    std::set<std::string> ids;
    std::string line;
    size_t lineNumber = 0;
    size_t legacyIndex = 0;
    while (std::getline(input, line)) {
        ++lineNumber;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        if (lineNumber == 1 && line.rfind("Id\t", 0) == 0) continue;
        const bool legacy = line.find('\t') == std::string::npos &&
                            line.find('|') != std::string::npos;
        const auto fields = Split(line, legacy ? '|' : '\t');
        Node node;
        if (legacy && allowLegacy && fields.size() >= 4) {
            ++legacyIndex;
            std::ostringstream id;
            id << "import-" << std::setw(4) << std::setfill('0') << legacyIndex;
            node.id = id.str();
            node.nameZh = Utf8ToWide(fields[0]);
            node.nameEn = node.nameZh;
            node.groupZh = L"导入";
            node.groupEn = L"Imported";
            if (!ParseDouble(fields[1], node.x) ||
                !ParseDouble(fields[2], node.y) ||
                !ParseDouble(fields[3], node.z)) {
                error = L"Invalid coordinate at line " + std::to_wstring(lineNumber);
                return false;
            }
        } else if (!legacy && fields.size() >= 8) {
            node.id = TrimAscii(fields[0]);
            node.groupZh = Utf8ToWide(fields[1]);
            node.groupEn = Utf8ToWide(fields[2]);
            node.nameZh = Utf8ToWide(fields[3]);
            node.nameEn = Utf8ToWide(fields[4]);
            if (!ParseDouble(fields[5], node.x) ||
                !ParseDouble(fields[6], node.y) ||
                !ParseDouble(fields[7], node.z)) {
                error = L"Invalid coordinate at line " + std::to_wstring(lineNumber);
                return false;
            }
        } else {
            error = L"Invalid node format at line " + std::to_wstring(lineNumber);
            return false;
        }
        if (node.id.empty() || node.nameZh.empty() || node.nameEn.empty() ||
            !ids.insert(node.id).second) {
            error = L"Missing or duplicate node data at line " +
                    std::to_wstring(lineNumber);
            return false;
        }
        nodes.push_back(std::move(node));
    }
    if (nodes.empty()) {
        error = L"No valid nodes were found.";
        return false;
    }
    return true;
}

bool ReplaceFileAtomic(const fs::path& temporary, const fs::path& target) {
    return MoveFileExW(
               temporary.c_str(), target.c_str(),
               MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
}

bool SaveNodeFile(const fs::path& path, const std::vector<Node>& nodes) {
    const fs::path temporary = path.wstring() + L".tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) return false;
    output << "Id\tGroupZh\tGroupEn\tNameZh\tNameEn\tX\tY\tZ\r\n";
    for (const Node& node : nodes) {
        output << node.id << '\t' << WideToUtf8(node.groupZh) << '\t'
               << WideToUtf8(node.groupEn) << '\t' << WideToUtf8(node.nameZh)
               << '\t' << WideToUtf8(node.nameEn) << '\t'
               << NumberText(node.x) << '\t' << NumberText(node.y) << '\t'
               << NumberText(node.z) << "\r\n";
    }
    output.close();
    if (!output) return false;
    return ReplaceFileAtomic(temporary, path);
}

bool SaveNodes() {
    std::vector<Node> copy;
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        copy = g_nodes;
    }
    return SaveNodeFile(g_paths.nodes, copy);
}

void LoadHotkeys() {
    std::lock_guard<std::mutex> lock(g_nodesMutex);
    g_hotkeys.clear();
    std::ifstream input(g_paths.hotkeys, std::ios::binary);
    std::string line;
    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        const auto fields = Split(line, '\t');
        if (fields.size() < 2 || fields[0] == "Key") continue;
        try {
            const int key = std::stoi(fields[0]);
            if (key >= 0 && key <= 9) g_hotkeys[key] = fields[1];
        } catch (...) {
        }
    }
}

bool SaveHotkeysLocked() {
    const fs::path temporary = g_paths.hotkeys.wstring() + L".tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) return false;
    output << "Key\tNodeId\r\n";
    for (const auto& binding : g_hotkeys) {
        output << binding.first << '\t' << binding.second << "\r\n";
    }
    output.close();
    return output && ReplaceFileAtomic(temporary, g_paths.hotkeys);
}

void SaveLanguageSetting() {
    WriteText(g_paths.settings, std::string("LANG=") + (g_english ? "EN\r\n" : "ZH\r\n"),
              false);
}

void LoadLanguageSetting() {
    g_english = true;
    std::ifstream input(g_paths.settings, std::ios::binary);
    std::string line;
    while (std::getline(input, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (TrimAscii(line) == "LANG=ZH") g_english = false;
        if (TrimAscii(line) == "LANG=EN") g_english = true;
    }
}

void QueueRequest(Request request) {
    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        g_requests.push_back(std::move(request));
    }
    g_queueCv.notify_one();
}

std::wstring NodeDisplayName(const Node& node) {
    return g_english ? node.nameEn : node.nameZh;
}

void NotifyRefresh() {
    if (g_window) PostMessageW(g_window, WM_TL_REFRESH, 0, 0);
}

void SetResult(const std::string& state, const std::string& messageEn,
               const std::wstring& messageZh) {
    WriteStatusFile(state, messageEn);
    SetUiStatus(g_english ? Utf8ToWide(messageEn) : messageZh);
}

void PerformTeleport(const Node& target) {
    if (FreeFlightIsOn()) {
        SetResult("BLOCKED", "Turn off Free Flight F7 before teleporting.",
                  L"请先关闭 F7 自由飞行，再执行瞬移。");
        Diag("teleport rejected: Free Flight V2 reports STATE=ON");
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (now < g_cooldownUntil) {
        const auto milliseconds =
            std::chrono::duration_cast<std::chrono::milliseconds>(
                g_cooldownUntil - now).count();
        std::ostringstream message;
        message << "Teleport cooldown: " << std::fixed << std::setprecision(1)
                << static_cast<double>(milliseconds) / 1000.0 << "s";
        SetResult("COOLDOWN", message.str(), L"瞬移冷却中，请稍候。");
        return;
    }
    g_cooldownUntil = now + kCooldown;
    SetResult("BUSY", "Resolving player position...", L"正在定位玩家坐标……");

    RootInfo root{};
    if (!ResolveRoot(root)) {
        SetResult("FAILED", "Player position is unavailable. Load a save first.",
                  L"无法读取玩家位置，请先进入存档。");
        Diag("teleport failed: player root unavailable");
        return;
    }
    Node before;
    if (!ReadCurrentLocation(before)) {
        SetResult("FAILED", "Player coordinates could not be read.",
                  L"无法读取玩家坐标。");
        return;
    }
    Diag("teleport request id=" + target.id + " target=" +
         NumberText(target.x) + "," + NumberText(target.y) + "," +
         NumberText(target.z));

    bool writesOk = true;
    for (int index = 0; index <= 150; ++index) {
        writesOk = SafeWrite(root.coordinates, target.x) &&
                   SafeWrite(root.coordinates + sizeof(double), target.y) &&
                   SafeWrite(root.coordinates + sizeof(double) * 2, target.z);
        if (!writesOk) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    Node after;
    after.x = after.y = after.z = 0.0;
    const bool readNow =
        SafeRead(root.coordinates, after.x) &&
        SafeRead(root.coordinates + sizeof(double), after.y) &&
        SafeRead(root.coordinates + sizeof(double) * 2, after.z);
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    std::this_thread::sleep_for(std::chrono::milliseconds(750));
    Node held;
    held.x = held.y = held.z = 0.0;
    const bool readHeld =
        SafeRead(root.coordinates, held.x) &&
        SafeRead(root.coordinates + sizeof(double), held.y) &&
        SafeRead(root.coordinates + sizeof(double) * 2, held.z);

    const double immediateDistance = readNow ? Distance(after, target) : 1e30;
    const double heldDistance = readHeld ? Distance(held, target) : 1e30;
    std::ostringstream result;
    result << "teleport readback write=" << writesOk
           << " immediate=" << immediateDistance << " held=" << heldDistance;
    Diag(result.str());
    if (writesOk && immediateDistance < 250.0 && heldDistance < 250.0) {
        SetResult("SUCCESS",
                  "Teleport complete. Take one step if the view has not refreshed.",
                  L"瞬移完成；如果画面未刷新，请走一步。");
    } else if (immediateDistance < 250.0) {
        SetResult("FAILED", "Position was written but the game moved the player back.",
                  L"坐标已写入，但游戏随后把玩家移回原位。");
    } else {
        SetResult("FAILED", "Teleport coordinate verification failed.",
                  L"瞬移坐标回读验证失败。");
    }
}

std::string MakeUserIdLocked() {
    const auto stamp =
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::system_clock::now().time_since_epoch()).count();
    int suffix = 1;
    while (true) {
        const std::string id = "user-" + std::to_string(stamp) + "-" +
                               std::to_string(suffix);
        if (!FindNodeByIdLocked(id)) return id;
        ++suffix;
    }
}

void PerformSave(const Request& request) {
    Node node;
    if (!ReadCurrentLocation(node)) {
        SetResult("FAILED", "Current player position is unavailable.",
                  L"无法读取玩家当前位置。");
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        node.id = MakeUserIdLocked();
        const size_t customCount =
            static_cast<size_t>(std::count_if(g_nodes.begin(), g_nodes.end(),
                [](const Node& item) { return item.id.rfind("user-", 0) == 0; })) + 1;
        node.nameZh = TrimWide(request.nameZh);
        node.nameEn = TrimWide(request.nameEn);
        if (node.nameZh.empty()) node.nameZh = L"自定义点_" + std::to_wstring(customCount);
        if (node.nameEn.empty()) node.nameEn = L"Custom Spot " + std::to_wstring(customCount);
        node.groupZh = L"自定义";
        node.groupEn = L"Custom";
        g_nodes.push_back(node);
    }
    if (!SaveNodes()) {
        SetResult("FAILED", "The node file could not be saved.",
                  L"无法保存节点文件。");
        return;
    }
    Diag("saved current position id=" + node.id);
    SetResult("SUCCESS", "Current position saved.", L"当前位置已保存。");
    NotifyRefresh();
}

void PerformHotkey(int hotkey) {
    std::optional<Node> node;
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        const auto binding = g_hotkeys.find(hotkey);
        if (binding != g_hotkeys.end()) node = FindNodeByIdLocked(binding->second);
    }
    if (!node) {
        SetResult("FAILED", "This numpad key is not bound.",
                  L"这个小键盘按键尚未绑定节点。");
        return;
    }
    PerformTeleport(*node);
}

void PerformList() {
    std::vector<Node> nodes;
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        nodes = g_nodes;
    }
    Diag("node list count=" + std::to_string(nodes.size()));
    for (size_t index = 0; index < nodes.size(); ++index) {
        const Node& node = nodes[index];
        Diag("  [" + std::to_string(index + 1) + "] " +
             WideToUtf8(node.nameEn) + " / " + WideToUtf8(node.nameZh) + " | " +
             NumberText(node.x) + "," + NumberText(node.y) + "," +
             NumberText(node.z));
    }
    SetResult("READY", "Node list written to TeleportLite_native_diag.txt.",
              L"节点列表已写入 TeleportLite_native_diag.txt。");
}

void WorkerMain() {
    Diag("worker started");
    while (!g_stop.load(std::memory_order_acquire)) {
        Request request;
        {
            std::unique_lock<std::mutex> lock(g_queueMutex);
            g_queueCv.wait(lock, [] {
                return g_stop.load(std::memory_order_acquire) || !g_requests.empty();
            });
            if (g_stop.load(std::memory_order_acquire)) break;
            request = std::move(g_requests.front());
            g_requests.pop_front();
        }
        switch (request.type) {
        case RequestType::Teleport:
            PerformTeleport(request.node);
            break;
        case RequestType::Save:
            PerformSave(request);
            break;
        case RequestType::Hotkey:
            PerformHotkey(request.hotkey);
            break;
        case RequestType::List:
            PerformList();
            break;
        }
    }
    Diag("worker stopped");
}

std::optional<Node> SelectedNode() {
    if (!g_list) return std::nullopt;
    const int item = ListView_GetNextItem(g_list, -1, LVNI_SELECTED);
    if (item < 0 || static_cast<size_t>(item) >= g_visibleNodeIds.size()) {
        return std::nullopt;
    }
    std::lock_guard<std::mutex> lock(g_nodesMutex);
    return FindNodeByIdLocked(g_visibleNodeIds[static_cast<size_t>(item)]);
}

void RefreshNodeList() {
    if (!g_list) return;
    const std::wstring filter = LowerWide(TrimWide(GetWindowTextString(g_search)));
    std::vector<Node> nodes;
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        nodes = g_nodes;
    }
    ListView_DeleteAllItems(g_list);
    ListView_RemoveAllGroups(g_list);
    g_visibleNodeIds.clear();

    std::map<std::wstring, int> groups;
    int nextGroupId = 1;
    int visible = 0;
    for (const Node& node : nodes) {
        const std::wstring name = g_english ? node.nameEn : node.nameZh;
        const std::wstring group = g_english ? node.groupEn : node.groupZh;
        const std::wstring searchable =
            LowerWide(node.nameEn + L" " + node.nameZh + L" " +
                      node.groupEn + L" " + node.groupZh);
        if (!filter.empty() && searchable.find(filter) == std::wstring::npos) continue;
        int groupId = 0;
        const auto foundGroup = groups.find(group);
        if (foundGroup == groups.end()) {
            groupId = nextGroupId++;
            groups[group] = groupId;
            LVGROUP listGroup{};
            listGroup.cbSize = sizeof(listGroup);
            listGroup.mask = LVGF_HEADER | LVGF_GROUPID | LVGF_STATE;
            listGroup.iGroupId = groupId;
            listGroup.pszHeader = const_cast<wchar_t*>(group.c_str());
            listGroup.stateMask = LVGS_COLLAPSIBLE;
            listGroup.state = LVGS_COLLAPSIBLE;
            ListView_InsertGroup(g_list, -1, &listGroup);
        } else {
            groupId = foundGroup->second;
        }
        LVITEMW item{};
        item.mask = LVIF_TEXT | LVIF_GROUPID;
        item.iItem = visible;
        item.iGroupId = groupId;
        item.pszText = const_cast<wchar_t*>(name.c_str());
        const int inserted = ListView_InsertItem(g_list, &item);
        const std::wstring indexText = std::to_wstring(visible + 1);
        const std::wstring coordinates = CoordinateText(node);
        ListView_SetItemText(g_list, inserted, 1,
                             const_cast<wchar_t*>(indexText.c_str()));
        ListView_SetItemText(g_list, inserted, 2,
                             const_cast<wchar_t*>(coordinates.c_str()));
        g_visibleNodeIds.push_back(node.id);
        ++visible;
    }
    std::wostringstream count;
    if (g_english) {
        count << L"Nodes " << visible << L" / " << nodes.size();
    } else {
        count << L"节点 " << visible << L" / " << nodes.size();
    }
    SetWindowTextW(g_count, count.str().c_str());
}

void SetColumnText(int index, const wchar_t* text) {
    LVCOLUMNW column{};
    column.mask = LVCF_TEXT;
    column.pszText = const_cast<wchar_t*>(text);
    ListView_SetColumn(g_list, index, &column);
}

void ApplyLanguage() {
    if (!g_window) return;
    SetWindowTextW(g_window, g_english ? kWindowTitleEn : kWindowTitleZh);
    SetWindowTextW(g_searchLabel, g_english ? L"Search" : L"搜索");
    SetWindowTextW(g_language, g_english ? L"中文" : L"English");
    SetWindowTextW(g_nameZhLabel, g_english ? L"Chinese name" : L"中文名称");
    SetWindowTextW(g_nameEnLabel, g_english ? L"English name" : L"英文名称");
    SetWindowTextW(g_coordLabel, g_english ? L"Coordinates" : L"手动坐标");
    SetWindowTextW(g_saveCurrent, g_english ? L"Save Current" : L"保存当前位置");
    SetWindowTextW(g_teleportCoord, g_english ? L"Teleport" : L"坐标瞬移");
    SetWindowTextW(g_rename, g_english ? L"Rename Selected" : L"重命名所选");
    SetWindowTextW(g_delete, g_english ? L"Delete Selected" : L"删除所选");
    SetWindowTextW(g_import, g_english ? L"Import" : L"导入");
    SetWindowTextW(g_export, g_english ? L"Export" : L"导出");
    SetColumnText(0, g_english ? L"Name" : L"名称");
    SetColumnText(1, g_english ? L"No." : L"序号");
    SetColumnText(2, g_english ? L"Coordinates" : L"坐标");
    SetUiStatus(g_english
                    ? L"F6 toggles this window. Double-click a node to teleport."
                    : L"F6 显示或隐藏窗口；双击节点即可瞬移。");
    RefreshNodeList();
}

bool ParseCoordinates(const std::wstring& text, Node& node) {
    std::vector<double> values;
    const wchar_t* cursor = text.c_str();
    while (*cursor && values.size() < 3) {
        if (*cursor == L'+' || *cursor == L'-' || *cursor == L'.' ||
            (*cursor >= L'0' && *cursor <= L'9')) {
            wchar_t* end = nullptr;
            const double value = std::wcstod(cursor, &end);
            if (end && end != cursor && std::isfinite(value)) {
                values.push_back(value);
                cursor = end;
                continue;
            }
        }
        ++cursor;
    }
    if (values.size() != 3) return false;
    node.x = values[0];
    node.y = values[1];
    node.z = values[2];
    return true;
}

void QueueSelectedTeleport() {
    const auto selected = SelectedNode();
    if (!selected) {
        SetUiStatus(g_english ? L"Select a node first." : L"请先选择一个节点。");
        return;
    }
    Request request;
    request.type = RequestType::Teleport;
    request.node = *selected;
    QueueRequest(std::move(request));
}

void LoadSelectedIntoEditors() {
    const auto selected = SelectedNode();
    if (!selected) {
        SetUiStatus(g_english ? L"Select a node first." : L"请先选择一个节点。");
        return;
    }
    SetWindowTextW(g_nameZh, selected->nameZh.c_str());
    SetWindowTextW(g_nameEn, selected->nameEn.c_str());
    SetWindowTextW(g_coord, CoordinateText(*selected).c_str());
    SetUiStatus(g_english ? L"Edit the names, then select Rename Selected."
                          : L"修改名称后点击“重命名所选”。");
}

void RenameSelected() {
    const auto selected = SelectedNode();
    if (!selected) {
        SetUiStatus(g_english ? L"Select a node first." : L"请先选择一个节点。");
        return;
    }
    const std::wstring zh = TrimWide(GetWindowTextString(g_nameZh));
    const std::wstring en = TrimWide(GetWindowTextString(g_nameEn));
    if (zh.empty() || en.empty()) {
        SetUiStatus(g_english ? L"Both Chinese and English names are required."
                              : L"中文名和英文名都不能为空。");
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        const auto found = std::find_if(g_nodes.begin(), g_nodes.end(),
            [&](const Node& node) { return node.id == selected->id; });
        if (found == g_nodes.end()) return;
        found->nameZh = zh;
        found->nameEn = en;
    }
    if (!SaveNodes()) {
        SetUiStatus(g_english ? L"Could not save the node file."
                              : L"无法保存节点文件。");
        return;
    }
    RefreshNodeList();
    SetUiStatus(g_english ? L"Node renamed." : L"节点已重命名。");
}

void DeleteSelected() {
    const auto selected = SelectedNode();
    if (!selected) {
        SetUiStatus(g_english ? L"Select a node first." : L"请先选择一个节点。");
        return;
    }
    const int answer = MessageBoxW(
        g_window,
        g_english ? L"Delete the selected node?" : L"确定删除所选节点吗？",
        g_english ? L"Teleport Lite" : L"瞬移 Lite",
        MB_OKCANCEL | MB_ICONQUESTION);
    if (answer != IDOK) return;
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        g_nodes.erase(std::remove_if(g_nodes.begin(), g_nodes.end(),
            [&](const Node& node) { return node.id == selected->id; }), g_nodes.end());
        for (auto it = g_hotkeys.begin(); it != g_hotkeys.end();) {
            if (it->second == selected->id) it = g_hotkeys.erase(it);
            else ++it;
        }
        SaveHotkeysLocked();
    }
    SaveNodes();
    RefreshNodeList();
    SetUiStatus(g_english ? L"Node deleted." : L"节点已删除。");
}

void CopySelectedCoordinates() {
    const auto selected = SelectedNode();
    if (!selected) return;
    const std::wstring text = CoordinateText(*selected);
    if (!OpenClipboard(g_window)) return;
    EmptyClipboard();
    const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (memory) {
        void* pointer = GlobalLock(memory);
        if (pointer) {
            std::memcpy(pointer, text.c_str(), bytes);
            GlobalUnlock(memory);
            SetClipboardData(CF_UNICODETEXT, memory);
            memory = nullptr;
        }
    }
    if (memory) GlobalFree(memory);
    CloseClipboard();
    SetUiStatus(g_english ? L"Coordinates copied." : L"坐标已复制。");
}

void BindSelected(int key) {
    const auto selected = SelectedNode();
    if (!selected || key < 0 || key > 9) return;
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        g_hotkeys[key] = selected->id;
        SaveHotkeysLocked();
    }
    SetUiStatus((g_english ? L"Bound numpad " : L"已绑定小键盘 ") +
                std::to_wstring(key));
}

void ClearBinding(int key) {
    if (key < 0 || key > 9) return;
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        g_hotkeys.erase(key);
        SaveHotkeysLocked();
    }
    SetUiStatus((g_english ? L"Cleared numpad " : L"已清除小键盘 ") +
                std::to_wstring(key));
}

std::optional<fs::path> ChooseFile(bool save) {
    wchar_t buffer[32768]{};
    OPENFILENAMEW dialog{};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = g_window;
    dialog.lpstrFile = buffer;
    dialog.nMaxFile = static_cast<DWORD>(std::size(buffer));
    dialog.lpstrFilter =
        L"Teleport node files (*.tsv;*.txt)\0*.tsv;*.txt\0All files (*.*)\0*.*\0";
    dialog.nFilterIndex = 1;
    dialog.Flags = OFN_EXPLORER | OFN_PATHMUSTEXIST |
                   (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST);
    dialog.lpstrDefExt = L"tsv";
    const BOOL accepted =
        save ? GetSaveFileNameW(&dialog) : GetOpenFileNameW(&dialog);
    if (!accepted) return std::nullopt;
    return fs::path(buffer);
}

std::string BackupStamp() {
    SYSTEMTIME time{};
    GetLocalTime(&time);
    char buffer[32]{};
    std::snprintf(buffer, sizeof(buffer), "%04u%02u%02u_%02u%02u%02u",
                  time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
                  time.wSecond);
    return buffer;
}

void ImportNodes() {
    const auto path = ChooseFile(false);
    if (!path) return;
    std::vector<Node> imported;
    std::wstring error;
    if (!LoadNodeFile(*path, imported, error, true)) {
        MessageBoxW(g_window, error.c_str(),
                    g_english ? L"Import failed" : L"导入失败",
                    MB_OK | MB_ICONERROR);
        return;
    }
    std::wostringstream question;
    if (g_english) {
        question << L"Replace the current node list with " << imported.size()
                 << L" imported nodes? A backup will be created.";
    } else {
        question << L"用导入的 " << imported.size()
                 << L" 个节点替换当前列表吗？操作前会自动备份。";
    }
    if (MessageBoxW(g_window, question.str().c_str(),
                    g_english ? L"Import nodes" : L"导入节点",
                    MB_OKCANCEL | MB_ICONQUESTION) != IDOK) {
        return;
    }
    std::error_code copyError;
    if (fs::exists(g_paths.nodes)) {
        const fs::path backup = g_paths.win64Dir /
            (L"TeleportLite_nodes_backup_" + Utf8ToWide(BackupStamp()) + L".tsv");
        fs::copy_file(g_paths.nodes, backup, fs::copy_options::overwrite_existing,
                      copyError);
    }
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        g_nodes = imported;
        std::set<std::string> valid;
        for (const Node& node : g_nodes) valid.insert(node.id);
        for (auto it = g_hotkeys.begin(); it != g_hotkeys.end();) {
            if (!valid.count(it->second)) it = g_hotkeys.erase(it);
            else ++it;
        }
        SaveHotkeysLocked();
    }
    if (!SaveNodes()) {
        SetUiStatus(g_english ? L"Imported data could not be saved."
                              : L"无法保存导入的数据。");
        return;
    }
    RefreshNodeList();
    SetUiStatus(g_english ? L"Node import complete." : L"节点导入完成。");
}

void ExportNodes() {
    const auto path = ChooseFile(true);
    if (!path) return;
    std::vector<Node> nodes;
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        nodes = g_nodes;
    }
    if (!SaveNodeFile(*path, nodes)) {
        SetUiStatus(g_english ? L"Node export failed." : L"节点导出失败。");
        return;
    }
    SetUiStatus(g_english ? L"Node export complete." : L"节点导出完成。");
}

void ShowContextMenu(POINT point) {
    const auto selected = SelectedNode();
    if (!selected) return;
    HMENU menu = CreatePopupMenu();
    HMENU bindMenu = CreatePopupMenu();
    HMENU clearMenu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, IDM_TELEPORT,
                g_english ? L"Teleport here" : L"瞬移到这里");
    AppendMenuW(menu, MF_STRING, IDM_RENAME,
                g_english ? L"Edit names" : L"编辑名称");
    AppendMenuW(menu, MF_STRING, IDM_DELETE,
                g_english ? L"Delete" : L"删除");
    AppendMenuW(menu, MF_STRING, IDM_COPY_COORDS,
                g_english ? L"Copy coordinates" : L"复制坐标");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    for (int key = 1; key <= 9; ++key) {
        const std::wstring label = (g_english ? L"Numpad " : L"小键盘 ") +
                                   std::to_wstring(key);
        AppendMenuW(bindMenu, MF_STRING, IDM_BIND_BASE + key, label.c_str());
        AppendMenuW(clearMenu, MF_STRING, IDM_CLEAR_BASE + key, label.c_str());
    }
    AppendMenuW(bindMenu, MF_STRING, IDM_BIND_BASE, g_english ? L"Numpad 0" : L"小键盘 0");
    AppendMenuW(clearMenu, MF_STRING, IDM_CLEAR_BASE, g_english ? L"Numpad 0" : L"小键盘 0");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(bindMenu),
                g_english ? L"Bind to numpad" : L"绑定到小键盘");
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(clearMenu),
                g_english ? L"Clear numpad binding" : L"清除小键盘绑定");
    const int command = TrackPopupMenu(
        menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, point.x, point.y, 0, g_window, nullptr);
    if (command == IDM_TELEPORT) QueueSelectedTeleport();
    else if (command == IDM_RENAME) LoadSelectedIntoEditors();
    else if (command == IDM_DELETE) DeleteSelected();
    else if (command == IDM_COPY_COORDS) CopySelectedCoordinates();
    else if (command >= IDM_BIND_BASE && command <= IDM_BIND_BASE + 9)
        BindSelected(command - IDM_BIND_BASE);
    else if (command >= IDM_CLEAR_BASE && command <= IDM_CLEAR_BASE + 9)
        ClearBinding(command - IDM_CLEAR_BASE);
    DestroyMenu(menu);
}

void LayoutControls(HWND window) {
    RECT client{};
    GetClientRect(window, &client);
    const int width = client.right - client.left;
    const int height = client.bottom - client.top;
    MoveWindow(g_searchLabel, 12, 15, 52, 24, TRUE);
    MoveWindow(g_search, 70, 11, std::max(180, width - 420), 26, TRUE);
    MoveWindow(g_count, std::max(300, width - 330), 15, 180, 24, TRUE);
    MoveWindow(g_language, width - 130, 9, 116, 30, TRUE);
    MoveWindow(g_nameZhLabel, 12, 51, 92, 24, TRUE);
    MoveWindow(g_nameZh, 108, 47, std::max(180, (width - 238) / 2), 26, TRUE);
    const int secondX = 118 + std::max(180, (width - 238) / 2);
    MoveWindow(g_nameEnLabel, secondX, 51, 92, 24, TRUE);
    MoveWindow(g_nameEn, secondX + 96, 47,
               std::max(180, width - secondX - 110), 26, TRUE);
    MoveWindow(g_coordLabel, 12, 87, 92, 24, TRUE);
    MoveWindow(g_coord, 108, 83, std::max(260, width - 122), 26, TRUE);
    int x = 12;
    for (HWND button : {g_saveCurrent, g_teleportCoord, g_rename, g_delete,
                        g_import, g_export}) {
        MoveWindow(button, x, 119, 140, 31, TRUE);
        x += 148;
    }
    MoveWindow(g_list, 12, 160, width - 24, std::max(100, height - 196), TRUE);
    MoveWindow(g_status, 12, height - 30, width - 24, 22, TRUE);
}

void CreateControls(HWND window) {
    const DWORD labelStyle = WS_CHILD | WS_VISIBLE | SS_LEFT;
    const DWORD editStyle = WS_CHILD | WS_VISIBLE | WS_BORDER | ES_AUTOHSCROLL;
    const DWORD buttonStyle = WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON;
    g_searchLabel = CreateWindowW(L"STATIC", L"", labelStyle, 0, 0, 0, 0,
                                  window, reinterpret_cast<HMENU>(IDC_SEARCH_LABEL),
                                  g_instance, nullptr);
    g_search = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", editStyle,
                               0, 0, 0, 0, window,
                               reinterpret_cast<HMENU>(IDC_SEARCH), g_instance, nullptr);
    g_count = CreateWindowW(L"STATIC", L"", labelStyle, 0, 0, 0, 0,
                            window, reinterpret_cast<HMENU>(IDC_COUNT),
                            g_instance, nullptr);
    g_language = CreateWindowW(L"BUTTON", L"", buttonStyle, 0, 0, 0, 0,
                               window, reinterpret_cast<HMENU>(IDC_LANGUAGE),
                               g_instance, nullptr);
    g_nameZhLabel = CreateWindowW(L"STATIC", L"", labelStyle, 0, 0, 0, 0,
                                  window, reinterpret_cast<HMENU>(IDC_NAME_ZH_LABEL),
                                  g_instance, nullptr);
    g_nameZh = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", editStyle,
                               0, 0, 0, 0, window,
                               reinterpret_cast<HMENU>(IDC_NAME_ZH), g_instance, nullptr);
    g_nameEnLabel = CreateWindowW(L"STATIC", L"", labelStyle, 0, 0, 0, 0,
                                  window, reinterpret_cast<HMENU>(IDC_NAME_EN_LABEL),
                                  g_instance, nullptr);
    g_nameEn = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", editStyle,
                               0, 0, 0, 0, window,
                               reinterpret_cast<HMENU>(IDC_NAME_EN), g_instance, nullptr);
    g_coordLabel = CreateWindowW(L"STATIC", L"", labelStyle, 0, 0, 0, 0,
                                 window, reinterpret_cast<HMENU>(IDC_COORD_LABEL),
                                 g_instance, nullptr);
    g_coord = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"X: 0 | Y: 0 | Z: 0",
                              editStyle, 0, 0, 0, 0, window,
                              reinterpret_cast<HMENU>(IDC_COORD), g_instance, nullptr);
    g_saveCurrent = CreateWindowW(L"BUTTON", L"", buttonStyle, 0, 0, 0, 0,
                                  window, reinterpret_cast<HMENU>(IDC_SAVE_CURRENT),
                                  g_instance, nullptr);
    g_teleportCoord = CreateWindowW(L"BUTTON", L"", buttonStyle, 0, 0, 0, 0,
                                    window, reinterpret_cast<HMENU>(IDC_TELEPORT_COORD),
                                    g_instance, nullptr);
    g_rename = CreateWindowW(L"BUTTON", L"", buttonStyle, 0, 0, 0, 0,
                             window, reinterpret_cast<HMENU>(IDC_RENAME),
                             g_instance, nullptr);
    g_delete = CreateWindowW(L"BUTTON", L"", buttonStyle, 0, 0, 0, 0,
                             window, reinterpret_cast<HMENU>(IDC_DELETE),
                             g_instance, nullptr);
    g_import = CreateWindowW(L"BUTTON", L"", buttonStyle, 0, 0, 0, 0,
                             window, reinterpret_cast<HMENU>(IDC_IMPORT),
                             g_instance, nullptr);
    g_export = CreateWindowW(L"BUTTON", L"", buttonStyle, 0, 0, 0, 0,
                             window, reinterpret_cast<HMENU>(IDC_EXPORT),
                             g_instance, nullptr);
    g_list = CreateWindowExW(
        WS_EX_CLIENTEDGE, WC_LISTVIEWW, L"",
        WS_CHILD | WS_VISIBLE | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS,
        0, 0, 0, 0, window, reinterpret_cast<HMENU>(IDC_LIST), g_instance, nullptr);
    g_status = CreateWindowW(L"STATIC", L"", labelStyle | SS_SUNKEN,
                             0, 0, 0, 0, window,
                             reinterpret_cast<HMENU>(IDC_STATUS), g_instance, nullptr);

    const HFONT font = static_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
    for (HWND control : {g_searchLabel, g_search, g_count, g_language,
                         g_nameZhLabel, g_nameZh, g_nameEnLabel, g_nameEn,
                         g_coordLabel, g_coord, g_saveCurrent, g_teleportCoord,
                         g_rename, g_delete, g_import, g_export, g_list, g_status}) {
        SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
    }
    ListView_SetExtendedListViewStyle(
        g_list, LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES | LVS_EX_DOUBLEBUFFER);
    ListView_EnableGroupView(g_list, TRUE);
    LVCOLUMNW column{};
    column.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
    column.cx = 330;
    column.pszText = const_cast<wchar_t*>(L"Name");
    ListView_InsertColumn(g_list, 0, &column);
    column.cx = 70;
    column.iSubItem = 1;
    column.pszText = const_cast<wchar_t*>(L"No.");
    ListView_InsertColumn(g_list, 1, &column);
    column.cx = 430;
    column.iSubItem = 2;
    column.pszText = const_cast<wchar_t*>(L"Coordinates");
    ListView_InsertColumn(g_list, 2, &column);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_CREATE:
        g_window = window;
        CreateControls(window);
        ApplyLanguage();
        LayoutControls(window);
        return 0;
    case WM_SIZE:
        LayoutControls(window);
        return 0;
    case WM_COMMAND: {
        const int id = LOWORD(wParam);
        if (id == IDC_SEARCH && HIWORD(wParam) == EN_CHANGE) RefreshNodeList();
        else if (id == IDC_LANGUAGE) {
            g_english = !g_english;
            SaveLanguageSetting();
            ApplyLanguage();
        } else if (id == IDC_SAVE_CURRENT) {
            Request request;
            request.type = RequestType::Save;
            request.nameZh = GetWindowTextString(g_nameZh);
            request.nameEn = GetWindowTextString(g_nameEn);
            QueueRequest(std::move(request));
        } else if (id == IDC_TELEPORT_COORD) {
            Node node;
            if (!ParseCoordinates(GetWindowTextString(g_coord), node)) {
                SetUiStatus(g_english ? L"Enter three valid coordinates."
                                      : L"请输入三个有效坐标。");
            } else {
                node.id = "manual";
                node.nameZh = L"手动坐标";
                node.nameEn = L"Manual Coordinates";
                Request request;
                request.type = RequestType::Teleport;
                request.node = node;
                QueueRequest(std::move(request));
            }
        } else if (id == IDC_RENAME) RenameSelected();
        else if (id == IDC_DELETE) DeleteSelected();
        else if (id == IDC_IMPORT) ImportNodes();
        else if (id == IDC_EXPORT) ExportNodes();
        return 0;
    }
    case WM_NOTIFY: {
        const auto* header = reinterpret_cast<NMHDR*>(lParam);
        if (header && header->idFrom == IDC_LIST) {
            if (header->code == NM_DBLCLK) QueueSelectedTeleport();
            else if (header->code == NM_RCLICK) {
                POINT point{};
                GetCursorPos(&point);
                ShowContextMenu(point);
            } else if (header->code == LVN_ITEMCHANGED) {
                const auto* changed = reinterpret_cast<NMLISTVIEW*>(lParam);
                if (changed && (changed->uNewState & LVIS_SELECTED)) {
                    const auto node = SelectedNode();
                    if (node) SetWindowTextW(g_coord, CoordinateText(*node).c_str());
                }
            }
        }
        return 0;
    }
    case WM_TL_REFRESH:
        RefreshNodeList();
        return 0;
    case WM_TL_STATUS:
        InvalidateRect(g_status, nullptr, TRUE);
        return 0;
    case WM_TL_TOGGLE:
        if (IsWindowVisible(window)) {
            ShowWindow(window, SW_HIDE);
        } else {
            ShowWindow(window, SW_RESTORE);
            SetForegroundWindow(window);
        }
        return 0;
    case WM_CLOSE:
        ShowWindow(window, SW_HIDE);
        return 0;
    case WM_DESTROY:
        g_searchLabel = nullptr;
        g_search = nullptr;
        g_count = nullptr;
        g_language = nullptr;
        g_nameZhLabel = nullptr;
        g_nameZh = nullptr;
        g_nameEnLabel = nullptr;
        g_nameEn = nullptr;
        g_coordLabel = nullptr;
        g_coord = nullptr;
        g_saveCurrent = nullptr;
        g_teleportCoord = nullptr;
        g_rename = nullptr;
        g_delete = nullptr;
        g_import = nullptr;
        g_export = nullptr;
        g_list = nullptr;
        g_status = nullptr;
        g_window = nullptr;
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProcW(window, message, wParam, lParam);
    }
}

void UiMain() {
    INITCOMMONCONTROLSEX controls{};
    controls.dwSize = sizeof(controls);
    controls.dwICC = ICC_LISTVIEW_CLASSES | ICC_STANDARD_CLASSES;
    InitCommonControlsEx(&controls);
    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.lpfnWndProc = WindowProc;
    windowClass.hInstance = g_instance;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    windowClass.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    windowClass.lpszClassName = kWindowClass;
    RegisterClassExW(&windowClass);
    HWND window = CreateWindowExW(
        WS_EX_APPWINDOW, kWindowClass, kWindowTitleEn,
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 980, 680,
        nullptr, nullptr, g_instance, nullptr);
    if (!window) {
        Diag("native UI window creation failed");
        return;
    }
    ShowWindow(window, SW_HIDE);
    MSG message{};
    while (!g_stop.load(std::memory_order_acquire) &&
           GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    if (IsWindow(window)) DestroyWindow(window);
    UnregisterClassW(kWindowClass, g_instance);
}

void ToggleUi() {
    if (g_window) {
        PostMessageW(g_window, WM_TL_TOGGLE, 0, 0);
    } else {
        SetResult("FAILED", "The native UI is not ready yet.",
                  L"原生 UI 尚未准备完成，请稍后再按 F6。");
    }
}

void DispatchLine(const std::string& line) {
    const auto fields = Split(TrimAscii(line), '|');
    if (fields.empty()) return;
    if (fields[0] == "TOGGLE_UI") {
        ToggleUi();
    } else if (fields[0] == "SAVE_AUTO") {
        Request request;
        request.type = RequestType::Save;
        QueueRequest(std::move(request));
    } else if (fields[0] == "LIST") {
        Request request;
        request.type = RequestType::List;
        QueueRequest(std::move(request));
    } else if (fields[0] == "HOTKEY" && fields.size() >= 2) {
        try {
            const int key = std::stoi(fields[1]);
            if (key >= 0 && key <= 9) {
                Request request;
                request.type = RequestType::Hotkey;
                request.hotkey = key;
                QueueRequest(std::move(request));
            }
        } catch (...) {
            SetResult("FAILED", "Invalid numpad command.", L"小键盘命令无效。");
        }
    }
}

bool PrepareData() {
    std::error_code error;
    if (!fs::exists(g_paths.nodes)) {
        fs::copy_file(g_paths.defaultNodes, g_paths.nodes,
                      fs::copy_options::overwrite_existing, error);
        if (error) {
            Diag("default node copy failed: " + error.message());
            return false;
        }
    }
    std::vector<Node> nodes;
    std::wstring loadError;
    if (!LoadNodeFile(g_paths.nodes, nodes, loadError, false)) {
        Diag("node load failed: " + WideToUtf8(loadError));
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(g_nodesMutex);
        g_nodes = std::move(nodes);
    }
    LoadHotkeys();
    LoadLanguageSetting();
    return true;
}

void InitializeNative() {
    std::lock_guard<std::mutex> lock(g_lifecycleMutex);
    if (g_initialized.load(std::memory_order_acquire)) return;
    g_paths.moduleDir = ModuleDirectory();
    if (g_paths.moduleDir.empty()) return;
    g_paths.win64Dir = g_paths.moduleDir.parent_path().parent_path();
    g_paths.command = g_paths.win64Dir / kCommandFile;
    g_paths.nodes = g_paths.win64Dir / kNodesFile;
    g_paths.defaultNodes = g_paths.moduleDir / kDefaultNodesRelative;
    g_paths.hotkeys = g_paths.win64Dir / kHotkeysFile;
    g_paths.settings = g_paths.win64Dir / kSettingsFile;
    g_paths.status = g_paths.win64Dir / kStatusFile;
    g_paths.diag = g_paths.win64Dir / kDiagFile;
    WriteText(g_paths.diag,
              "[" + NowText() +
                  "] TeleportLiteNative 1.0.0-test initialized; one in-process DLL\r\n",
              false);
    if (!PrepareData()) {
        WriteStatusFile("FAILED", "Default node data could not be loaded.");
        return;
    }
    g_stop.store(false, std::memory_order_release);
    g_worker = std::thread(WorkerMain);
    g_uiThread = std::thread(UiMain);
    g_initialized.store(true, std::memory_order_release);
    WriteStatusFile("READY", "F6 opens Teleport Lite.");
    Diag("ready nodes=" + std::to_string(g_nodes.size()));
}

void DispatchCommand() {
    InitializeNative();
    if (!g_initialized.load(std::memory_order_acquire)) return;
    std::ifstream input(g_paths.command, std::ios::binary);
    std::string line;
    std::getline(input, line);
    input.close();
    std::error_code error;
    fs::remove(g_paths.command, error);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    DispatchLine(line);
}

void ShutdownNative() {
    std::lock_guard<std::mutex> lock(g_lifecycleMutex);
    if (!g_initialized.exchange(false)) return;
    g_stop.store(true, std::memory_order_release);
    g_queueCv.notify_all();
    if (g_window) PostMessageW(g_window, WM_DESTROY, 0, 0);
    if (g_worker.joinable() && g_worker.get_id() != std::this_thread::get_id()) {
        g_worker.join();
    }
    if (g_uiThread.joinable() && g_uiThread.get_id() != std::this_thread::get_id()) {
        g_uiThread.join();
    }
    WriteStatusFile("STOPPED", "Teleport Lite stopped.");
}

}  // namespace

extern "C" __declspec(dllexport) int TeleportLiteInitialize(void*) {
    InitializeNative();
    return 0;
}

extern "C" __declspec(dllexport) int TeleportLiteDispatch(void*) {
    DispatchCommand();
    return 0;
}

extern "C" __declspec(dllexport) int TeleportLiteShutdown(void*) {
    ShutdownNative();
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_instance = instance;
        DisableThreadLibraryCalls(instance);
    } else if (reason == DLL_PROCESS_DETACH) {
        g_stop.store(true, std::memory_order_release);
    }
    return TRUE;
}
