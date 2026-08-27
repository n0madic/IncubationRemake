// dbgcall -- call functions inside a live 32-bit Windows process.
//
// Runs a 32-bit target under a debugger, waits for a breakpoint, then calls
// functions inside the live process with arguments of your choosing.
//
// See README.md for the design; the short version:
//
//   - addresses may be absolute, `rva:` against the main image, or
//     `Module.dll+0x...`, resolved from the debugger's own module table
//   - a call is described by an ABI signature, which the harness then
//     *verifies* against the callee's actual stack cleanup
//   - arguments are expressions over the frozen breakpoint context, target
//     memory, remote buffers and previous results -- not just constants
//   - one run can drive a whole batch of calls and emit JSONL

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <cwctype>

#include <algorithm>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#ifdef _WIN64
#error This harness must be compiled as x86 (32-bit).
#endif

// ------------------------------------------------------------
// Utilities
// ------------------------------------------------------------

static std::wstring WinErrorMessage(DWORD err = GetLastError())
{
    wchar_t* buf = nullptr;

    DWORD flags =
        FORMAT_MESSAGE_ALLOCATE_BUFFER |
        FORMAT_MESSAGE_FROM_SYSTEM |
        FORMAT_MESSAGE_IGNORE_INSERTS;

    DWORD n = FormatMessageW(
        flags, nullptr, err, 0,
        reinterpret_cast<wchar_t*>(&buf), 0, nullptr);

    std::wstring s;
    if (n && buf)
        s.assign(buf, n);
    else
        s = L"Unknown Windows error";

    if (buf)
        LocalFree(buf);

    while (!s.empty() &&
           (s.back() == L'\n' || s.back() == L'\r'))
    {
        s.pop_back();
    }

    return s;
}

[[noreturn]]
static void Die(const std::wstring& msg)
{
    std::wcerr << L"[!] " << msg << L"\n";
    std::wcerr.flush();
    ExitProcess(1);
}

[[noreturn]]
static void DieWin(const std::wstring& msg)
{
    DWORD e = GetLastError();

    std::wcerr
        << L"[!] " << msg
        << L"\n    error=" << e
        << L": " << WinErrorMessage(e)
        << L"\n";

    std::wcerr.flush();
    ExitProcess(1);
}

static std::wstring Lower(std::wstring s)
{
    std::transform(
        s.begin(), s.end(), s.begin(),
        [](wchar_t c) {
            return static_cast<wchar_t>(std::towlower(c));
        });

    return s;
}

static std::wstring Trim(const std::wstring& s)
{
    size_t a = s.find_first_not_of(L" \t\r\n");

    if (a == std::wstring::npos)
        return {};

    size_t b = s.find_last_not_of(L" \t\r\n");

    return s.substr(a, b - a + 1);
}

static std::vector<std::wstring> SplitWs(const std::wstring& s)
{
    std::vector<std::wstring> out;
    std::wstring cur;

    for (wchar_t c : s)
    {
        if (c == L' ' || c == L'\t' || c == L'\r' || c == L'\n')
        {
            if (!cur.empty())
            {
                out.push_back(cur);
                cur.clear();
            }
        }
        else
        {
            cur.push_back(c);
        }
    }

    if (!cur.empty())
        out.push_back(cur);

    return out;
}

// Whitespace-separated tokens, except inside `"`, `[]`, `()` or `{}` -- so
// `--poke A:B=>e9{rel32 &tramp}` survives being written on a line of a plan
// file rather than in a shell's quotes. A token wrapped in quotes loses them,
// the way a shell would remove them.
static std::vector<std::wstring> SplitTokens(const std::wstring& s)
{
    std::vector<std::wstring> out;
    std::wstring cur;
    int depth = 0;
    bool quoted = false;

    auto flush = [&]()
    {
        if (cur.empty())
            return;

        if (cur.size() >= 2 && cur.front() == L'"' && cur.back() == L'"')
            cur = cur.substr(1, cur.size() - 2);

        out.push_back(cur);
        cur.clear();
    };

    for (wchar_t c : s)
    {
        if (c == L'"')
            quoted = !quoted;
        else if (!quoted && (c == L'[' || c == L'(' || c == L'{'))
            ++depth;
        else if (!quoted && (c == L']' || c == L')' || c == L'}'))
            --depth;

        if (!quoted && depth <= 0 &&
            (c == L' ' || c == L'\t' || c == L'\r' || c == L'\n'))
        {
            flush();
            continue;
        }

        cur.push_back(c);
    }

    flush();

    return out;
}

static std::wstring Hex32(uint32_t v)
{
    std::wostringstream o;

    o << L"0x"
      << std::hex << std::setw(8) << std::setfill(L'0')
      << v;

    return o.str();
}

static std::vector<uint8_t> ParseHexBytes(const std::wstring& s)
{
    std::vector<uint8_t> out;
    std::wstring clean;

    for (wchar_t c : s)
    {
        if (c == L' ' || c == L'_' || c == L'-')
            continue;

        clean.push_back(c);
    }

    if (clean.size() % 2)
        Die(L"Hex byte string must have an even length: " + s);

    for (size_t i = 0; i < clean.size(); i += 2)
    {
        std::wstring byte = clean.substr(i, 2);
        wchar_t* end = nullptr;

        unsigned long v = std::wcstoul(byte.c_str(), &end, 16);

        if (!end || *end != L'\0')
            Die(L"Invalid hex byte `" + byte + L"` in: " + s);

        out.push_back(static_cast<uint8_t>(v));
    }

    return out;
}

// ------------------------------------------------------------
// Byte patterns
//
// Hex bytes with holes in them. A hole is `{EXPR}`, four bytes holding the
// address EXPR evaluates to, or `{rel32 EXPR}`, the displacement from the end
// of the hole to that address -- what a near jmp or call needs.
//
// Both are filled in when the bytes are written, because both can depend on
// where they are written and on where a buffer was allocated. That is what
// lets injected code live on a page of its own instead of in the image's tail
// padding: `{&tramp}` in the patch and `{rel32 0x42073a}` inside the
// trampoline are exactly the two addresses that cannot be known in advance.
// ------------------------------------------------------------

struct BytePattern
{
    struct Fixup
    {
        uint32_t offset = 0;    // where the four bytes sit
        bool rel32 = false;
        std::wstring expr;
    };

    std::vector<uint8_t> bytes;
    std::vector<Fixup> fixups;
};

static BytePattern ParseBytePattern(const std::wstring& s)
{
    BytePattern p;
    std::wstring literal;

    for (size_t i = 0; i < s.size(); ++i)
    {
        if (s[i] != L'{')
        {
            literal.push_back(s[i]);
            continue;
        }

        size_t end = s.find(L'}', i);

        if (end == std::wstring::npos)
            Die(L"Unterminated `{` in byte pattern: " + s);

        std::vector<uint8_t> lit = ParseHexBytes(literal);
        p.bytes.insert(p.bytes.end(), lit.begin(), lit.end());
        literal.clear();

        std::wstring inner = Trim(s.substr(i + 1, end - i - 1));

        BytePattern::Fixup f;
        f.offset = static_cast<uint32_t>(p.bytes.size());

        if (Lower(inner).rfind(L"rel32", 0) == 0 &&
            inner.size() > 5 &&
            (inner[5] == L' ' || inner[5] == L'\t'))
        {
            f.rel32 = true;
            f.expr = Trim(inner.substr(5));
        }
        else
        {
            f.expr = inner;
        }

        if (f.expr.empty())
            Die(L"Empty expression in byte pattern: " + s);

        p.fixups.push_back(f);
        p.bytes.insert(p.bytes.end(), 4, 0);

        i = end;
    }

    std::vector<uint8_t> lit = ParseHexBytes(literal);
    p.bytes.insert(p.bytes.end(), lit.begin(), lit.end());

    return p;
}

static std::wstring HexBytes(const std::vector<uint8_t>& b)
{
    std::wostringstream o;

    o << std::hex << std::setfill(L'0');

    for (size_t i = 0; i < b.size(); ++i)
    {
        if (i && (i % 4) == 0)
            o << L' ';

        o << std::setw(2) << static_cast<unsigned>(b[i]);
    }

    return o.str();
}

static bool ParseU64Checked(const std::wstring& s, uint64_t& out)
{
    if (s.empty())
        return false;

    wchar_t* end = nullptr;
    errno = 0;

    unsigned long long v =
        std::wcstoull(s.c_str(), &end, 0);

    if (!end || *end != L'\0')
        return false;

    out = static_cast<uint64_t>(v);
    return true;
}

static bool ParseI64Checked(const std::wstring& s, int64_t& out)
{
    if (s.empty())
        return false;

    wchar_t* end = nullptr;

    long long v =
        std::wcstoll(s.c_str(), &end, 0);

    if (!end || *end != L'\0')
        return false;

    out = static_cast<int64_t>(v);
    return true;
}

static uint64_t ParseU64(const std::wstring& s)
{
    uint64_t v = 0;

    if (!ParseU64Checked(s, v))
        Die(L"Invalid integer: " + s);

    return v;
}

static int64_t ParseI64(const std::wstring& s)
{
    int64_t v = 0;

    if (!ParseI64Checked(s, v))
        Die(L"Invalid signed integer: " + s);

    return v;
}

static double ParseF64(const std::wstring& s)
{
    try {
        size_t pos = 0;
        double d = std::stod(s, &pos);

        if (pos != s.size())
            Die(L"Invalid floating point value: " + s);

        return d;
    }
    catch (...) {
        Die(L"Invalid floating point value: " + s);
    }
}

static uint64_t DoubleBits(double d)
{
    uint64_t bits = 0;
    static_assert(sizeof(bits) == sizeof(d));

    std::memcpy(&bits, &d, sizeof(bits));
    return bits;
}

static double BitsDouble(uint64_t bits)
{
    double d = 0;
    std::memcpy(&d, &bits, sizeof(d));
    return d;
}

static uint32_t FloatBits(float f)
{
    uint32_t bits = 0;
    static_assert(sizeof(bits) == sizeof(f));

    std::memcpy(&bits, &f, sizeof(bits));
    return bits;
}

// The target binaries this harness exists for are 1997 MSVC builds that know
// nothing about UTF-8; string arguments go in as the active ANSI code page.
static std::string WideToAnsi(const std::wstring& s)
{
    if (s.empty())
        return {};

    int n = WideCharToMultiByte(
        CP_ACP, 0, s.data(), static_cast<int>(s.size()),
        nullptr, 0, nullptr, nullptr);

    if (n <= 0)
        DieWin(L"WideCharToMultiByte(size)");

    std::string out;
    out.resize(n);

    if (!WideCharToMultiByte(
            CP_ACP, 0, s.data(), static_cast<int>(s.size()),
            out.data(), n, nullptr, nullptr))
    {
        DieWin(L"WideCharToMultiByte");
    }

    return out;
}

static std::wstring AnsiToWide(const std::string& s)
{
    if (s.empty())
        return {};

    int n = MultiByteToWideChar(
        CP_ACP, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);

    if (n <= 0)
        return {};

    std::wstring out;
    out.resize(n);

    MultiByteToWideChar(
        CP_ACP, 0, s.data(), static_cast<int>(s.size()),
        out.data(), n);

    return out;
}

static std::wstring BaseName(const std::wstring& path)
{
    size_t p = path.find_last_of(L"\\/");

    if (p == std::wstring::npos)
        return path;

    return path.substr(p + 1);
}

// Standard CreateProcess command line quoting.
static std::wstring QuoteArg(const std::wstring& s)
{
    if (s.empty())
        return L"\"\"";

    if (s.find_first_of(L" \t\"") == std::wstring::npos)
        return s;

    std::wstring out;
    out.push_back(L'"');

    size_t backslashes = 0;

    for (wchar_t c : s)
    {
        if (c == L'\\')
        {
            ++backslashes;
            continue;
        }

        if (c == L'"')
        {
            out.append(backslashes * 2 + 1, L'\\');
            out.push_back(L'"');
            backslashes = 0;
            continue;
        }

        out.append(backslashes, L'\\');
        backslashes = 0;
        out.push_back(c);
    }

    out.append(backslashes * 2, L'\\');
    out.push_back(L'"');

    return out;
}

static std::wstring JsonEscape(const std::wstring& s)
{
    std::wstring out;

    for (wchar_t c : s)
    {
        switch (c)
        {
            case L'"':  out += L"\\\""; break;
            case L'\\': out += L"\\\\"; break;
            case L'\n': out += L"\\n";  break;
            case L'\r': out += L"\\r";  break;
            case L'\t': out += L"\\t";  break;
            default:
                if (c < 0x20)
                {
                    std::wostringstream o;
                    o << L"\\u"
                      << std::hex << std::setw(4) << std::setfill(L'0')
                      << static_cast<unsigned>(c);
                    out += o.str();
                }
                else
                {
                    out.push_back(c);
                }
        }
    }

    return out;
}


// ------------------------------------------------------------
// ABI types and signatures
//
//   [__cdecl|__stdcall|__thiscall|__fastcall] RET (P1, P2, ...)
//
// Every parameter is a whole number of 4-byte stack slots. `this` under
// __thiscall is an explicit first parameter: the harness has no notion of a
// class, and an implicit one would break the arity check that gives the
// signature its value.
// ------------------------------------------------------------

using Va = uint32_t;

enum class SlotType
{
    Void,
    I32,
    U32,
    Ptr,
    I64,
    U64,
    F32,
    F64,
    Str,
    WStr,
    Bytes       // a struct passed by value: `bytes12`
};

// A parameter is a type plus, for `bytesN`, how many bytes of it there are.
struct Param
{
    SlotType type = SlotType::I32;
    uint32_t bytes = 0;
};

static bool ParseSlotType(const std::wstring& s, SlotType& out);

// `bytesN` is a struct of N bytes passed by value.
static bool ParseParam(const std::wstring& s, Param& out)
{
    std::wstring t = Lower(Trim(s));

    if (t.rfind(L"bytes", 0) == 0)
    {
        uint64_t n = 0;

        if (!ParseU64Checked(t.substr(5), n) || n == 0 || n > 0x400)
            return false;

        out.type = SlotType::Bytes;
        out.bytes = static_cast<uint32_t>(n);
        return true;
    }

    out.bytes = 0;
    return ParseSlotType(t, out.type);
}

static bool ParseSlotType(const std::wstring& s, SlotType& out)
{
    std::wstring t = Lower(Trim(s));

    if (t == L"void")               { out = SlotType::Void; return true; }
    if (t == L"i32" || t == L"int") { out = SlotType::I32;  return true; }
    if (t == L"u32")                { out = SlotType::U32;  return true; }
    if (t == L"ptr" || t == L"hex") { out = SlotType::Ptr;  return true; }
    if (t == L"i64")                { out = SlotType::I64;  return true; }
    if (t == L"u64")                { out = SlotType::U64;  return true; }
    if (t == L"f32" || t == L"float")  { out = SlotType::F32; return true; }
    if (t == L"f64" || t == L"double") { out = SlotType::F64; return true; }
    if (t == L"str")                { out = SlotType::Str;  return true; }
    if (t == L"wstr")               { out = SlotType::WStr; return true; }

    return false;
}

