#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Nur eine Selfify-Instanz: Zwei Fenster würden sich Einstellungen, Anmeldung
  // und Offline-Liste gegenseitig überschreiben. Läuft Selfify schon, wird das
  // vorhandene Fenster nach vorn geholt.
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, L"Local\\Selfify.SingleInstance");
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Selfify");
    if (running != nullptr) {
      if (::IsIconic(running)) {
        ::ShowWindow(running, SW_RESTORE);
      }
      ::SetForegroundWindow(running);
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Startgröße 1280x800 – auf kleinen Bildschirmen bzw. bei hoher Skalierung
  // (z. B. Laptop mit 150 %) so verkleinert, dass die Player-Leiste sichtbar
  // bleibt und nicht hinter der Taskleiste verschwindet.
  RECT work_area{};
  ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0);
  const POINT work_origin{work_area.left, work_area.top};
  const double scale_factor =
      FlutterDesktopGetDpiForMonitor(
          ::MonitorFromPoint(work_origin, MONITOR_DEFAULTTOPRIMARY)) /
      96.0;
  const int max_width =
      static_cast<int>((work_area.right - work_area.left) / scale_factor) - 40;
  const int max_height =
      static_cast<int>((work_area.bottom - work_area.top) / scale_factor) - 40;
  const int width = std::max(480, std::min(1280, max_width));
  const int height = std::max(560, std::min(800, max_height));

  FlutterWindow window(project);
  Win32Window::Point origin(20, 20);
  Win32Window::Size size(static_cast<unsigned int>(width),
                         static_cast<unsigned int>(height));
  if (!window.Create(L"Selfify", origin, size)) {
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
