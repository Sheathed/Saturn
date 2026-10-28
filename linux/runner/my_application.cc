#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#include <webkit2/webkit2.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"
#include <gio/gio.h>

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void webview_proxy_method_call_cb(FlMethodChannel* channel,
                                         FlMethodCall* call,
                                         gpointer user_data) {
  (void)channel;
  (void)user_data;
  if (g_strcmp0(fl_method_call_get_name(call), "configure") != 0) {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
    return;
  }
  FlValue* args = fl_method_call_get_args(call);
  FlValue* address_value = fl_value_lookup_string(args, "address");
  const gchar* address = address_value != nullptr &&
      fl_value_get_type(address_value) == FL_VALUE_TYPE_STRING
      ? fl_value_get_string(address_value) : nullptr;
  WebKitWebContext* context = webkit_web_context_get_default();
  if (address == nullptr || address[0] == '\0') {
    webkit_web_context_set_network_proxy_settings(
        context, WEBKIT_NETWORK_PROXY_MODE_DEFAULT, nullptr);
  } else {
    gchar* proxy_uri = g_strdup_printf("http://%s", address);
    const gchar* bypass[] = {"localhost", "127.0.0.1", "::1", nullptr};
    WebKitNetworkProxySettings* proxy =
        webkit_network_proxy_settings_new(proxy_uri, bypass);
    webkit_web_context_set_network_proxy_settings(
        context, WEBKIT_NETWORK_PROXY_MODE_CUSTOM, proxy);
    webkit_network_proxy_settings_free(proxy);
    g_free(proxy_uri);
  }
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  fl_method_call_respond(call, response, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView *view)
{
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

#ifndef WINDOW_TITLE
#define WINDOW_TITLE "Saturn"
#endif

#ifndef APP_ICON_ASSET
#define APP_ICON_ASSET "assets/icon.png"
#endif

// Resolve the icon path across bundle, debug intermediates, or source tree
static gchar* resolve_icon_path(const gchar* asset_rel_path) {
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", NULL);
  if (executable != NULL) {
    g_autofree gchar* executable_dir = g_path_get_dirname(executable);
    // 1. Check bundle data directory
    gchar* path1 = g_build_filename(executable_dir, "data", "flutter_assets", asset_rel_path, NULL);
    if (g_file_test(path1, G_FILE_TEST_EXISTS)) return path1;
    g_free(path1);

    // 2. Check bundle directory when running from intermediates_do_not_run
    gchar* path2 = g_build_filename(executable_dir, "..", "bundle", "data", "flutter_assets", asset_rel_path, NULL);
    if (g_file_test(path2, G_FILE_TEST_EXISTS)) return path2;
    g_free(path2);

    // 3. Check source tree relative to build output
    gchar* path3 = g_build_filename(executable_dir, "..", "..", "..", "..", asset_rel_path, NULL);
    if (g_file_test(path3, G_FILE_TEST_EXISTS)) return path3;
    g_free(path3);
  }

  // 4. Fallback relative to current working directory
  gchar* path4 = g_build_filename(".", asset_rel_path, NULL);
  if (g_file_test(path4, G_FILE_TEST_EXISTS)) return path4;
  g_free(path4);

  return g_strdup(asset_rel_path);
}

static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Let the desktop environment and window manager provide the native title bar.
  // GTK's custom header bar is substantially taller than KDE's normal title bar,
  // especially on Wayland.
  gtk_window_set_title(window, WINDOW_TITLE);

  // Set window and taskbar icons
  g_autofree gchar* linux_icon_path = resolve_icon_path(APP_ICON_ASSET);
  if (linux_icon_path != NULL && g_file_test(linux_icon_path, G_FILE_TEST_EXISTS)) {
    gtk_window_set_icon_from_file(window, linux_icon_path, NULL);
    gtk_window_set_default_icon_from_file(linux_icon_path, NULL);
  }

  // Register icon search paths for Wayland and desktop taskbars
  GtkIconTheme* icon_theme = gtk_icon_theme_get_default();
  g_autofree gchar* exe_link = g_file_read_link("/proc/self/exe", NULL);
  if (exe_link != NULL) {
    g_autofree gchar* exe_dir = g_path_get_dirname(exe_link);
    g_autofree gchar* share_icons = g_build_filename(exe_dir, "..", "share", "icons", NULL);
    if (g_file_test(share_icons, G_FILE_TEST_IS_DIR)) {
      gtk_icon_theme_append_search_path(icon_theme, share_icons);
    }
    g_autofree gchar* bundle_share = g_build_filename(exe_dir, "..", "bundle", "data", "flutter_assets", "assets", NULL);
    if (g_file_test(bundle_share, G_FILE_TEST_IS_DIR)) {
      gtk_icon_theme_append_search_path(icon_theme, bundle_share);
    }
    g_autofree gchar* data_assets = g_build_filename(exe_dir, "data", "flutter_assets", "assets", NULL);
    if (g_file_test(data_assets, G_FILE_TEST_IS_DIR)) {
      gtk_icon_theme_append_search_path(icon_theme, data_assets);
    }
  }

  gtk_window_set_default_icon_name(APPLICATION_ID);
  gtk_window_set_icon_name(window, APPLICATION_ID);
  gtk_window_set_default_size(window, 1280, 720);
  GdkGeometry minimum_window_size = {};
  minimum_window_size.min_width = 350;
  minimum_window_size.min_height = 500;
  gtk_window_set_geometry_hints(window, nullptr, &minimum_window_size,
                                GDK_HINT_MIN_SIZE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000 for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb), self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) proxy_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "s.s.saturn/webview_proxy", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      proxy_channel, webview_proxy_method_call_cb, nullptr, nullptr);
  g_object_set_data_full(G_OBJECT(view), "saturn-webview-proxy-channel",
                         g_steal_pointer(&proxy_channel),
                         reinterpret_cast<GDestroyNotify>(g_object_unref));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}