static const wchar_t* SlotTypeName(SlotType t)
{
    switch (t)
    {
        case SlotType::Void: return L"void";
        case SlotType::I32:  return L"i32";
        case SlotType::U32:  return L"u32";
        case SlotType::Ptr:  return L"ptr";
        case SlotType::I64:  return L"i64";
        case SlotType::U64:  return L"u64";
        case SlotType::F32:  return L"f32";
        case SlotType::F64:  return L"f64";
        case SlotType::Str:  return L"str";
        case SlotType::WStr: return L"wstr";
        case SlotType::Bytes: return L"bytes";
    }

    return L"?";
}

// How many 4-byte slots a parameter occupies. A struct passed by value is
// simply its bytes on the stack, rounded up to whole slots -- on x86 there
// is no hidden pointer and no register involved.
static uint32_t SlotCount(const Param& p)
{
    switch (p.type)
    {
        case SlotType::I64:
        case SlotType::U64:
        case SlotType::F64:
            return 2;

        case SlotType::Void:
            return 0;

        case SlotType::Bytes:
            return (p.bytes + 3) / 4;

        default:
            return 1;
    }
}

// A parameter that can travel in ECX/EDX: dword-sized and integral.
static bool IsRegisterEligible(const Param& p)
{
    switch (p.type)
    {
        case SlotType::I32:
        case SlotType::U32:
        case SlotType::Ptr:
        case SlotType::Str:
        case SlotType::WStr:
            return true;

        default:
            // F32 is a dword, but MSVC never passes floating point in the
            // integer registers, so it stays on the stack. A by-value struct
            // is left on the stack too: MSVC can put a 4-byte one in a
            // register under __fastcall, and guessing wrong would be worse
            // than making the caller spell it out as u32.
            return false;
    }
}

static std::wstring ParamName(const Param& p)
{
    if (p.type == SlotType::Bytes)
        return L"bytes" + std::to_wstring(p.bytes);

    return SlotTypeName(p.type);
}

static bool ReturnsFloat(SlotType t)
{
    return t == SlotType::F32 || t == SlotType::F64;
}

enum class CallConv
{
    Cdecl,
    Stdcall,
    Thiscall,
    Fastcall
};

static bool ParseCallConv(const std::wstring& s, CallConv& out)
{
    std::wstring t = Lower(Trim(s));

    if (!t.empty() && t.rfind(L"__", 0) == 0)
        t = t.substr(2);

    if (t == L"cdecl")    { out = CallConv::Cdecl;    return true; }
    if (t == L"stdcall")  { out = CallConv::Stdcall;  return true; }
    if (t == L"thiscall") { out = CallConv::Thiscall; return true; }
    if (t == L"fastcall") { out = CallConv::Fastcall; return true; }

    return false;
}

static const wchar_t* CallConvName(CallConv cc)
{
    switch (cc)
    {
        case CallConv::Cdecl:    return L"__cdecl";
        case CallConv::Stdcall:  return L"__stdcall";
        case CallConv::Thiscall: return L"__thiscall";
        case CallConv::Fastcall: return L"__fastcall";
    }

    return L"?";
}

// Whether the callee pops its own arguments.
static bool CalleeCleans(CallConv cc)
{
    return cc != CallConv::Cdecl;
}

struct Signature
{
    bool haveCc = false;
    CallConv cc = CallConv::Cdecl;

    SlotType ret = SlotType::I32;
    std::vector<Param> params;

    // Present when the signature was written in the named, C-like form:
    //
    //   __cdecl i32 aCheckLineOfSight(ptr,i32,i32) = Incubation.exe+0x46C460
    //
    // The name is how a call refers to it; the address makes the declaration
    // self-contained, so a file of these needs no other columns.
    std::wstring name;
    std::wstring addressText;

    std::wstring text;
};

static Signature ParseSignature(const std::wstring& src)
{
    Signature sig;
    sig.text = Trim(src);

    std::wstring s = sig.text;

    size_t open = s.find(L'(');

    if (open == std::wstring::npos)
        Die(L"A signature must contain a parameter list: " + src);

    size_t close = s.rfind(L')');

    if (close == std::wstring::npos || close < open)
        Die(L"A signature must contain a parameter list: " + src);

    // Optional `= ADDRESS` after the parameter list.
    std::wstring tail = Trim(s.substr(close + 1));

    if (!tail.empty())
    {
        if (tail[0] != L'=')
            Die(L"Unexpected text after the parameter list: " + tail);

        sig.addressText = Trim(tail.substr(1));

        if (sig.addressText.empty())
            Die(L"`=` with no address in: " + src);
    }

    std::wstring head = Trim(s.substr(0, open));
    std::wstring body = Trim(s.substr(open + 1, close - open - 1));

    std::vector<std::wstring> headParts = SplitWs(head);

    if (headParts.empty())
        Die(L"Signature has no return type: " + src);

    if (headParts.size() > 3)
        Die(L"Cannot parse signature head: " + head);

    // Trailing name, as in `i32 aCheckLineOfSight(...)`.
    if (headParts.size() >= 2)
    {
        SlotType maybeRet;

        // Two tokens are either `cc ret` or `ret name`; three are `cc ret
        // name`. A second token that is not a type must be the name.
        if (headParts.size() == 3 ||
            !ParseSlotType(headParts.back(), maybeRet))
        {
            sig.name = headParts.back();
            headParts.pop_back();
        }
    }

    if (headParts.size() == 2)
    {
        if (!ParseCallConv(headParts[0], sig.cc))
        {
            Die(
                L"Unknown calling convention in signature: " + headParts[0] +
                L"\nSupported: __cdecl,__stdcall,__thiscall,__fastcall");
        }

        sig.haveCc = true;
        headParts.erase(headParts.begin());
    }

    if (headParts.size() != 1)
        Die(L"Cannot parse signature head: " + head);

    if (!ParseSlotType(headParts[0], sig.ret))
        Die(L"Unknown return type in signature: " + headParts[0]);

    if (sig.ret == SlotType::Str || sig.ret == SlotType::WStr)
    {
        Die(
            L"A string return type is ambiguous; declare `ptr` and read the "
            L"result with --read");
    }

    // Parameters.
    if (!body.empty() && Lower(body) != L"void")
    {
        std::wstring cur;

        auto flush = [&]()
        {
            std::wstring p = Trim(cur);
            cur.clear();

            Param t;

            if (!ParseParam(p, t))
                Die(L"Unknown parameter type in signature: " + p);

            if (t.type == SlotType::Void)
                Die(L"`void` is not a parameter type: " + src);

            sig.params.push_back(t);
        };

        for (wchar_t c : body)
        {
            if (c == L',')
                flush();
            else
                cur.push_back(c);
        }

        flush();
    }

    if (sig.haveCc &&
        sig.cc == CallConv::Thiscall &&
        sig.params.empty())
    {
        Die(
            L"__thiscall needs `this` as an explicit first parameter: " + src);
    }

    return sig;
}

// Total bytes the arguments occupy on the stack under this convention.
// This is what a callee-cleaning convention must pop, and what the harness
// checks the observed cleanup against.
static uint32_t StackArgBytes(const Signature& sig, CallConv cc)
{
    uint32_t slots = 0;

    size_t regsLeft = 0;

    if (cc == CallConv::Thiscall)
        regsLeft = 1;
    else if (cc == CallConv::Fastcall)
        regsLeft = 2;

    for (size_t i = 0; i < sig.params.size(); ++i)
    {
        const Param& t = sig.params[i];

        if (cc == CallConv::Thiscall && i == 0)
        {
            // `this` always takes ECX.
            regsLeft = 0;
            continue;
        }

        if (regsLeft && IsRegisterEligible(t))
        {
            --regsLeft;
            continue;
        }

        slots += SlotCount(t);
    }

    return slots * 4;
}

// ------------------------------------------------------------
// Module table
//
// Eng3d.dll is not in either EXE's import table -- it is brought in by
// LoadLibrary at runtime -- and its preferred base is 0x00400000, exactly
// where the EXE already sits, so it is relocated on every single run. An
// address quoted from a static disassembly of it is therefore meaningless
// without the base the loader actually chose, which only the debugger sees.
// ------------------------------------------------------------

struct ModuleInfo
{
    std::wstring name;      // basename, as loaded
    std::wstring path;
    Va base = 0;
    uint32_t size = 0;
};

class ModuleTable
{
public:
    void Add(const ModuleInfo& m)
    {
        std::wstring key = Lower(m.name);

        for (auto& e : modules_)
        {
            if (Lower(e.name) == key && e.base == m.base)
            {
                e = m;
                return;
            }
        }

        modules_.push_back(m);
    }

    void RemoveByBase(Va base)
    {
        modules_.erase(
            std::remove_if(
                modules_.begin(), modules_.end(),
                [base](const ModuleInfo& m) { return m.base == base; }),
            modules_.end());
    }

    // Returns 0 when the module is not loaded (yet).
    Va Find(const std::wstring& name, bool& ambiguous) const
    {
        std::wstring key = Lower(name);

        Va found = 0;
        int hits = 0;

        for (const auto& m : modules_)
        {
            if (Lower(m.name) == key)
            {
                if (!hits)
                    found = m.base;

                ++hits;
            }
        }

        ambiguous = hits > 1;
        return found;
    }

    // Best-effort reverse lookup, for readable diagnostics.
    std::wstring Describe(Va addr) const
    {
        for (const auto& m : modules_)
        {
            if (m.size &&
                addr >= m.base &&
                addr < m.base + m.size)
            {
                std::wostringstream o;
                o << m.name << L"+0x" << std::hex << (addr - m.base);
                return o.str();
            }
        }

        return Hex32(addr);
    }

    const std::vector<ModuleInfo>& All() const { return modules_; }

private:
    std::vector<ModuleInfo> modules_;
};

// SizeOfImage straight out of the mapped PE header, so Describe() can name
// an arbitrary address rather than only an exact base.
static uint32_t ReadImageSize(HANDLE process, Va base)
{
    IMAGE_DOS_HEADER dos{};
    SIZE_T got = 0;

    if (!ReadProcessMemory(
            process,
            reinterpret_cast<LPCVOID>(static_cast<uintptr_t>(base)),
            &dos, sizeof(dos), &got) ||
        got != sizeof(dos) ||
        dos.e_magic != IMAGE_DOS_SIGNATURE)
    {
        return 0;
    }

    IMAGE_NT_HEADERS32 nt{};

    if (!ReadProcessMemory(
            process,
            reinterpret_cast<LPCVOID>(
                static_cast<uintptr_t>(base + dos.e_lfanew)),
            &nt, sizeof(nt), &got) ||
        got != sizeof(nt) ||
        nt.Signature != IMAGE_NT_SIGNATURE)
    {
        return 0;
    }

    return nt.OptionalHeader.SizeOfImage;
}

// LOAD_DLL_DEBUG_EVENT.lpImageName is famously unreliable -- often NULL, or a
// pointer into memory the loader has already released -- so the file handle is
// the primary source and the name pointer only the last resort.
static std::wstring ResolveModuleName(
    HANDLE process,
    HANDLE file,
    LPVOID base,
    LPVOID imageNamePtr,
    WORD unicode)
{
    if (file)
    {
        wchar_t buf[MAX_PATH * 2];

        DWORD n = GetFinalPathNameByHandleW(
            file, buf, static_cast<DWORD>(std::size(buf)), 0);

        if (n && n < std::size(buf))
        {
            std::wstring s(buf, n);

            // Strip the \\?\ prefix GetFinalPathNameByHandleW adds.
            if (s.rfind(L"\\\\?\\", 0) == 0)
                s = s.substr(4);

            return s;
        }
    }

    {
        wchar_t buf[MAX_PATH * 2];

        DWORD n = GetMappedFileNameW(
            process, base, buf, static_cast<DWORD>(std::size(buf)));

        if (n && n < std::size(buf))
            return std::wstring(buf, n);
    }

    if (imageNamePtr)
    {
        LPVOID strPtr = nullptr;
        SIZE_T got = 0;

        if (ReadProcessMemory(
                process, imageNamePtr, &strPtr, sizeof(strPtr), &got) &&
            got == sizeof(strPtr) && strPtr)
        {
            char raw[MAX_PATH * 2] = {};

            if (ReadProcessMemory(
                    process, strPtr, raw, sizeof(raw) - 2, &got) && got)
            {
                if (unicode)
                {
                    const wchar_t* w =
                        reinterpret_cast<const wchar_t*>(raw);

                    return std::wstring(
                        w, wcsnlen(w, (sizeof(raw) / sizeof(wchar_t)) - 1));
                }

                return AnsiToWide(
                    std::string(raw, strnlen(raw, sizeof(raw) - 1)));
            }
        }
    }

    return {};
}

// ------------------------------------------------------------
// Address specification
//
//   0x004014b0              absolute runtime VA
//   rva:0x14b0              RVA of the main image
//   Eng3d.dll+0x5678        module + RVA, resolved when the module loads
// ------------------------------------------------------------

struct AddressSpec
{
    bool valid = false;
    bool isAbsolute = false;

    // An address may also be an argument expression, evaluated at call time:
    // `[Incubation.exe+0x1255e8]` is an import thunk's slot, `[[%esi]+0x10]`
    // a virtual method. Both are addresses only the running process knows.
    bool isExpr = false;
    std::wstring expr;

    std::wstring module;    // empty means "the main image"
    uint32_t rva = 0;
    Va absolute = 0;

    std::wstring text;
};

static Va NarrowVa(uint64_t v, const std::wstring& what)
{
    if (v > 0xFFFFFFFFull)
        Die(what + L" does not fit in a 32-bit address");

    return static_cast<Va>(v);
}

static AddressSpec ParseAddress(const std::wstring& s)
{
    AddressSpec a;
    a.valid = true;
    a.text = s;

    // An expression, not an address literal. Nothing in `rva:`, an absolute
    // number or `Module+RVA` can start with one of these.
    if (!s.empty() &&
        (s[0] == L'[' || s[0] == L'%' || s[0] == L'$' ||
         s[0] == L'&' || s[0] == L'('))
    {
        a.isExpr = true;
        a.expr = s;
        return a;
    }

    std::wstring ls = Lower(s);

    if (ls.rfind(L"rva:", 0) == 0)
    {
        a.isAbsolute = false;
        a.module.clear();
        a.rva = NarrowVa(ParseU64(s.substr(4)), L"RVA " + s);
        return a;
    }

    size_t plus = s.rfind(L'+');

    if (plus != std::wstring::npos && plus > 0)
    {
        a.isAbsolute = false;
        a.module = Trim(s.substr(0, plus));
        a.rva = NarrowVa(
            ParseU64(Trim(s.substr(plus + 1))),
            L"RVA in " + s);

        if (a.module.empty())
            Die(L"Empty module name in address: " + s);

        return a;
    }

    a.isAbsolute = true;
    a.absolute = NarrowVa(ParseU64(s), L"Address " + s);

    return a;
}

