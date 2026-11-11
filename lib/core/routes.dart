import 'package:get/get.dart';
import '../controllers/home_controller.dart';
import '../controllers/chat_controller.dart';
import '../controllers/task_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/settings_controller.dart';
import '../views/home_view.dart';
import '../views/chat_view.dart';
import '../views/task_view.dart';
import '../views/discord_callback_view.dart';

abstract class AppRoutes {
  static const home = '/';
  static const chat = '/chat';
  static const task = '/task';

  /// Endpoint callback OAuth Discord — didaftarkan di Discord Developer
  /// Portal → Redirects (https://piercingblow.ai.id/auth/discord).
  static const authDiscord = '/auth/discord';
}

class AppPages {
  static final pages = [
    GetPage(
      name: AppRoutes.home,
      page: () => const HomeView(),
      binding: BindingsBuilder(() {
        Get.lazyPut(() => HomeController());
        Get.lazyPut(() => ChatController());
        Get.lazyPut(() => TaskController());
        Get.lazyPut(() => ModelController());
        Get.lazyPut(() => SettingsController());
      }),
    ),
    GetPage(
      name: AppRoutes.authDiscord,
      page: () => const DiscordCallbackView(),
      transition: Transition.fadeIn,
    ),
    GetPage(
      name: AppRoutes.chat,
      page: () => const ChatView(),
      binding: BindingsBuilder(() {
        Get.lazyPut(() => ChatController());
      }),
    ),
    GetPage(
      name: AppRoutes.task,
      page: () => const TaskView(),
      binding: BindingsBuilder(() {
        Get.lazyPut(() => TaskController());
      }),
    ),
  ];
}