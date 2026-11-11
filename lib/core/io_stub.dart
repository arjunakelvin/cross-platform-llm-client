// Stub for web platform where dart:io is unavailable.
class File {
  File(String path);
  bool existsSync() => false;
  File get parent => File('');
  String get path => '';
}

class Platform {
  static bool get isWindows => false;
  static Map<String, String> get environment => const {};
  static String get resolvedExecutable => '';
}

class Process {
  static Future<Process> start(String executable, List<String> arguments) async => Process();
  void kill() {}
  Stream<List<int>> get stdout => const Stream.empty();
  Stream<List<int>> get stderr => const Stream.empty();
  Future<int> get exitCode => Future.value(0);
}

void autoStartDesktopAI() {}