// Returns 0 while the owning module is not loaded yet.
static Va ResolveAddress(
    const AddressSpec& s,
    const ModuleTable& modules,
    Va mainImageBase)
{
    if (!s.valid)
        return 0;

    if (s.isAbsolute)
        return s.absolute;

    if (s.module.empty())
    {
        if (!mainImageBase)
            return 0;

        return static_cast<Va>(mainImageBase + s.rva);
    }

    bool ambiguous = false;
    Va base = modules.Find(s.module, ambiguous);

    if (ambiguous)
    {
        Die(
            L"Module name is ambiguous, two loaded modules share it: " +
            s.module);
    }

    if (!base)
        return 0;

    return static_cast<Va>(base + s.rva);
}

// ------------------------------------------------------------
// Remote memory and buffers
// ------------------------------------------------------------

struct Buffer
{
    Va addr = 0;
    uint32_t size = 0;
};

static Va RemoteAllocWrite(
    HANDLE process,
    const void* data,
    SIZE_T size,
    std::vector<LPVOID>& allocations,
    DWORD protect = PAGE_READWRITE)
{
    LPVOID p = VirtualAllocEx(
        process, nullptr, size ? size : 1,
        MEM_COMMIT | MEM_RESERVE, protect);

    if (!p)
        DieWin(L"VirtualAllocEx");

    allocations.push_back(p);

    if (data && size)
    {
        SIZE_T written = 0;

        if (!WriteProcessMemory(process, p, data, size, &written))
            DieWin(L"WriteProcessMemory(remote data)");

        if (written != size)
            Die(L"Short WriteProcessMemory");
    }

    return static_cast<Va>(reinterpret_cast<uintptr_t>(p));
}

static bool ReadRemote(
    HANDLE process,
    Va addr,
    void* out,
    SIZE_T size)
{
    SIZE_T got = 0;

    return
        ReadProcessMemory(
            process,
            reinterpret_cast<LPCVOID>(static_cast<uintptr_t>(addr)),
            out, size, &got) &&
        got == size;
}

// ------------------------------------------------------------
// Argument expressions
//
//   0x1234        literal
//   %esi          register value in the frozen breakpoint context
//   $name         result of an earlier call in this batch
//   &name         address of a declared buffer
//   [expr]        dword read from target memory, at call time
//   expr + expr   offset arithmetic
//
// Everything is evaluated on the debugger side, before the stub is emitted.
// The injected code stays as dumb as it was: it only ever sees final numbers.
// ------------------------------------------------------------

struct Env
{
    HANDLE process = nullptr;

    // So an expression can name a module, which is the only way to write the
    // address of an import thunk's slot: `[Incubation.exe+0x1255e8]`.
    const ModuleTable* modules = nullptr;
    Va mainImageBase = 0;

    CONTEXT frozen{};
    bool haveFrozen = false;

    std::map<std::wstring, uint32_t> bindings;
    std::map<std::wstring, Buffer> buffers;
};

struct EvalError
{
    std::wstring message;
};

static uint32_t RegisterValue(const CONTEXT& c, const std::wstring& name)
{
    std::wstring r = Lower(name);

    if (r == L"eax") return c.Eax;
    if (r == L"ebx") return c.Ebx;
    if (r == L"ecx") return c.Ecx;
    if (r == L"edx") return c.Edx;
    if (r == L"esi") return c.Esi;
    if (r == L"edi") return c.Edi;
    if (r == L"ebp") return c.Ebp;
    if (r == L"esp") return c.Esp;
    if (r == L"eip") return c.Eip;

    throw EvalError{
        L"Unknown register: %" + name +
        L" (eax,ebx,ecx,edx,esi,edi,ebp,esp,eip)"};
}

class ExprParser
{
public:
    ExprParser(const std::wstring& text, const Env& env)
        : s_(text), env_(env) {}

    uint32_t Parse()
    {
        uint32_t v = ParseSum();
        SkipSpace();

        if (i_ != s_.size())
            throw EvalError{L"Trailing text in expression: " + s_};

        return v;
    }

private:
    void SkipSpace()
    {
        while (i_ < s_.size() &&
               (s_[i_] == L' ' || s_[i_] == L'\t'))
        {
            ++i_;
        }
    }

    uint32_t ParseSum()
    {
        uint32_t acc = ParseTerm();

        for (;;)
        {
            SkipSpace();

            if (i_ < s_.size() && s_[i_] == L'+')
            {
                ++i_;
                acc += ParseTerm();
            }
            else if (i_ < s_.size() && s_[i_] == L'-')
            {
                ++i_;
                acc -= ParseTerm();
            }
            else
            {
                return acc;
            }
        }
    }

    std::wstring ParseIdent()
    {
        std::wstring out;

        while (i_ < s_.size() &&
               (std::iswalnum(s_[i_]) || s_[i_] == L'_'))
        {
            out.push_back(s_[i_++]);
        }

        if (out.empty())
            throw EvalError{L"Expected a name in expression: " + s_};

        return out;
    }

    uint32_t ParseTerm()
    {
        SkipSpace();

        if (i_ >= s_.size())
            throw EvalError{L"Unexpected end of expression: " + s_};

        wchar_t c = s_[i_];

        if (c == L'%')
        {
            ++i_;

            if (!env_.haveFrozen)
            {
                throw EvalError{
                    L"Register values are only available once the "
                    L"breakpoint has been hit"};
            }

            return RegisterValue(env_.frozen, ParseIdent());
        }

        if (c == L'$')
        {
            ++i_;
            std::wstring name = ParseIdent();

            auto it = env_.bindings.find(name);

            if (it == env_.bindings.end())
                throw EvalError{L"Undefined binding: $" + name};

            return it->second;
        }

        if (c == L'&')
        {
            ++i_;
            std::wstring name = ParseIdent();

            auto it = env_.buffers.find(name);

            if (it == env_.buffers.end())
                throw EvalError{L"Undefined buffer: &" + name};

            return it->second.addr;
        }

        if (c == L'[')
        {
            ++i_;
            uint32_t addr = ParseSum();

            SkipSpace();

            if (i_ >= s_.size() || s_[i_] != L']')
                throw EvalError{L"Missing ']' in expression: " + s_};

            ++i_;

            uint32_t value = 0;

            if (!ReadRemote(env_.process, addr, &value, sizeof(value)))
            {
                throw EvalError{
                    L"Cannot read target memory at " + Hex32(addr)};
            }

            return value;
        }

        if (c == L'(')
        {
            ++i_;
            uint32_t v = ParseSum();

            SkipSpace();

            if (i_ >= s_.size() || s_[i_] != L')')
                throw EvalError{L"Missing ')' in expression: " + s_};

            ++i_;
            return v;
        }

        // A module name, which stands for its runtime base address.
        if (std::iswalpha(c) || c == L'_')
        {
            std::wstring name;

            while (i_ < s_.size() &&
                   (std::iswalnum(s_[i_]) || s_[i_] == L'_' ||
                    s_[i_] == L'.' || s_[i_] == L'-'))
            {
                name.push_back(s_[i_++]);
            }

            if (!env_.modules)
                throw EvalError{L"No module table yet for: " + name};

            bool ambiguous = false;
            Va base = env_.modules->Find(name, ambiguous);

            if (ambiguous)
                throw EvalError{L"Module name is ambiguous: " + name};

            if (!base)
                throw EvalError{L"Module not loaded: " + name};

            return base;
        }

        // Numeric literal.
        size_t start = i_;

        if (c == L'-' || c == L'+')
            ++i_;

        while (i_ < s_.size() &&
               (std::iswalnum(s_[i_]) || s_[i_] == L'x' || s_[i_] == L'X'))
        {
            ++i_;
        }

        std::wstring lit = s_.substr(start, i_ - start);

        uint64_t u = 0;
        int64_t sv = 0;

        if (ParseU64Checked(lit, u))
            return static_cast<uint32_t>(u);

        if (ParseI64Checked(lit, sv))
            return static_cast<uint32_t>(static_cast<int32_t>(sv));

        throw EvalError{L"Cannot parse `" + lit + L"` in expression: " + s_};
    }

    const std::wstring& s_;
    const Env& env_;
    size_t i_ = 0;
};

static uint32_t EvalExpr(const std::wstring& text, const Env& env)
{
    ExprParser p(text, env);
    return p.Parse();
}

// Fills a pattern's holes in for one destination. `dest` is where the first
// byte is going to live, so a rel32 knows what it is relative to.
static std::vector<uint8_t> MaterializeBytes(
    const BytePattern& p,
    Va dest,
    const Env& env,
    const std::wstring& what)
{
    std::vector<uint8_t> out = p.bytes;

    for (const BytePattern::Fixup& f : p.fixups)
    {
        uint32_t v = 0;

        try
        {
            v = EvalExpr(f.expr, env);
        }
        catch (const EvalError& e)
        {
            Die(what + L": " + e.message);
        }

        if (f.rel32)
            v -= static_cast<uint32_t>(dest + f.offset + 4);

        for (int k = 0; k < 4; ++k)
            out[f.offset + k] = static_cast<uint8_t>((v >> (8 * k)) & 0xFF);
    }

    return out;
}

// ------------------------------------------------------------
// Arguments and call specifications
// ------------------------------------------------------------

struct ArgSpec
{
    Param type;

    // For 32-bit integral parameters this is an expression; for 64-bit and
    // floating point parameters it must be a literal, because an expression
    // evaluates to a single dword; for str/wstr it is the string itself.
    std::wstring text;
};

struct ReadSpec
{
    std::wstring expr;
    uint32_t length = 0;
    std::wstring label;
};

struct CallSpec
{
    std::wstring name;              // for reporting
    AddressSpec func;
    Signature sig;
    CallConv cc = CallConv::Cdecl;
    bool probe = false;

    std::vector<ArgSpec> args;

    std::wstring bind;              // --name: bind EAX to $bind
    std::vector<std::wstring> zeros; // buffers to clear before this call
    std::vector<std::wstring> dumps;
    std::vector<ReadSpec> reads;
};


// ------------------------------------------------------------
// Resolving arguments to raw bits
// ------------------------------------------------------------

struct ResolvedArg
{
    Param type;
    uint64_t bits = 0;
    std::vector<uint8_t> raw;   // for a by-value struct
    std::wstring shown;         // what to print in the report
};

// Strings are constant, so one remote copy per distinct string serves the
// whole batch instead of leaking an allocation per call.
struct StringCache
{
    std::map<std::wstring, Va> ansi;
    std::map<std::wstring, Va> utf16;
};

static Va InternString(
    HANDLE process,
    StringCache& cache,
    const std::wstring& text,
    bool wide,
    std::vector<LPVOID>& allocations)
{
    auto& table = wide ? cache.utf16 : cache.ansi;

    auto it = table.find(text);

    if (it != table.end())
        return it->second;

    Va addr = 0;

    if (wide)
    {
        std::vector<wchar_t> buf(text.begin(), text.end());
        buf.push_back(L'\0');

        addr = RemoteAllocWrite(
            process, buf.data(), buf.size() * sizeof(wchar_t), allocations);
    }
    else
    {
        std::string s = WideToAnsi(text);
        std::vector<char> buf(s.begin(), s.end());
        buf.push_back('\0');

        addr = RemoteAllocWrite(
            process, buf.data(), buf.size(), allocations);
    }

    table[text] = addr;
    return addr;
}

static std::vector<ResolvedArg> ResolveArgs(
    const CallSpec& call,
    Env& env,
    StringCache& cache,
    std::vector<LPVOID>& allocations)
{
    std::vector<ResolvedArg> out;

    for (size_t index = 0; index < call.args.size(); ++index)
    {
        const ArgSpec& a = call.args[index];

        ResolvedArg r;
        r.type = a.type;

        // 64-bit and floating point parameters take a literal, since an
        // expression yields a single dword. Say which parameter went wrong
        // rather than only what could not be parsed.
        if (SlotCount(a.type) == 2 || a.type.type == SlotType::F32)
        {
            bool ok = false;

            if (a.type.type == SlotType::I64)
            {
                int64_t v = 0;
                ok = ParseI64Checked(a.text, v);
            }
            else if (a.type.type == SlotType::U64)
            {
                uint64_t v = 0;
                ok = ParseU64Checked(a.text, v);
            }
            else
            {
                try {
                    size_t pos = 0;
                    (void)std::stod(a.text, &pos);
                    ok = pos == a.text.size();
                }
                catch (...) {
                    ok = false;
                }
            }

            if (!ok)
            {
                Die(
                    L"Argument " + std::to_wstring(index + 1) + L" of " +
                    call.name + L" is `" +
                    ParamName(a.type) +
                    L"` and needs a literal, got: " + a.text);
            }
        }

        switch (a.type.type)
        {
            case SlotType::Bytes:
            {
                // The bytes themselves, or `*SOURCE` to take them from the
                // target: a declared buffer by name, or any expression for
                // a struct that lives inside a live object.
                if (!a.text.empty() && a.text[0] == L'*')
                {
                    std::wstring source = Trim(a.text.substr(1));

                    Va from = 0;
                    uint32_t available = a.type.bytes;

                    auto it = env.buffers.find(source);

                    if (it != env.buffers.end())
                    {
                        from = it->second.addr;
                        available = it->second.size;
                    }
                    else
                    {
                        from = EvalExpr(source, env);
                    }

                    if (available < a.type.bytes)
                    {
                        Die(
                            L"Argument " + std::to_wstring(index + 1) +
                            L" of " + call.name + L" wants " +
                            std::to_wstring(a.type.bytes) +
                            L" bytes but buffer " + source + L" holds " +
                            std::to_wstring(available));
                    }

                    r.raw.resize(a.type.bytes);

                    if (!ReadRemote(
                            env.process, from, r.raw.data(), r.raw.size()))
                    {
                        throw EvalError{
                            L"Cannot read " +
                            std::to_wstring(a.type.bytes) +
                            L" bytes at " + Hex32(from)};
                    }
                }
                else
                {
                    r.raw = ParseHexBytes(a.text);
                }

                if (r.raw.size() != a.type.bytes)
                {
                    Die(
                        L"Argument " + std::to_wstring(index + 1) + L" of " +
                        call.name + L" is `" + ParamName(a.type) +
                        L"` but " + std::to_wstring(r.raw.size()) +
                        L" bytes were given");
                }

                r.shown = a.text;
                break;
            }

            case SlotType::Str:
            case SlotType::WStr:
            {
                r.bits = InternString(
                    env.process, cache, a.text,
                    a.type.type == SlotType::WStr, allocations);

                r.shown = a.text;
                break;
            }

            case SlotType::F32:
            {
                r.bits = FloatBits(
                    static_cast<float>(ParseF64(a.text)));

                r.shown = a.text;
                break;
            }

            case SlotType::F64:
            {
                r.bits = DoubleBits(ParseF64(a.text));
                r.shown = a.text;
                break;
            }

            case SlotType::I64:
            {
                r.bits = static_cast<uint64_t>(ParseI64(a.text));
                r.shown = a.text;
                break;
            }

            case SlotType::U64:
            {
                r.bits = ParseU64(a.text);
                r.shown = a.text;
                break;
            }

            default:
            {
                uint32_t v = EvalExpr(a.text, env);
                r.bits = v;

                // Show both the source expression and what it came out as,
                // otherwise a batch report cannot be read back later.
                if (a.text == std::to_wstring(v))
                    r.shown = a.text;
                else
                    r.shown = a.text + L"=" + Hex32(v);

                break;
            }
        }

        out.push_back(std::move(r));
    }

    return out;
}

