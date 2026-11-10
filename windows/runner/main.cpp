#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <delayimp.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// bizkhata.exe can't run on its own: it needs flutter_windows.dll, the plugin
// DLLs and the data folder next to it. Those DLLs are delay-loaded (see
// windows/CMakeLists.txt), so when files are missing, say because only the exe
// was copied out of the portable zip, we can tell people what to do instead of
// Windows stopping with "printing_plugin.dll was not found".
void ShowMissingFilesMessage(const std::wstring& file) {
  std::wstring text =
      L"BizKhata can't start because some of its files are missing (" + file +
      L").\n\n"
      L"bizkhata.exe can't run on its own: it needs the \"data\" folder and "
      L"the .dll files that come with it. To fix this:\n\n"
      L"\u2022 Install BizKhata with BizKhata-Setup.exe, or\n"
      L"\u2022 Extract the whole portable zip, then open bizkhata.exe inside "
      L"that folder.\n\n"
      L"For a desktop icon, make a shortcut instead of copying bizkhata.exe."
      L"\n\n";
  // The same in Bangla, escaped so the file compiles under any code page.
  text +=
      L"\u0995\u09BF\u099B\u09C1 \u09AB\u09BE\u0987\u09B2 \u09A8\u09BE "
      L"\u09A5\u09BE\u0995\u09BE\u09AF\u09BC BizKhata \u099A\u09BE\u09B2"
      L"\u09C1 \u09B9\u099A\u09CD\u099B\u09C7 \u09A8\u09BE\u0964\n"
      L"\u09B6\u09C1\u09A7\u09C1 bizkhata.exe \u09A6\u09BF\u09AF\u09BC"
      L"\u09C7 \u0985\u09CD\u09AF\u09BE\u09AA\u099F\u09BF \u099A\u09B2"
      L"\u09C7 \u09A8\u09BE\u0964 BizKhata-Setup.exe \u09A6\u09BF\u09AF"
      L"\u09BC\u09C7 \u0987\u09A8\u09B8\u09CD\u099F\u09B2 \u0995\u09B0"
      L"\u09C1\u09A8, \u0985\u09A5\u09AC\u09BE \u09AA\u09C1\u09B0\u09CB "
      L"zip \u09AB\u09BE\u0987\u09B2\u099F\u09BF extract \u0995\u09B0\u09C7 "
      L"\u09B8\u09C7\u0987 \u09AB\u09CB\u09B2\u09CD\u09A1\u09BE\u09B0"
      L"\u09C7\u09B0 \u09AD\u09C7\u09A4\u09B0\u09C7\u09B0 bizkhata.exe "
      L"\u099A\u09BE\u09B2\u09BE\u09A8\u0964\n"
      L"\u09A1\u09C7\u09B8\u09CD\u0995\u099F\u09AA\u09C7 \u0986\u0987"
      L"\u0995\u09A8 \u099A\u09BE\u0987\u09B2\u09C7 bizkhata.exe \u0995"
      L"\u09AA\u09BF \u09A8\u09BE \u0995\u09B0\u09C7 \u09B6\u09B0\u09CD"
      L"\u099F\u0995\u09BE\u099F \u09AC\u09BE\u09A8\u09BE\u09A8\u0964";
  ::MessageBoxW(nullptr, text.c_str(), L"BizKhata",
                MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
}

// The folder bizkhata.exe runs from, ending in a backslash, or "" if unknown.
std::wstring ExeFolder() {
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (length == 0) return L"";
    if (length < path.size()) {
      path.resize(length);
      break;
    }
    path.resize(path.size() * 2);
  }
  const size_t slash = path.find_last_of(L'\\');
  return slash == std::wstring::npos ? L"" : path.substr(0, slash + 1);
}

// The first file BizKhata needs that isn't next to the exe, or "" if none.
std::wstring FirstMissingFile() {
  const std::wstring folder = ExeFolder();
  if (folder.empty()) return L"";
  const wchar_t* const required[] = {
      L"flutter_windows.dll",
      L"data\\icudtl.dat",
      L"data\\flutter_assets",
#ifdef NDEBUG
      L"data\\app.so",
#endif
  };
  for (const wchar_t* name : required) {
    if (::GetFileAttributesW((folder + name).c_str()) ==
        INVALID_FILE_ATTRIBUTES) {
      return name;
    }
  }
  return L"";
}

// Called when a delay-loaded DLL can't be loaded after all (a plugin DLL, or a
// DLL it needs, is missing or from another version): explain and quit instead
// of crashing.
FARPROC WINAPI OnDelayLoadFailure(unsigned notification, PDelayLoadInfo info) {
  if (notification == static_cast<unsigned>(dliFailLoadLib) ||
      notification == static_cast<unsigned>(dliFailGetProc)) {
    std::wstring name;
    if (info != nullptr && info->szDll != nullptr) {
      for (const char* c = info->szDll; *c != '\0'; ++c) {
        name += static_cast<wchar_t>(static_cast<unsigned char>(*c));
      }
    }
    ShowMissingFilesMessage(name);
    // Not ExitProcess: the Flutter engine may be half started at this point.
    ::TerminateProcess(::GetCurrentProcess(), EXIT_FAILURE);
  }
  return nullptr;
}

}  // namespace

// Used by the delay-load helper from delayimp.lib.
ExternC const PfnDliHook __pfnDliFailureHook2 = OnDelayLoadFailure;

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Check before anything loads flutter_windows.dll or a plugin.
  const std::wstring missing = FirstMissingFile();
  if (!missing.empty()) {
    ShowMissingFilesMessage(missing);
    return EXIT_FAILURE;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 640);
  if (!window.Create(L"BizKhata", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
