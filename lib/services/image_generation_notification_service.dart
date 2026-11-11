/// Platform-aware entry point for image generation notifications.
///
/// On Android/iOS the native implementation uses local notifications and a
/// background service. On the web those plugins are unavailable, so a no-op
/// stub is used instead. Keeping the import conditional prevents the web build
/// from loading plugins that never complete their initialization (which would
/// block the whole app before the first frame).
library;

export 'image_generation_notification_service_native.dart'
    if (dart.library.html) 'image_generation_notification_service_web.dart';