// ------------------------------------------------------------
// Call layout
//
// cdecl / stdcall   every argument on the stack, left to right
// thiscall          arg0 is `this` in ECX, the rest on the stack
// fastcall          the first two dword-sized integral arguments, scanned
//                   left to right, take ECX and EDX; a 64-bit or floating
//                   argument is never eligible but does not consume a
//                   register either, so a later small one still takes it
// ------------------------------------------------------------

struct CallLayout
{
    bool hasEcx = false;
    uint32_t ecx = 0;

    bool hasEdx = false;
    uint32_t edx = 0;

    std::vector<uint32_t> stackSlots;
};

static void AppendSlots(
    std::vector<uint32_t>& out,
    const ResolvedArg& a)
{
    if (a.type.type == SlotType::Bytes)
    {
        // The struct's own bytes, zero-padded up to whole slots.
        std::vector<uint8_t> padded = a.raw;
        padded.resize(SlotCount(a.type) * 4, 0);

        for (size_t i = 0; i < padded.size(); i += 4)
        {
            uint32_t word = 0;
            std::memcpy(&word, padded.data() + i, sizeof(word));
            out.push_back(word);
        }
    }
    else if (SlotCount(a.type) == 2)
    {
        out.push_back(static_cast<uint32_t>(a.bits & 0xFFFFFFFFull));
        out.push_back(static_cast<uint32_t>(a.bits >> 32));
    }
    else
    {
        out.push_back(static_cast<uint32_t>(a.bits));
    }
}

static CallLayout BuildCallLayout(
    const std::vector<ResolvedArg>& args,
    CallConv cc)
{
    CallLayout layout;

    switch (cc)
    {
        case CallConv::Cdecl:
        case CallConv::Stdcall:
        {
            for (const auto& a : args)
                AppendSlots(layout.stackSlots, a);

            break;
        }

        case CallConv::Thiscall:
        {
            if (args.empty())
                Die(L"__thiscall requires an explicit `this` argument");

            if (!IsRegisterEligible(args[0].type))
                Die(L"__thiscall `this` must be a dword-sized value");

            layout.hasEcx = true;
            layout.ecx = static_cast<uint32_t>(args[0].bits);

            for (size_t i = 1; i < args.size(); ++i)
                AppendSlots(layout.stackSlots, args[i]);

            break;
        }

        case CallConv::Fastcall:
        {
            for (const auto& a : args)
            {
                if (IsRegisterEligible(a.type))
                {
                    if (!layout.hasEcx)
                    {
                        layout.hasEcx = true;
                        layout.ecx = static_cast<uint32_t>(a.bits);
                        continue;
                    }

                    if (!layout.hasEdx)
                    {
                        layout.hasEdx = true;
                        layout.edx = static_cast<uint32_t>(a.bits);
                        continue;
                    }
                }

                AppendSlots(layout.stackSlots, a);
            }

            break;
        }
    }

    return layout;
}

// ------------------------------------------------------------
// x86 stub emitter
// ------------------------------------------------------------

static void Emit8(std::vector<uint8_t>& c, uint8_t v)
{
    c.push_back(v);
}

static void Emit32(std::vector<uint8_t>& c, uint32_t v)
{
    for (int i = 0; i < 4; ++i)
        c.push_back(static_cast<uint8_t>((v >> (i * 8)) & 0xFF));
}

// mov eax, [disp32]   ->  A1 disp32
static void EmitLoadEaxAbs(std::vector<uint8_t>& c, Va addr)
{
    Emit8(c, 0xA1);
    Emit32(c, addr);
}

// mov ecx, [disp32]   ->  8B 0D disp32
static void EmitLoadEcxAbs(std::vector<uint8_t>& c, Va addr)
{
    Emit8(c, 0x8B);
    Emit8(c, 0x0D);
    Emit32(c, addr);
}

// mov edx, [disp32]   ->  8B 15 disp32
static void EmitLoadEdxAbs(std::vector<uint8_t>& c, Va addr)
{
    Emit8(c, 0x8B);
    Emit8(c, 0x15);
    Emit32(c, addr);
}

// mov [esp + disp32], eax   ->  89 84 24 disp32
static void EmitStoreEaxStackSlot(std::vector<uint8_t>& c, uint32_t disp)
{
    Emit8(c, 0x89);
    Emit8(c, 0x84);
    Emit8(c, 0x24);
    Emit32(c, disp);
}

// mov [disp32], esp   ->  89 25 disp32
static void EmitStoreEsp(std::vector<uint8_t>& c, Va addr)
{
    Emit8(c, 0x89);
    Emit8(c, 0x25);
    Emit32(c, addr);
}

// Layout must match what the stub writes; the ESP pair is what makes the
// declared signature checkable against the callee's actual cleanup.
struct RemoteResult
{
    uint32_t eax;
    uint32_t edx;
    uint64_t st0;
    uint32_t espBefore;
    uint32_t espAfter;
};

constexpr uint32_t kResultEax       = 0;
constexpr uint32_t kResultEdx       = 4;
constexpr uint32_t kResultSt0       = 8;
constexpr uint32_t kResultEspBefore = 16;
constexpr uint32_t kResultEspAfter  = 20;
constexpr uint32_t kResultSize      = 24;

// Offsets inside the data page. The stub reads its arguments from here, so
// the code itself depends only on the *shape* of a call, never on the values.
constexpr uint32_t kDataFunc  = 0x20;
constexpr uint32_t kDataEcx   = 0x24;
constexpr uint32_t kDataEdx   = 0x28;
constexpr uint32_t kDataSlots = 0x40;
constexpr uint32_t kDataMaxSlots = (0x1000 - kDataSlots) / 4;

// A call's shape: everything the emitted code depends on. Two calls that
// share a shape share their code, which is what lets the code page be
// append-only.
struct StubShape
{
    uint32_t stackSlots = 0;
    bool hasEcx = false;
    bool hasEdx = false;
    bool captureFloat = false;

    bool operator<(const StubShape& o) const
    {
        if (stackSlots != o.stackSlots) return stackSlots < o.stackSlots;
        if (hasEcx != o.hasEcx) return hasEcx < o.hasEcx;
        if (hasEdx != o.hasEdx) return hasEdx < o.hasEdx;
        return captureFloat < o.captureFloat;
    }
};

struct StubEntry
{
    Va entry = 0;
    Va completionBreakpoint = 0;
};

// The code page is written append-only and never rewritten.
//
// The obvious design -- one stub, rewritten with fresh immediates per call --
// is self-modifying code, and it silently breaks under an emulating Wine on
// arm64: the first version of the stub gets translated, and rewriting those
// same bytes reuses the stale translation, so every call in a batch runs with
// the first call's arguments. FlushInstructionCache does not help. Keeping
// each distinct shape at its own address sidesteps the problem entirely.
struct StubRegion
{
    Va codeBase = 0;
    Va dataBase = 0;

    uint32_t codeUsed = 0;
    uint32_t codeCapacity = 0;

    std::map<StubShape, StubEntry> shapes;
};

static StubRegion AllocateStubRegion(HANDLE process)
{
    // 4 code pages, then one data page.
    constexpr SIZE_T codeSize = 0x4000;
    constexpr SIZE_T totalSize = codeSize + 0x1000;

    LPVOID remote = VirtualAllocEx(
        process, nullptr, totalSize,
        MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);

    if (!remote)
        DieWin(L"VirtualAllocEx(stub)");

    StubRegion r;
    r.codeBase = static_cast<Va>(reinterpret_cast<uintptr_t>(remote));
    r.codeCapacity = static_cast<uint32_t>(codeSize);
    r.dataBase = r.codeBase + static_cast<Va>(codeSize);

    return r;
}

// Emits the code for one shape, or returns the copy already emitted.
static StubEntry GetOrEmitStub(
    HANDLE process,
    StubRegion& region,
    const StubShape& shape)
{
    auto it = region.shapes.find(shape);

    if (it != region.shapes.end())
        return it->second;

    Va entryVa = region.codeBase + region.codeUsed;
    Va data = region.dataBase;

    std::vector<uint8_t> c;

    // and esp, -16
    //
    // The 1997 MSVC target code has no alignment requirement of its own, but
    // aligning here keeps the frame predictable and matches what SSE-using
    // code expects: ESP is 16-byte aligned before the CALL, so the callee
    // sees ESP % 16 == 12.
    Emit8(c, 0x83);
    Emit8(c, 0xE4);
    Emit8(c, 0xF0);

    // Unlike x64 there is no shadow space: the first stack argument sits at
    // [esp+0].
    uint64_t reserve = static_cast<uint64_t>(shape.stackSlots) * 4;

    reserve = (reserve + 15) & ~uint64_t(15);

    if (reserve > 0x800)
        Die(L"Too many arguments for the stub frame");

    if (reserve)
    {
        // sub esp, imm32
        Emit8(c, 0x81);
        Emit8(c, 0xEC);
        Emit32(c, static_cast<uint32_t>(reserve));
    }

    // Stack arguments are copied from the data page through EAX, which is
    // free until the function address is loaded.
    for (uint32_t i = 0; i < shape.stackSlots; ++i)
    {
        EmitLoadEaxAbs(c, data + kDataSlots + i * 4);
        EmitStoreEaxStackSlot(c, i * 4);
    }

    if (shape.hasEcx)
        EmitLoadEcxAbs(c, data + kDataEcx);

    if (shape.hasEdx)
        EmitLoadEdxAbs(c, data + kDataEdx);

    EmitLoadEaxAbs(c, data + kDataFunc);

    // ESP either side of the call. The difference is exactly the immediate
    // in the callee's `ret K`, i.e. how many argument bytes it popped.
    EmitStoreEsp(c, data + kResultEspBefore);

    // call eax
    Emit8(c, 0xFF);
    Emit8(c, 0xD0);

    EmitStoreEsp(c, data + kResultEspAfter);

    // mov [result+0], eax     A3 disp32
    Emit8(c, 0xA3);
    Emit32(c, data + kResultEax);

    // mov [result+4], edx     89 15 disp32
    Emit8(c, 0x89);
    Emit8(c, 0x15);
    Emit32(c, data + kResultEdx);

    // Both float and double come back in ST(0), and storing as a double is
    // lossless for either. Emitted only for float returns: popping ST(0)
    // after a function that never pushed one underflows the x87 stack.
    if (shape.captureFloat)
    {
        Emit8(c, 0xDD);
        Emit8(c, 0x1D);
        Emit32(c, data + kResultSt0);
    }

    Va completionAddress = static_cast<Va>(entryVa + c.size());

    Emit8(c, 0xCC);

    // If the debugger somehow continues without changing the context.
    Emit8(c, 0xEB);
    Emit8(c, 0xFE);

    if (region.codeUsed + c.size() > region.codeCapacity)
    {
        Die(
            L"Out of stub code space; too many distinct call shapes in one "
            L"run");
    }

    LPVOID stubPtr =
        reinterpret_cast<LPVOID>(static_cast<uintptr_t>(entryVa));

    SIZE_T written = 0;

    if (!WriteProcessMemory(
            process, stubPtr, c.data(), c.size(), &written))
    {
        DieWin(L"WriteProcessMemory(stub)");
    }

    if (written != c.size())
        Die(L"Short WriteProcessMemory(stub)");

    FlushInstructionCache(process, stubPtr, c.size());

    region.codeUsed += static_cast<uint32_t>(c.size());

    StubEntry e;
    e.entry = entryVa;
    e.completionBreakpoint = completionAddress;

    region.shapes[shape] = e;

    return e;
}

// Writes one call's arguments into the data page. This is the only thing that
// changes between calls, and it is data, never code.
static void WriteCallData(
    HANDLE process,
    const StubRegion& region,
    Va functionAddress,
    const CallLayout& layout)
{
    if (layout.stackSlots.size() > kDataMaxSlots)
        Die(L"Too many stack arguments for the data page");

    // Covers the result block too, so every call starts from a clean one.
    std::vector<uint8_t> page(
        kDataSlots + layout.stackSlots.size() * 4, 0);

    auto put = [&](uint32_t offset, uint32_t value)
    {
        std::memcpy(page.data() + offset, &value, sizeof(value));
    };

    put(kDataFunc, functionAddress);
    put(kDataEcx, layout.ecx);
    put(kDataEdx, layout.edx);

    for (size_t i = 0; i < layout.stackSlots.size(); ++i)
        put(kDataSlots + static_cast<uint32_t>(i) * 4, layout.stackSlots[i]);

    SIZE_T written = 0;

    if (!WriteProcessMemory(
            process,
            reinterpret_cast<LPVOID>(
                static_cast<uintptr_t>(region.dataBase)),
            page.data(), page.size(), &written) ||
        written != page.size())
    {
        DieWin(L"WriteProcessMemory(call data)");
    }
}

// ------------------------------------------------------------
// Breakpoint handling
// ------------------------------------------------------------

static bool InstallBreakpoint(HANDLE process, Va addr, BYTE& originalByte)
{
    LPVOID p = reinterpret_cast<LPVOID>(static_cast<uintptr_t>(addr));

    SIZE_T got = 0;

    if (!ReadProcessMemory(process, p, &originalByte, 1, &got) || got != 1)
        return false;

    DWORD oldProtect = 0;

    if (!VirtualProtectEx(
            process, p, 1, PAGE_EXECUTE_READWRITE, &oldProtect))
    {
        return false;
    }

    BYTE cc = 0xCC;
    SIZE_T written = 0;

    BOOL ok = WriteProcessMemory(process, p, &cc, 1, &written);

    FlushInstructionCache(process, p, 1);

    DWORD dummy = 0;
    VirtualProtectEx(process, p, 1, oldProtect, &dummy);

    return ok && written == 1;
}

static void RestoreBreakpointByte(
    HANDLE process, Va addr, BYTE originalByte)
{
    LPVOID p = reinterpret_cast<LPVOID>(static_cast<uintptr_t>(addr));

    DWORD oldProtect = 0;

    if (!VirtualProtectEx(
            process, p, 1, PAGE_EXECUTE_READWRITE, &oldProtect))
    {
        DieWin(L"VirtualProtectEx(restore breakpoint)");
    }

    SIZE_T written = 0;

    if (!WriteProcessMemory(process, p, &originalByte, 1, &written))
        DieWin(L"WriteProcessMemory(restore breakpoint)");

    FlushInstructionCache(process, p, 1);

    DWORD dummy = 0;
    VirtualProtectEx(process, p, 1, oldProtect, &dummy);
}

