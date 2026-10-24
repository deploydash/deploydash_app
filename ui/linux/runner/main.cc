#include "my_application.h"

#include <iostream>
#include <string>

#include "../../shared_native/process_security.h"

static gboolean should_suppress_known_gdk_warning(const gchar* log_domain,
                                                  const gchar* message) {
  if (g_strcmp0(log_domain, "Gdk") != 0 || message == nullptr) {
    return FALSE;
  }

  return g_strcmp0(message, "Unable to load  from the cursor theme") == 0 ||
         g_strcmp0(
             message,
             "gdk_device_get_source: assertion 'GDK_IS_DEVICE (device)' failed") ==
             0 ||
         g_strcmp0(message,
                   "gdk_device_get_position: assertion 'GDK_IS_DEVICE "
                   "(device)' failed") == 0;
}

static void gdk_log_filter(const gchar* log_domain,
                           GLogLevelFlags log_level,
                           const gchar* message,
                           gpointer user_data) {
  if (should_suppress_known_gdk_warning(log_domain, message)) {
    return;
  }

  g_log_default_handler(log_domain, log_level, message, user_data);
}

int main(int argc, char** argv) {
  std::string hardening_error;
  if (!deploydash::ApplyProcessHardening(&hardening_error)) {
    std::cerr << "Deploy Dash process hardening failed: " << hardening_error
              << std::endl;
    return 1;
  }

  // Flutter's current Linux stack can emit a few known false-positive GDK
  // warnings during cursor/device initialization. Filter only those exact
  // messages so real GTK/GDK errors still reach stderr.
  g_log_set_handler(
      "Gdk",
      static_cast<GLogLevelFlags>(G_LOG_LEVEL_MASK | G_LOG_FLAG_FATAL |
                                  G_LOG_FLAG_RECURSION),
      gdk_log_filter, nullptr);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