static bool IsCommittedAddress(HANDLE process, Va addr)
{
    MEMORY_BASIC_INFORMATION mbi{};

    SIZE_T n = VirtualQueryEx(
        process,
        reinterpret_cast<LPCVOID>(static_cast<uintptr_t>(addr)),
        &mbi, sizeof(mbi));

    return n == sizeof(mbi) && mbi.State == MEM_COMMIT;
}

// This harness is a 32-bit process, so on 64-bit Windows it runs under WOW64
// and can only debug other WOW64 processes. A target that is not under WOW64
// on such a system is a native x64 process.
static bool TargetIsX64(HANDLE process)
{
    BOOL selfWow64 = FALSE;

    if (!IsWow64Process(GetCurrentProcess(), &selfWow64) || !selfWow64)
        return false;

    BOOL targetWow64 = FALSE;

    if (!IsWow64Process(process, &targetWow64))
        return false;

    return !targetWow64;
}

// ------------------------------------------------------------
// Result reporting
// ------------------------------------------------------------

enum class OutputFormat
{
    Text,
    Jsonl
};

struct CallOutcome
{
    size_t index = 0;
    std::wstring name;
    std::wstring status = L"ok";     // ok | fault | timeout | sig-mismatch
    std::wstring detail;

    std::vector<std::wstring> argsShown;

    RemoteResult raw{};
    bool haveRaw = false;

    uint32_t espDelta = 0;
    bool tainted = false;

    std::wstring decoded;

    std::vector<std::pair<std::wstring, std::wstring>> dumps;
};

static std::wstring DecodeReturn(SlotType kind, const RemoteResult& r)
{
    uint64_t wide =
        (static_cast<uint64_t>(r.edx) << 32) |
        static_cast<uint64_t>(r.eax);

    std::wostringstream o;

    switch (kind)
    {
        case SlotType::Void: return L"<void>";
        case SlotType::Ptr:  return Hex32(r.eax);

        case SlotType::U32:
            o << r.eax;
            break;

        case SlotType::I32:
            o << static_cast<int32_t>(r.eax);
            break;

        case SlotType::U64:
            o << wide;
            break;

        case SlotType::I64:
            o << static_cast<int64_t>(wide);
            break;

        case SlotType::F32:
            o << static_cast<float>(BitsDouble(r.st0));
            break;

        case SlotType::F64:
            o << BitsDouble(r.st0);
            break;

        default:
            return Hex32(r.eax);
    }

    return o.str();
}

class Reporter
{
public:
    Reporter(OutputFormat format, const std::wstring& path)
        : format_(format)
    {
        if (!path.empty())
        {
            file_.open(path.c_str());

            if (!file_)
                Die(L"Cannot open output file: " + path);

            stream_ = &file_;
        }
        else
        {
            stream_ = &std::wcout;
        }
    }

    void Row(const CallOutcome& o, SlotType ret)
    {
        switch (format_)
        {
            case OutputFormat::Text: Text(o, ret); break;
            case OutputFormat::Jsonl: Jsonl(o, ret); break;
        }

        // Flushed per row on purpose: a batch that dies on call 37 must
        // still hand back the first 36 results.
        stream_->flush();
    }

    void Note(const std::wstring& s)
    {
        if (format_ == OutputFormat::Text)
        {
            *stream_ << s << L"\n";
            stream_->flush();
        }
        else
        {
            std::wcerr << s << L"\n";
        }
    }

private:
    void Text(const CallOutcome& o, SlotType ret)
    {
        std::wostringstream line;

        line << L"[" << o.index << L"] ";

        if (!o.name.empty())
            line << o.name;

        line << L"(";

        for (size_t i = 0; i < o.argsShown.size(); ++i)
        {
            if (i) line << L", ";
            line << o.argsShown[i];
        }

        line << L")";

        if (o.status == L"ok")
        {
            line << L" = " << o.decoded;

            if (o.haveRaw)
            {
                line << L"    [eax=" << Hex32(o.raw.eax);

                if (ret == SlotType::I64 || ret == SlotType::U64)
                    line << L" edx=" << Hex32(o.raw.edx);

                line << L" esp+" << o.espDelta << L"]";
            }
        }
        else
        {
            line << L"  !! " << o.status;

            if (!o.detail.empty())
                line << L": " << o.detail;
        }

        if (o.tainted)
            line << L"  (tainted)";

        *stream_ << line.str() << L"\n";

        // A successful row can still carry a note -- this is where --probe
        // reports what the observed stack cleanup implies.
        if (o.status == L"ok" && !o.detail.empty())
            *stream_ << L"      " << o.detail << L"\n";

        for (const auto& d : o.dumps)
            *stream_ << L"      " << d.first << L" = " << d.second << L"\n";
    }

    void Jsonl(const CallOutcome& o, SlotType ret)
    {
        std::wostringstream j;

        j << L"{\"i\":" << o.index;

        if (!o.name.empty())
            j << L",\"call\":\"" << JsonEscape(o.name) << L"\"";

        j << L",\"args\":[";

        for (size_t i = 0; i < o.argsShown.size(); ++i)
        {
            if (i) j << L",";
            j << L"\"" << JsonEscape(o.argsShown[i]) << L"\"";
        }

        j << L"]";

        if (o.haveRaw)
        {
            j << L",\"eax\":\"" << Hex32(o.raw.eax) << L"\""
              << L",\"edx\":\"" << Hex32(o.raw.edx) << L"\""
              << L",\"esp_delta\":" << o.espDelta;

            if (ReturnsFloat(ret))
                j << L",\"st0\":" << BitsDouble(o.raw.st0);

            if (ret != SlotType::Void)
                j << L",\"result\":\"" << JsonEscape(o.decoded) << L"\"";
        }

        j << L",\"status\":\"" << JsonEscape(o.status) << L"\"";

        if (!o.detail.empty())
            j << L",\"detail\":\"" << JsonEscape(o.detail) << L"\"";

        if (o.tainted)
            j << L",\"tainted\":true";

        if (!o.dumps.empty())
        {
            j << L",\"reads\":{";

            for (size_t i = 0; i < o.dumps.size(); ++i)
            {
                if (i) j << L",";

                j << L"\"" << JsonEscape(o.dumps[i].first) << L"\":\""
                  << JsonEscape(o.dumps[i].second) << L"\"";
            }

            j << L"}";
        }

        j << L"}";

        *stream_ << j.str() << L"\n";
    }


    OutputFormat format_;
    std::wofstream file_;
    std::wostream* stream_ = nullptr;
};

// ------------------------------------------------------------
// Command line model
// ------------------------------------------------------------

struct BufDecl
{
    std::wstring name;
    uint32_t size = 0;
    BytePattern pattern;

    // --code allocates executable, so a trampoline can be built at a fresh
    // address instead of in whatever tail padding happens to look free. That
    // is not a convenience: padding that reads as zero in the file can hold
    // live pointers once the image is loaded, and a page of our own cannot.
    bool exec = false;
};

// A patch written into the target at the breakpoint, and left there.
struct PokeDecl
{
    AddressSpec addr;
    std::vector<uint8_t> expected;
    BytePattern replacement;
    std::wstring text;
};

// ------------------------------------------------------------
// Patching the target
// ------------------------------------------------------------

// Writes one patch, checking what it replaces first.
//
// The expected bytes are not optional. A patch is only worth anything if the
// address still holds what the disassembly said it held, and this is the only
// place that can be checked -- against the loaded image, relocations and all.
//
// Nothing is undone at the end of the run: a patch is meant to outlive the
// debugger, because --resume is what makes it useful.
static void ApplyPoke(
    HANDLE process,
    const PokeDecl& p,
    Va addr,
    const Env& env,
    Reporter& reporter)
{
    LPVOID at = reinterpret_cast<LPVOID>(static_cast<uintptr_t>(addr));

    std::vector<uint8_t> was(p.expected.size());

    if (!ReadRemote(process, addr, was.data(), was.size()))
        DieWin(L"ReadProcessMemory(--poke " + p.text + L")");

    if (was != p.expected)
    {
        Die(
            L"--poke " + p.text + L": " + Hex32(addr) + L" holds " +
            HexBytes(was) + L", not the expected " + HexBytes(p.expected));
    }

    std::vector<uint8_t> now =
        MaterializeBytes(p.replacement, addr, env, L"--poke " + p.text);

    DWORD oldProtect = 0;

    if (!VirtualProtectEx(
            process, at, now.size(), PAGE_EXECUTE_READWRITE, &oldProtect))
    {
        DieWin(L"VirtualProtectEx(--poke " + p.text + L")");
    }

    SIZE_T written = 0;

    BOOL ok = WriteProcessMemory(process, at, now.data(), now.size(), &written);

    DWORD ignored = 0;
    VirtualProtectEx(process, at, now.size(), oldProtect, &ignored);

    if (!ok || written != now.size())
        DieWin(L"WriteProcessMemory(--poke " + p.text + L")");

    FlushInstructionCache(process, at, now.size());

    reporter.Note(
        L"[+] poke at " + env.modules->Describe(addr) + L": " +
        HexBytes(was) + L" -> " + HexBytes(now));
}

// A call as typed, before addresses, signatures and types are bound.
struct CallDraft
{
    std::vector<std::wstring> calls;     // --call, one invocation each
    std::vector<std::wstring> zeros;
    std::vector<std::wstring> dumps;
    std::vector<std::wstring> reads;
    bool probe = false;
    bool any = false;
};

struct Options
{
    std::wstring target;
    std::vector<std::wstring> targetArgs;

    // Several anchors may be given; the first one the target reaches wins.
    // Useful when it is not certain which path a configuration takes, or
    // whether a module gets loaded at all.
    std::vector<AddressSpec> bps;

    OutputFormat format = OutputFormat::Text;
    bool formatSet = false;
    std::wstring outPath;

    DWORD callTimeoutMs = 5000;

    bool continueOnFault = false;
    bool resume = false;
    bool verifySig = true;

    std::vector<BufDecl> bufs;
    std::vector<PokeDecl> pokes;
    std::map<std::wstring, Signature> decls;

    std::vector<CallDraft> drafts;
};


// Options that set the run up rather than belonging to one call: buffers,
// injected code and patches. Accepted on the command line and on a line of
// their own in a plan file, parsed here once for both. Returns how many
// tokens were consumed, or 0 when the token is not one of them.
static size_t ApplyGlobalOption(
    const std::vector<std::wstring>& t,
    size_t i,
    Options& o)
{
    const std::wstring& x = t[i];

    auto need = [&]() -> const std::wstring&
    {
        if (i + 1 >= t.size())
            Die(x + L" requires a value");

        return t[i + 1];
    };

    if (x == L"--buf" || x == L"--blob" || x == L"--code")
    {
        std::wstring v = need();
        size_t colon = v.find(L':');

        if (colon == std::wstring::npos)
        {
            Die(
                x + L" must be NAME:" +
                (x == L"--buf" ? L"SIZE" : L"HEXBYTES") + L", got: " + v);
        }

        BufDecl b;
        b.name = Trim(v.substr(0, colon));
        b.exec = (x == L"--code");

        if (b.name.empty())
            Die(L"Empty buffer name in: " + v);

        if (x == L"--buf")
        {
            b.size = static_cast<uint32_t>(ParseU64(Trim(v.substr(colon + 1))));

            if (!b.size || b.size > 0x100000)
                Die(L"--buf size must be between 1 and 1048576: " + v);
        }
        else
        {
            b.pattern = ParseBytePattern(Trim(v.substr(colon + 1)));

            if (b.pattern.bytes.empty())
                Die(x + L" needs at least one byte: " + v);

            b.size = static_cast<uint32_t>(b.pattern.bytes.size());
        }

        o.bufs.push_back(b);
        return 2;
    }

    if (x == L"--poke")
    {
        std::wstring v = need();
        size_t arrow = v.find(L"=>");

        if (arrow == std::wstring::npos)
            Die(L"--poke must be ADDR:EXPECTED=>NEW, got: " + v);

        std::wstring left = Trim(v.substr(0, arrow));

        // The last colon before `=>` is the separator, so `rva:0x1fb34` stays
        // one address rather than becoming an address and a nonsensical byte
        // string.
        size_t colon = left.rfind(L':');

        if (colon == std::wstring::npos)
            Die(L"--poke must be ADDR:EXPECTED=>NEW, got: " + v);

        PokeDecl q;
        q.text = v;
        q.addr = ParseAddress(Trim(left.substr(0, colon)));
        q.expected = ParseHexBytes(Trim(left.substr(colon + 1)));
        q.replacement = ParseBytePattern(Trim(v.substr(arrow + 2)));

        if (q.expected.empty())
            Die(L"--poke needs the bytes it expects to find: " + v);

        if (q.replacement.bytes.size() != q.expected.size())
        {
            Die(
                L"--poke must preserve length: " +
                std::to_wstring(q.expected.size()) + L" bytes expected, " +
                std::to_wstring(q.replacement.bytes.size()) +
                L" written: " + v);
        }

        o.pokes.push_back(q);
        return 2;
    }

    return 0;
}

// Options that attach to a call, and so are accepted both on the command
// line and after a call in a plan file. Returns how many tokens were
// consumed, or 0 when the token is not one of them.
static size_t ApplyCallOption(
    const std::vector<std::wstring>& t,
    size_t i,
    CallDraft& c)
{
    const std::wstring& x = t[i];

    auto need = [&](const wchar_t* what) -> const std::wstring&
    {
        if (i + 1 >= t.size())
            Die(std::wstring(what) + L" requires a value");

        return t[i + 1];
    };

    if (x == L"--zero")   { c.zeros.push_back(need(L"--zero"));   c.any = true; return 2; }
    if (x == L"--dump")   { c.dumps.push_back(need(L"--dump"));   c.any = true; return 2; }
    if (x == L"--read")   { c.reads.push_back(need(L"--read"));   c.any = true; return 2; }
    if (x == L"--probe")  { c.probe = true; c.any = true; return 1; }

    return 0;
}



// One invocation, as written: `[binding =] name(arg, arg, ...)`.
struct CallExpr
{
    std::wstring bind;
    std::wstring callee;
    std::vector<std::wstring> args;
};

// Splits on commas that are not inside brackets, parentheses or quotes, so
// an argument may itself be an expression like `[[%esi+8]+0x24]`.
static std::vector<std::wstring> SplitArgList(
    const std::wstring& body,
    const std::wstring& whole)
{
    std::vector<std::wstring> out;

    if (Trim(body).empty())
        return out;

    std::wstring cur;
    int depth = 0;
    bool quoted = false;

    for (wchar_t ch : body)
    {
        if (quoted)
        {
            if (ch == L'"')
                quoted = false;
            else
                cur.push_back(ch);

            continue;
        }

        switch (ch)
        {
            case L'"': quoted = true; break;
            case L'[': case L'(': ++depth; cur.push_back(ch); break;
            case L']': case L')': --depth; cur.push_back(ch); break;

            case L',':
                if (depth)
                {
                    cur.push_back(ch);
                }
                else
                {
                    out.push_back(Trim(cur));
                    cur.clear();
                }
                break;

            default:
                cur.push_back(ch);
        }
    }

    if (quoted)
        Die(L"Unterminated string in: " + whole);

    if (depth)
        Die(L"Unbalanced brackets in: " + whole);

    out.push_back(Trim(cur));

    for (const auto& a : out)
    {
        if (a.empty())
            Die(L"Empty argument in: " + whole);
    }

    return out;
}

static CallExpr ParseCallExpr(const std::wstring& src)
{
    CallExpr e;

    std::wstring s = Trim(src);

    size_t open = s.find(L'(');

    if (open == std::wstring::npos || s.back() != L')')
        Die(L"A call must be written as name(arg, ...), got: " + src);

    std::wstring head = Trim(s.substr(0, open));

    // A binding is `name = call(...)`; the `=` is before the parameter list,
    // which is exactly what distinguishes it from a declaration, where the
    // `=` introduces the address after the list.
    size_t eq = head.find(L'=');

    if (eq != std::wstring::npos)
    {
        e.bind = Trim(head.substr(0, eq));
        head = Trim(head.substr(eq + 1));

        if (e.bind.empty())
            Die(L"Empty binding name in: " + src);
    }

    e.callee = head;

    if (e.callee.empty())
        Die(L"No function name in: " + src);

    e.args = SplitArgList(s.substr(open + 1, s.size() - open - 2), src);

    return e;
}

// Builds one call from the declaration its name refers to.
static CallSpec FinalizeCall(
    const CallDraft& d,
    const std::wstring& name,
    const AddressSpec& func,
    const Signature& sig,
    const std::vector<std::wstring>& rawArgs,
    const std::wstring& bind)
{
    CallSpec c;

    c.name = name;
    c.func = func;
    c.sig = sig;

    bool haveSig = !c.sig.text.empty();

    c.cc = c.sig.haveCc ? c.sig.cc : CallConv::Cdecl;

    if (!haveSig)
        Die(L"A call needs a signature: " + c.name);

    if (rawArgs.size() != c.sig.params.size())
    {
        Die(
            L"`" + c.sig.text + L"` declares " +
            std::to_wstring(c.sig.params.size()) +
            L" parameter(s) but " + std::to_wstring(rawArgs.size()) +
            L" argument(s) were given");
    }

    for (size_t i = 0; i < rawArgs.size(); ++i)
    {
        ArgSpec a;
        a.type = c.sig.params[i];
        a.text = rawArgs[i];

        c.args.push_back(a);
    }

    if (c.cc == CallConv::Thiscall && c.sig.params.empty())
        Die(L"__thiscall requires an explicit `this` argument");

    c.probe = d.probe;

    if (c.probe && !c.sig.haveCc)
    {
        // With no convention stated, probe as cdecl: the caller-cleans
        // convention makes a wrong guess about arity harmless for our stub,
        // and the observed cleanup then reveals what the callee really is.
        //
        // When a convention *is* stated it is kept, so __thiscall and
        // __fastcall can be probed too -- they need a sensible ECX, which
        // only the caller can supply. Probing is safe under any convention
        // here, because nothing is ever resumed on that stack.
        c.cc = CallConv::Cdecl;
    }

    c.bind = bind;
    c.zeros = d.zeros;
    c.dumps = d.dumps;

    for (const std::wstring& r : d.reads)
    {
        size_t colon = r.rfind(L':');

        if (colon == std::wstring::npos)
            Die(L"--read must be EXPR:LENGTH, got: " + r);

        ReadSpec rs;
        rs.expr = Trim(r.substr(0, colon));
        rs.length = static_cast<uint32_t>(ParseU64(Trim(r.substr(colon + 1))));
        rs.label = rs.expr;

        if (!rs.length || rs.length > 4096)
            Die(L"--read length must be between 1 and 4096: " + r);

        c.reads.push_back(rs);
    }

    if (c.name.empty())
        c.name = c.func.text;

    return c;
}

// One draft becomes one call per --call.
//
// There is deliberately no sweep syntax. Ranges over more than one argument
// need a rule for whether they multiply or advance together, and another for
// unequal lengths -- a small language, inside the harness, duplicating what
// the Python side of this repository already does better and can express far
// more of: a grid filtered by what is actually passable in the .lev, say.
// Generate the calls and hand them over.
static void FinalizeDraft(
    const CallDraft& d,
    const std::map<std::wstring, Signature>& decls,
    std::vector<CallSpec>& out)
{
    if (d.calls.empty())
        Die(L"Nothing to call: every call is a --call naming a declaration");

    for (const std::wstring& text : d.calls)
    {
        CallExpr e = ParseCallExpr(text);

        auto it = decls.find(e.callee);

        if (it == decls.end())
            Die(L"No function declared with the name: " + e.callee);

        out.push_back(
            FinalizeCall(
                d, e.callee,
                ParseAddress(it->second.addressText),
                it->second, e.args, e.bind));
    }
}

// ------------------------------------------------------------
// Signature and plan files
// ------------------------------------------------------------

static std::vector<std::wstring> ReadLines(const std::wstring& path)
{
    std::ifstream f(std::string(WideToAnsi(path)));

    if (!f)
        Die(L"Cannot open file: " + path);

    std::vector<std::wstring> out;
    std::string line;

    while (std::getline(f, line))
        out.push_back(AnsiToWide(line));

    return out;
}

// Splits a plan line into its expression and any trailing per-call flags.
// Flags start at the first whitespace-separated token beginning with `--`
// that is outside brackets, parentheses and quotes.
static void SplitPlanLine(
    const std::wstring& line,
    std::wstring& expr,
    std::vector<std::wstring>& flags)
{
    int depth = 0;
    bool quoted = false;

    for (size_t i = 0; i < line.size(); ++i)
    {
        wchar_t c = line[i];

        if (quoted)
        {
            if (c == L'"')
                quoted = false;

            continue;
        }

        if (c == L'"')      { quoted = true; continue; }
        if (c == L'[' || c == L'(') { ++depth; continue; }
        if (c == L']' || c == L')') { --depth; continue; }

        if (depth == 0 &&
            i + 1 < line.size() &&
            line[i] == L'-' && line[i + 1] == L'-' &&
            (i == 0 || line[i - 1] == L' ' || line[i - 1] == L'\t'))
        {
            expr = Trim(line.substr(0, i));
            flags = SplitTokens(line.substr(i));
            return;
        }
    }

    expr = Trim(line);
    flags.clear();
}

// A declaration carries `= ADDRESS` after the parameter list; a call may
// carry `binding =` before it. That is the whole difference between the two
// forms that look like C.
static bool IsDeclaration(const std::wstring& expr)
{
    size_t close = expr.rfind(L')');

    if (close == std::wstring::npos)
        return false;

    return !Trim(expr.substr(close + 1)).empty();
}

// One file format for the lot. A line is one of three things, and none of
// them needs a keyword to say which:
//
//   * a setup option, spelled exactly as on the command line, because there
//     is no reason for the same thing to have two spellings;
//   * a declaration, which is the one with `= ADDRESS` after its parameters;
//   * a call, optionally with per-call options after it.
//
// Deliberately absent: anything that computes. No loops, no conditionals, no
// arithmetic over lines. A plan is a flat list, and whatever has to be worked
// out is worked out by the script that writes the plan.
static void LoadPlanFile(const std::wstring& path, Options& o)
{
    for (std::wstring raw : ReadLines(path))
    {
        std::wstring line = Trim(raw);

        if (line.empty() || line[0] == L'#')
            continue;

        std::wstring expr;
        std::vector<std::wstring> flags;

        SplitPlanLine(line, expr, flags);

        // A line that is nothing but options sets the run up.
        if (expr.empty())
        {
            for (size_t i = 0; i < flags.size();)
            {
                size_t used = ApplyGlobalOption(flags, i, o);

                if (!used)
                {
                    CallDraft ignored;

                    Die(
                        ApplyCallOption(flags, i, ignored)
                            ? flags[i] + L" belongs to a call, so it goes "
                              L"after one: " + line
                            : L"Unknown option in plan file: " + flags[i]);
                }

                i += used;
            }

            continue;
        }

        if (IsDeclaration(expr))
        {
            if (!flags.empty())
                Die(L"A declaration takes no options: " + line);

            Signature sig = ParseSignature(expr);

            if (sig.name.empty())
                Die(L"A declaration needs a function name: " + line);

            if (sig.addressText.empty())
                Die(L"A declaration needs `= ADDRESS`: " + line);

            if (o.decls.count(sig.name))
                Die(L"Duplicate declaration of: " + sig.name);

            o.decls[sig.name] = sig;
            continue;
        }

        CallDraft d;
        d.calls.push_back(expr);
        d.any = true;

        for (size_t i = 0; i < flags.size();)
        {
            size_t used = ApplyCallOption(flags, i, d);

            if (!used)
            {
                Die(
                    ApplyGlobalOption(flags, i, o)
                        ? flags[i] + L" sets the whole run up, so it goes on "
                          L"a line of its own: " + line
                        : L"Unknown option in plan file: " + flags[i]);
            }

            i += used;
        }

        o.drafts.push_back(d);
    }
}

// ------------------------------------------------------------
// Usage
// ------------------------------------------------------------

static void Usage()
{
    std::wcout <<
LR"USAGE(dbgcall - x86 (32-bit) Windows

Runs a 32-bit target under a debugger, waits for a breakpoint, then calls
functions inside the live process and prints what they returned.

  dbgcall.exe TARGET.exe --bp ADDRESS [call...] [options] [-- target args]

  Every call names a function declared with --sig. Both are repeatable, so
  one command line can declare several functions and call them in the order
  written:

  --sig "i32 add(i32,i32) = rva:0x14b0" ^
  --sig "__stdcall i32 sub(i32,i32) = rva:0x14fe" ^
  --call "x = add(1,2)" --call "sub($x,3)"

  --bp may be repeated: the first anchor the target reaches wins, and the
  rest are removed. Useful when it is not certain which path a build takes,
  or whether a module is loaded at all.

ADDRESSES

  0x004014b0              absolute runtime VA
  rva:0x14b0              RVA of the main image
  Eng3d.dll+0x5678        module + RVA, resolved when that module loads
  [Incubation.exe+0x1255e8]   an expression, for a function whose address
                              only the running process knows: an import
                              thunk's slot, or [[%esi]+0x10] for a virtual
                              method

  The third form is the only workable one for a DLL the loader relocates.
  Eng3d.dll asks for base 0x00400000, exactly where the EXE already is, so
  it moves on every run and a statically quoted address means nothing until
  the debugger has seen it load.

DECLARING AND CALLING

  A declaration is a C-like signature with a name and an address:

  --sig '__cdecl i32 aCheckLineOfSight(ptr,i32,i32) = Incubation.exe+0x46C460'

  and a call names it:

  --call 'aCheckLineOfSight(%esi, 12, 7)'
  --call 'hp = aGetUnitHitPoints(%esi)'

  A binding before the parameter list makes the result available as $hp to
  later calls. Repeat --call for a batch.

  Types: i32 u32 ptr i64 u64 f32 f64 str wstr void bytesN

  `this` under __thiscall is an explicit first parameter.

  bytesN is a struct passed by value: on x86 that is just its N bytes on
  the stack, rounded up to whole slots. Give the bytes as hex, or *SOURCE to
  take them from the target -- a buffer by name, or any expression:

  --sig "i32 dot(bytes12,bytes12) = rva:0x1234"
  --call "dot(010000000200000003000000, *other)"
  --call "dot(*[%esi+0x40], *scratch)"

  A function that *returns* a struct needs no new syntax: MSVC passes a
  hidden pointer as an implicit first argument, so declare it as `ptr` and
  pass a --buf.

SIGNATURE VERIFICATION

  The stub records ESP either side of the call, so the difference is exactly
  the immediate in the callee's `ret K`. For __stdcall, __thiscall and
  __fastcall that must equal the declared argument bytes -- which makes a
  wrong arity an error instead of a confident wrong number. Under __cdecl it
  must be zero, which catches a function that is really __stdcall.

  --no-verify-sig       report the mismatch but keep going
  --probe               report the observed cleanup instead of checking it,
                        to work out an unknown convention and arity. With no
                        convention stated the call is made as __cdecl; state
                        one to probe __thiscall or __fastcall, which need a
                        sensible ECX only you can supply.

ARGUMENT EXPRESSIONS

  Integral and pointer arguments are expressions, evaluated by the debugger
  before the call:

  0x1234                literal
  Eng3d.dll             a loaded module's base address
  %esi                  register in the frozen breakpoint context
  $name                 EAX of an earlier call in this batch
  &name                 address of a --buf or --blob buffer
  [expr]                dword read from target memory at call time
  expr+0x10             offset arithmetic

  i64, u64, f32, f64 and string arguments must be literals: an expression
  yields a single dword.

  --buf NAME:SIZE       zeroed buffer, allocated once for the whole run
  --blob NAME:HEX       buffer holding these bytes, written once
  --code NAME:HEX       the same, on an executable page: injected code
  --zero NAME           clear that buffer before this call
  --dump NAME           dump that buffer after this call
  --read EXPR:LENGTH    read LENGTH bytes at EXPR after this call

  Buffers keep whatever a call left in them, so one call can fill a buffer
  and the next can read it. Add --zero when you need to tell "the function
  wrote nothing" from "it wrote the same bytes again".

PATCHING

  --poke ADDR:EXPECTED=>NEW

  writes NEW over the EXPECTED bytes at ADDR, once, at the breakpoint. The
  two must be the same length, and the write is refused if the target does
  not actually hold EXPECTED -- against the loaded image, relocations and
  all, which is the only place that can be checked.

  Patches are applied in the order written, after every buffer exists and
  before any call, and are never undone: with --resume the target runs on
  with them in place. So a hook can be installed on the original executable
  at runtime instead of by shipping a patched copy of it.

  Both --code and --poke take hex with holes in it:

  {EXPR}                four bytes: the address EXPR evaluates to
  {rel32 EXPR}          four bytes: EXPR minus the end of the hole, which
                        is what a near jmp or call needs

  Holes are filled in when the bytes are written, so they can name a buffer
  that was allocated moments earlier. Installing a trampoline over a
  six-byte instruction pair and returning to the instruction after it:

  dbgcall.exe game.exe --bp rva:0xae890 --resume ^
      --buf trace:256 ^
      --code tramp:"8935{&trace}9c505156{...}9d8b56488b6e14e9{rel32 0x42073a}" ^
      --poke "0x00420734:8b56488b6e14=>e9{rel32 &tramp}90"

  That is a run with no --call in it at all, which is allowed: --poke on
  its own is a complete job.

BATCHES

  A plan file holds a whole run, one thing per line. A line is a setup
  option, a declaration -- the one with `= ADDRESS` after its parameters --
  or a call, and none of them needs a keyword to say which:

  --code alt:b840420f00c3
  --poke 0x004014b0:6944240 4e8=>e9{rel32 &alt}

  i32 add(i32,i32) = rva:0x14b0
  x = add(1, 2)
  add($x, 7) --dump out

  Setup options are spelled exactly as on the command line, and go on lines
  of their own; per-call options go after a call. Braces, brackets and quotes
  hold a value together, so a hole containing a space survives without the
  shell. Deliberately absent: loops, conditionals, arithmetic over lines. A
  plan is a flat list -- generate it from a script when it needs working out.

  There is no sweep or range syntax on purpose. Generate the lines with a
  script -- that handles irregular domains a range never could, and keeps
  one language out of the harness.

  --plan FILE           declarations and calls; repeatable
  --out text|jsonl      default: text for one call, jsonl for a batch
  -o FILE               write the report to a file
  --call-timeout MS     give up on a call that never returns (default 5000,
                        0 disables)
  --continue-on-fault   keep going after a call faults, marking every later
                        row tainted, since the target's state is suspect
  --resume              put the thread back where the breakpoint caught it
                        and detach, leaving the target running, instead of
                        killing it -- and leaving any --poke in place

EXAMPLES

  One call:

  dbgcall.exe game.exe --bp rva:0x1565 ^
      --sig "i32 add(i32,i32) = rva:0x14b0" --call "add(10, 20)"

  A method on the object the breakpoint has in ESI:

  dbgcall.exe game.exe --bp rva:0x1565 ^
      --sig "__thiscall f32 GetRange(ptr,i32) = Eng3d.dll+0x5678" ^
      --call "GetRange(%esi, 3)"

  Several calls, into JSONL for the Python side to check:

  dbgcall.exe game.exe --bp rva:0x1565 ^
      --sig "i32 los(ptr,i32,i32) = rva:0x46c460" ^
      --call "los([%esi+0x40], 0, 0)" --call "los([%esi+0x40], 1, 2)" ^
      --out jsonl -o los.jsonl

  For a whole grid, generate the plan file instead. It carries its own
  declaration, so the command line stays the same however many calls it
  holds:

  {
    echo "i32 los(ptr,i32,i32) = rva:0x46c460"
    python3 -c "print('\n'.join(f'los(%esi,{x},{y})' ^
        for x in range(40) for y in range(40)))"
  } > plan.txt
  dbgcall.exe game.exe --bp rva:0x1565 --plan plan.txt

  Work out an unknown function's convention:

  dbgcall.exe game.exe --bp rva:0x1565 --probe ^
      --sig "i32 unknown(i32,i32) = rva:0x14fe" --call "unknown(10, 3)"
)USAGE";
}

// ------------------------------------------------------------
// Main
// ------------------------------------------------------------

int wmain(int argc, wchar_t** argv)
{
    if (argc < 2)
    {
        Usage();
        return 1;
    }

    if (std::wstring(argv[1]) == L"--help" ||
        std::wstring(argv[1]) == L"-h")
    {
        Usage();
        return 0;
    }

    Options o;
    o.target = argv[1];

    CallDraft cli;

    std::vector<std::wstring> planFiles;

    std::vector<std::wstring> t;

    for (int i = 2; i < argc; ++i)
        t.emplace_back(argv[i]);

    for (size_t i = 0; i < t.size();)
    {
        const std::wstring& x = t[i];

        if (x == L"--")
        {
            for (++i; i < t.size(); ++i)
                o.targetArgs.push_back(t[i]);

            break;
        }

        if (x == L"--help" || x == L"-h")
        {
            Usage();
            return 0;
        }

        size_t used = ApplyCallOption(t, i, cli);

        if (!used)
            used = ApplyGlobalOption(t, i, o);

        if (used)
        {
            i += used;
            continue;
        }

        auto need = [&](const wchar_t* what) -> const std::wstring&
        {
            if (i + 1 >= t.size())
                Die(std::wstring(what) + L" requires a value");

            return t[i + 1];
        };

        if (x == L"--bp")
        {
            o.bps.push_back(ParseAddress(need(L"--bp")));
            i += 2;
        }
        else if (x == L"--sig")
        {
            // A declaration: name, parameters and address, all in one
            // string, going into the table a --call can reach.
            std::wstring text = need(L"--sig");
            Signature sig = ParseSignature(text);

            if (sig.name.empty())
                Die(L"A signature needs a function name: " + text);

            if (sig.addressText.empty())
            {
                Die(
                    L"A signature needs `= ADDRESS` so the declaration is "
                    L"self-contained: " + text);
            }

            if (o.decls.count(sig.name))
                Die(L"Duplicate declaration of: " + sig.name);

            o.decls[sig.name] = sig;
            i += 2;
        }
        else if (x == L"--call")
        {
            cli.calls.push_back(need(L"--call"));
            cli.any = true;
            i += 2;
        }
        else if (x == L"--plan")
        {
            planFiles.push_back(need(L"--plan"));
            i += 2;
        }
        else if (x == L"--out")
        {
            std::wstring v = Lower(need(L"--out"));

            if (v == L"text")       o.format = OutputFormat::Text;
            else if (v == L"jsonl") o.format = OutputFormat::Jsonl;
            else Die(L"Unknown output format: " + v);

            o.formatSet = true;
            i += 2;
        }
        else if (x == L"-o")
        {
            o.outPath = need(L"-o");
            i += 2;
        }
        else if (x == L"--call-timeout")
        {
            o.callTimeoutMs =
                static_cast<DWORD>(ParseU64(need(L"--call-timeout")));

            i += 2;
        }
        else if (x == L"--resume")
        {
            o.resume = true;
            ++i;
        }
        else if (x == L"--continue-on-fault")
        {
            o.continueOnFault = true;
            ++i;
        }
        else if (x == L"--no-verify-sig")
        {
            o.verifySig = false;
            ++i;
        }
        else
        {
            Die(L"Unknown option: " + x);
        }
    }

    if (o.bps.empty())
        Die(L"--bp is required");

    for (const auto& f : planFiles)
        LoadPlanFile(f, o);

    if (cli.any)
        o.drafts.push_back(cli);

    if (o.drafts.empty() && o.pokes.empty())
    {
        Die(
            L"Nothing to do: give --sig and --call, a --plan file, "
            L"or --poke");
    }

    // Bind addresses, signatures and types, then expand sweeps.
    std::vector<CallSpec> calls;

    for (const CallDraft& d : o.drafts)
        FinalizeDraft(d, o.decls, calls);

    if (!o.formatSet && calls.size() > 1)
        o.format = OutputFormat::Jsonl;

    Reporter reporter(o.format, o.outPath);

    // --------------------------------------------------------
    // Launch the target
    // --------------------------------------------------------

    std::wstring cmdLine = QuoteArg(o.target);

    for (const auto& a : o.targetArgs)
        cmdLine += L" " + QuoteArg(a);

    std::vector<wchar_t> cmdBuf(cmdLine.begin(), cmdLine.end());
    cmdBuf.push_back(L'\0');

    STARTUPINFOW si{};
    si.cb = sizeof(si);

    PROCESS_INFORMATION pi{};

    if (!CreateProcessW(
            o.target.c_str(), cmdBuf.data(), nullptr, nullptr, FALSE,
            DEBUG_ONLY_THIS_PROCESS | CREATE_UNICODE_ENVIRONMENT,
            nullptr, nullptr, &si, &pi))
    {
        DieWin(L"CreateProcessW");
    }

    reporter.Note(L"[+] pid = " + std::to_wstring(pi.dwProcessId));

    if (TargetIsX64(pi.hProcess))
    {
        TerminateProcess(pi.hProcess, 1);
        Die(L"This harness supports x86 targets only; the target is x64.");
    }

    DebugSetProcessKillOnExit(TRUE);

    // --------------------------------------------------------
    // Debugger state
    // --------------------------------------------------------

    ModuleTable modules;
    Va mainImageBase = 0;

    Env env;
    env.process = pi.hProcess;
    env.modules = &modules;

    struct Breakpoint
    {
        AddressSpec spec;
        Va addr = 0;
        BYTE original = 0;
        bool installed = false;
    };

    std::vector<Breakpoint> bps;

    for (const AddressSpec& a : o.bps)
    {
        Breakpoint b;
        b.spec = a;
        bps.push_back(b);
    }

    Va bpAddr = 0;

    bool initialBpSeen = false;
    bool started = false;
    bool detached = false;

    StubRegion region{};

    HANDLE callThread = nullptr;
    DWORD callTid = 0;

    size_t nextCall = 0;
    bool callRunning = false;
    Va completionBp = 0;

    CallOutcome current;
    bool tainted = false;
    bool abortBatch = false;

    std::vector<LPVOID> allocations;
    StringCache strCache;

    size_t okCount = 0;
    size_t badCount = 0;

    bool finished = false;

    // Plants every anchor whose address can be resolved yet. Called again on
    // each module load, so an anchor inside a DLL is planted the moment that
    // DLL appears.
    auto TryInstallBreakpoints = [&]()
    {
        if (started)
            return;

        for (Breakpoint& b : bps)
        {
            if (b.installed)
                continue;

            Va a = ResolveAddress(b.spec, modules, mainImageBase);

            if (!a)
                continue;

            BYTE original = 0;

            if (InstallBreakpoint(pi.hProcess, a, original))
            {
                b.addr = a;
                b.original = original;
                b.installed = true;

                reporter.Note(
                    L"[+] breakpoint at " + modules.Describe(a) +
                    L" (" + Hex32(a) + L")");
            }
        }
    };

    // Once one anchor fires the others are removed: nothing is ever resumed,
    // but a stray INT3 left in the image would confuse the exception
    // handling below.
    auto RemoveAllBreakpoints = [&]()
    {
        for (Breakpoint& b : bps)
        {
            if (!b.installed)
                continue;

            RestoreBreakpointByte(pi.hProcess, b.addr, b.original);
            b.installed = false;
        }
    };

    // How a run ends: kill the target, or -- with --resume -- put the thread
    // back exactly where the breakpoint caught it and detach, leaving the
    // game running.
    auto EndRun = [&](bool clean)
    {
        if (o.resume && clean && started && callThread)
        {
            CONTEXT back = env.frozen;
            back.ContextFlags = CONTEXT_FULL | CONTEXT_FLOATING_POINT;

            if (!SetThreadContext(callThread, &back))
            {
                std::wcerr
                    << L"[!] Cannot restore the thread context; the target "
                    << L"is being killed instead.\n";
            }
            else
            {
                // Must come before detaching, or the target dies with us.
                DebugSetProcessKillOnExit(FALSE);
                detached = true;

                reporter.Note(
                    L"[+] resuming the target at " +
                    modules.Describe(bpAddr) + L" and detaching");

                return;
            }
        }

        TerminateProcess(pi.hProcess, clean ? 0 : 1);
    };

    auto FinishRow = [&](CallOutcome& out, SlotType ret)
    {
        if (out.status == L"ok")
            ++okCount;
        else
            ++badCount;

        reporter.Row(out, ret);
    };

    // Prepares and launches the next call that can be launched. Calls that
    // cannot even be set up report a row and are skipped.
    auto StartNextCall = [&]() -> bool
    {
        while (nextCall < calls.size())
        {
            size_t idx = nextCall++;
            const CallSpec& c = calls[idx];

            CallOutcome out;
            out.index = idx;
            out.name = c.name;
            out.tainted = tainted;

            Va fn = 0;

            if (c.func.isExpr)
            {
                try
                {
                    fn = EvalExpr(c.func.expr, env);
                }
                catch (const EvalError& e)
                {
                    out.status = L"unresolved";
                    out.detail = e.message;
                    FinishRow(out, c.sig.ret);
                    continue;
                }
            }
            else
            {
                fn = ResolveAddress(c.func, modules, mainImageBase);
            }

            if (!fn)
            {
                out.status = L"unresolved";
                out.detail =
                    c.func.isExpr
                        ? c.func.expr + L" evaluated to zero"
                        : L"module not loaded: " +
                          (c.func.module.empty()
                               ? c.func.text
                               : c.func.module);

                FinishRow(out, c.sig.ret);
                continue;
            }

            if (!IsCommittedAddress(pi.hProcess, fn))
            {
                out.status = L"unmapped";
                out.detail = Hex32(fn) + L" is not committed memory";
                FinishRow(out, c.sig.ret);
                continue;
            }

            std::vector<ResolvedArg> args;

            try
            {
                args = ResolveArgs(c, env, strCache, allocations);
            }
            catch (const EvalError& e)
            {
                out.status = L"arg-error";
                out.detail = e.message;
                FinishRow(out, c.sig.ret);
                continue;
            }

            for (const auto& a : args)
                out.argsShown.push_back(a.shown);

            // Clearing a buffer is explicit per call, so that "the function
            // wrote nothing" stays distinguishable from "it wrote the same"
            // without silently wiping a buffer one call filled for the next.
            bool zeroFailed = false;

            for (const std::wstring& name : c.zeros)
            {
                auto bufIt = env.buffers.find(name);

                if (bufIt == env.buffers.end())
                {
                    out.status = L"arg-error";
                    out.detail = L"--zero names no such buffer: " + name;
                    zeroFailed = true;
                    break;
                }

                std::vector<uint8_t> zero(bufIt->second.size, 0);
                SIZE_T written = 0;

                WriteProcessMemory(
                    pi.hProcess,
                    reinterpret_cast<LPVOID>(
                        static_cast<uintptr_t>(bufIt->second.addr)),
                    zero.data(), zero.size(), &written);
            }

            if (zeroFailed)
            {
                FinishRow(out, c.sig.ret);
                continue;
            }

            CallLayout layout = BuildCallLayout(args, c.cc);

            StubShape shape;
            shape.stackSlots =
                static_cast<uint32_t>(layout.stackSlots.size());
            shape.hasEcx = layout.hasEcx;
            shape.hasEdx = layout.hasEdx;
            shape.captureFloat = ReturnsFloat(c.sig.ret);

            StubEntry stub = GetOrEmitStub(pi.hProcess, region, shape);

            WriteCallData(pi.hProcess, region, fn, layout);

            completionBp = stub.completionBreakpoint;

            CONTEXT ctx = env.frozen;
            ctx.ContextFlags = CONTEXT_FULL | CONTEXT_FLOATING_POINT;
            ctx.Eip = stub.entry;

            // Never carry a single-step flag into the injected stub.
            ctx.EFlags &= ~0x100u;

            if (!SetThreadContext(callThread, &ctx))
                DieWin(L"SetThreadContext(call stub)");

            current = out;
            callRunning = true;
            return true;
        }

        return false;
    };

    auto FinishCall = [&]()
    {
        const CallSpec& c = calls[current.index];

        RemoteResult r{};

        if (!ReadRemote(
                pi.hProcess, region.dataBase, &r, kResultSize))
        {
            DieWin(L"ReadProcessMemory(result)");
        }

        current.raw = r;
        current.haveRaw = true;
        current.espDelta = r.espAfter - r.espBefore;
        current.decoded = DecodeReturn(c.sig.ret, r);

        uint32_t expected =
            CalleeCleans(c.cc) ? StackArgBytes(c.sig, c.cc) : 0;

        if (c.probe)
        {
            std::wostringstream d;

            d << L"called as " << CallConvName(c.cc)
              << L", callee popped " << current.espDelta << L" bytes";

            if (current.espDelta % 4)
            {
                d << L", which is not a whole number of slots";
            }
            else if (!CalleeCleans(c.cc))
            {
                if (current.espDelta == 0)
                    d << L" -> caller-cleaned, consistent with __cdecl";
                else
                    d << L" -> really a callee-cleaning convention with "
                      << (current.espDelta / 4) << L" stack slot(s)";
            }
            else
            {
                d << L" -> " << (current.espDelta / 4)
                  << L" stack slot(s); the signature declares "
                  << (expected / 4);
            }

            current.detail = d.str();
        }
        else if (current.espDelta != expected)
        {
            current.status = L"sig-mismatch";

            std::wostringstream d;

            d << L"signature `" << c.sig.text << L"` under "
              << CallConvName(c.cc) << L" implies the callee pops "
              << expected << L" bytes, but it popped "
              << current.espDelta;

            if (!CalleeCleans(c.cc) && current.espDelta % 4 == 0)
            {
                d << L"; that looks like __stdcall with "
                  << (current.espDelta / 4) << L" dword slot(s)";
            }
            else if (CalleeCleans(c.cc) && current.espDelta % 4 == 0)
            {
                d << L"; that is " << (current.espDelta / 4)
                  << L" dword slot(s), not "
                  << (expected / 4);
            }

            current.detail = d.str();
        }

        if (!c.bind.empty())
            env.bindings[c.bind] = r.eax;

        for (const std::wstring& name : c.dumps)
        {
            auto it = env.buffers.find(name);

            if (it == env.buffers.end())
            {
                current.dumps.emplace_back(name, L"<no such buffer>");
                continue;
            }

            std::vector<uint8_t> data(it->second.size);

            if (ReadRemote(
                    pi.hProcess, it->second.addr,
                    data.data(), data.size()))
            {
                current.dumps.emplace_back(name, HexBytes(data));
            }
            else
            {
                current.dumps.emplace_back(name, L"<unreadable>");
            }
        }

        for (const ReadSpec& rs : c.reads)
        {
            try
            {
                uint32_t addr = EvalExpr(rs.expr, env);
                std::vector<uint8_t> data(rs.length);

                if (ReadRemote(
                        pi.hProcess, addr, data.data(), data.size()))
                {
                    current.dumps.emplace_back(rs.label, HexBytes(data));
                }
                else
                {
                    current.dumps.emplace_back(
                        rs.label, L"<unreadable at " + Hex32(addr) + L">");
                }
            }
            catch (const EvalError& e)
            {
                current.dumps.emplace_back(rs.label, L"<" + e.message + L">");
            }
        }

        FinishRow(current, c.sig.ret);

        if (current.status == L"sig-mismatch" && o.verifySig)
            abortBatch = true;
    };

    // --------------------------------------------------------
    // Debug loop
    // --------------------------------------------------------

    while (!finished)
    {
        DEBUG_EVENT ev{};

        DWORD waitMs =
            (callRunning && o.callTimeoutMs) ? o.callTimeoutMs : INFINITE;

        if (!WaitForDebugEvent(&ev, waitMs))
        {
            DWORD e = GetLastError();

            if (callRunning && e == ERROR_SEM_TIMEOUT)
            {
                const CallSpec& c = calls[current.index];

                current.status = L"timeout";
                current.detail =
                    L"no return after " +
                    std::to_wstring(o.callTimeoutMs) + L" ms";

                FinishRow(current, c.sig.ret);

                // The thread is stopped somewhere unknown, so there is no
                // safe way to keep going.
                TerminateProcess(pi.hProcess, 1);
                finished = true;
                break;
            }

            DieWin(L"WaitForDebugEvent");
        }

        DWORD continueStatus = DBG_CONTINUE;
        bool terminateAfterContinue = false;

        switch (ev.dwDebugEventCode)
        {
            case CREATE_PROCESS_DEBUG_EVENT:
            {
                mainImageBase = static_cast<Va>(
                    reinterpret_cast<uintptr_t>(
                        ev.u.CreateProcessInfo.lpBaseOfImage));

                ModuleInfo m;
                m.path = ResolveModuleName(
                    pi.hProcess,
                    ev.u.CreateProcessInfo.hFile,
                    ev.u.CreateProcessInfo.lpBaseOfImage,
                    ev.u.CreateProcessInfo.lpImageName,
                    ev.u.CreateProcessInfo.fUnicode);

                if (m.path.empty())
                    m.path = o.target;

                m.name = BaseName(m.path);
                m.base = mainImageBase;
                m.size = ReadImageSize(pi.hProcess, mainImageBase);

                modules.Add(m);

                reporter.Note(
                    L"[+] " + m.name + L" at " + Hex32(mainImageBase));

                TryInstallBreakpoints();

                if (ev.u.CreateProcessInfo.hFile)
                    CloseHandle(ev.u.CreateProcessInfo.hFile);

                break;
            }

            case LOAD_DLL_DEBUG_EVENT:
            {
                Va base = static_cast<Va>(
                    reinterpret_cast<uintptr_t>(ev.u.LoadDll.lpBaseOfDll));

                ModuleInfo m;
                m.path = ResolveModuleName(
                    pi.hProcess,
                    ev.u.LoadDll.hFile,
                    ev.u.LoadDll.lpBaseOfDll,
                    ev.u.LoadDll.lpImageName,
                    ev.u.LoadDll.fUnicode);

                m.name = m.path.empty()
                    ? L"<unnamed@" + Hex32(base) + L">"
                    : BaseName(m.path);

                m.base = base;
                m.size = ReadImageSize(pi.hProcess, base);

                modules.Add(m);

                // A breakpoint inside a dynamically loaded module can only
                // be planted once that module exists.
                TryInstallBreakpoints();

                if (ev.u.LoadDll.hFile)
                    CloseHandle(ev.u.LoadDll.hFile);

                break;
            }

            case UNLOAD_DLL_DEBUG_EVENT:
            {
                modules.RemoveByBase(
                    static_cast<Va>(
                        reinterpret_cast<uintptr_t>(
                            ev.u.UnloadDll.lpBaseOfDll)));

                break;
            }

            case EXIT_PROCESS_DEBUG_EVENT:
            {
                if (!started)
                {
                    std::wcerr
                        << L"[!] Target exited before any breakpoint was "
                        << L"hit:\n";

                    bool anyUnresolved = false;

                    for (const Breakpoint& b : bps)
                    {
                        // Plain ASCII on purpose: std::wcerr under the "C"
                        // locale cannot convert anything else, and it fails
                        // the stream silently, swallowing the rest of the
                        // diagnostic.
                        std::wcerr << L"      " << b.spec.text << L": ";

                        if (b.installed)
                        {
                            std::wcerr
                                << L"planted at " << Hex32(b.addr)
                                << L", never reached\n";
                        }
                        else
                        {
                            anyUnresolved = true;
                            std::wcerr << L"never resolved\n";
                        }
                    }

                    if (anyUnresolved)
                    {
                        std::wcerr << L"    Loaded modules were:\n";

                        for (const auto& m : modules.All())
                        {
                            std::wcerr
                                << L"      " << m.name
                                << L" at " << Hex32(m.base) << L"\n";
                        }
                    }
                }
                else if (nextCall < calls.size() || callRunning)
                {
                    std::wcerr
                        << L"[!] Target exited with "
                        << (calls.size() - nextCall + (callRunning ? 1 : 0))
                        << L" call(s) still pending.\n";
                }

                finished = true;
                break;
            }

            case EXCEPTION_DEBUG_EVENT:
            {
                const auto& ex = ev.u.Exception.ExceptionRecord;

                DWORD code = ex.ExceptionCode;

                Va exAddr = static_cast<Va>(
                    reinterpret_cast<uintptr_t>(ex.ExceptionAddress));

                // Completion INT3 from our own stub.
                if (callRunning &&
                    code == EXCEPTION_BREAKPOINT &&
                    exAddr == completionBp &&
                    ev.dwThreadId == callTid)
                {
                    FinishCall();
                    callRunning = false;

                    if (abortBatch || !StartNextCall())
                    {
                        EndRun(!abortBatch);
                        terminateAfterContinue = !detached;
                        finished = true;
                    }

                    continueStatus = DBG_CONTINUE;
                    break;
                }

                // Whichever anchor the target reached first.
                bool anchorHit =
                    !started && code == EXCEPTION_BREAKPOINT &&
                    std::any_of(
                        bps.begin(), bps.end(),
                        [&](const Breakpoint& b) {
                            return b.installed && b.addr == exAddr;
                        });

                if (anchorHit)
                {
                    started = true;
                    bpAddr = exAddr;

                    reporter.Note(
                        L"[+] breakpoint hit at " + modules.Describe(exAddr) +
                        L" on thread " + std::to_wstring(ev.dwThreadId));

                    RemoveAllBreakpoints();

                    callTid = ev.dwThreadId;

                    callThread = OpenThread(
                        THREAD_GET_CONTEXT | THREAD_SET_CONTEXT |
                            THREAD_QUERY_INFORMATION,
                        FALSE, callTid);

                    if (!callThread)
                        DieWin(L"OpenThread");

                    // The floating point state is part of the snapshot on
                    // purpose: it is restored before every call, so a batch
                    // cannot drift the x87 stack full over many float
                    // returns, and ESP cannot walk down the stack.
                    env.frozen = {};
                    env.frozen.ContextFlags =
                        CONTEXT_FULL | CONTEXT_FLOATING_POINT;

                    if (!GetThreadContext(callThread, &env.frozen))
                        DieWin(L"GetThreadContext");

                    // INT3 advanced EIP past the breakpoint byte.
                    env.frozen.Eip = bpAddr;
                    env.haveFrozen = true;
                    env.mainImageBase = mainImageBase;

                    region = AllocateStubRegion(pi.hProcess);

                    // Two passes: every buffer exists before any of them is
                    // filled in, so a pattern in one can name another with
                    // `&name` and a trampoline can be built out of them.
                    for (const BufDecl& b : o.bufs)
                    {
                        Buffer buf;
                        buf.size = b.size;
                        buf.addr = RemoteAllocWrite(
                            pi.hProcess, nullptr, b.size, allocations,
                            b.exec
                                ? PAGE_EXECUTE_READWRITE
                                : PAGE_READWRITE);

                        env.buffers[b.name] = buf;

                        // Reported because the address is the only way to
                        // reach a buffer from outside: a trace buffer that
                        // fills up after --resume is read by something else
                        // entirely, and it needs to be told where.
                        reporter.Note(
                            std::wstring(b.exec ? L"[+] code " : L"[+] buf ") +
                            b.name + L" at " + Hex32(buf.addr) + L", " +
                            std::to_wstring(b.size) + L" bytes");
                    }

                    for (const BufDecl& b : o.bufs)
                    {
                        if (b.pattern.bytes.empty())
                            continue;

                        const Buffer& buf = env.buffers[b.name];

                        std::vector<uint8_t> data = MaterializeBytes(
                            b.pattern, buf.addr, env, L"buffer " + b.name);

                        LPVOID at = reinterpret_cast<LPVOID>(
                            static_cast<uintptr_t>(buf.addr));

                        SIZE_T written = 0;

                        if (!WriteProcessMemory(
                                pi.hProcess, at,
                                data.data(), data.size(), &written) ||
                            written != data.size())
                        {
                            DieWin(
                                L"WriteProcessMemory(buffer " + b.name + L")");
                        }

                        if (b.exec)
                            FlushInstructionCache(pi.hProcess, at, data.size());
                    }

                    // Patches go in last, so `{&name}` in one can name a
                    // buffer that now has an address.
                    for (const PokeDecl& q : o.pokes)
                    {
                        Va at = 0;

                        if (q.addr.isExpr)
                        {
                            try
                            {
                                at = EvalExpr(q.addr.expr, env);
                            }
                            catch (const EvalError& e)
                            {
                                Die(L"--poke " + q.text + L": " + e.message);
                            }
                        }
                        else
                        {
                            at = ResolveAddress(
                                q.addr, modules, mainImageBase);
                        }

                        if (!at)
                        {
                            Die(
                                L"--poke " + q.text + L": `" + q.addr.text +
                                L"` does not resolve; is its module loaded "
                                L"at the breakpoint?");
                        }

                        ApplyPoke(pi.hProcess, q, at, env, reporter);
                    }

                    if (!StartNextCall())
                    {
                        EndRun(true);
                        terminateAfterContinue = !detached;
                        finished = true;
                    }

                    continueStatus = DBG_CONTINUE;
                    break;
                }

                // The loader's own initial breakpoint.
                if (code == EXCEPTION_BREAKPOINT && !initialBpSeen)
                {
                    initialBpSeen = true;
                    continueStatus = DBG_CONTINUE;
                    break;
                }

                // Anything else on the hijacked thread while a call is in
                // flight belongs to that call.
                if (callRunning && ev.dwThreadId == callTid)
                {
                    const CallSpec& c = calls[current.index];

                    current.status = L"fault";

                    std::wostringstream d;
                    d << L"exception 0x" << std::hex << code
                      << L" at " << modules.Describe(exAddr);

                    current.detail = d.str();

                    FinishRow(current, c.sig.ret);
                    callRunning = false;

                    if (o.continueOnFault)
                    {
                        // The target survived, but whatever the call was
                        // half-way through is anyone's guess, so every
                        // later row carries the doubt with it.
                        tainted = true;

                        if (!StartNextCall())
                        {
                            EndRun(true);
                            terminateAfterContinue = !detached;
                            finished = true;
                        }
                    }
                    else
                    {
                        // A faulted target is not worth resuming.
                        TerminateProcess(pi.hProcess, 1);
                        terminateAfterContinue = true;
                        finished = true;
                    }

                    continueStatus = DBG_CONTINUE;
                    break;
                }

                // Let the target's own handlers see everything else.
                continueStatus = DBG_EXCEPTION_NOT_HANDLED;
                break;
            }

            default:
                break;
        }

        if (!ContinueDebugEvent(
                ev.dwProcessId, ev.dwThreadId, continueStatus))
        {
            DieWin(L"ContinueDebugEvent");
        }

        if (detached)
        {
            if (!DebugActiveProcessStop(pi.dwProcessId))
                DieWin(L"DebugActiveProcessStop");

            break;
        }

        if (terminateAfterContinue)
            WaitForSingleObject(pi.hProcess, 3000);
    }

    if (calls.size() > 1 || badCount)
    {
        std::wcerr
            << L"[=] " << okCount << L" ok, " << badCount
            << L" failed, of " << calls.size() << L" call(s)\n";
    }

    if (callThread)
        CloseHandle(callThread);

    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);

    return badCount ? 2 : 0;
}
