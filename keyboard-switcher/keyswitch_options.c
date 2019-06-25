// gcc `pkg-config --cflags glib-2.0` hello.c  `pkg-config --libs glib-2.0 gio-unix-2.0`
#include <glib.h>
#include <glib/gprintf.h>
#include <gio/gio.h>
#include <stdlib.h>

static gint layout_index = 0;

static GOptionEntry entries[] =
{
    {"layout", 'l', 0, G_OPTION_ARG_INT, &layout_index, "Which layout index to switch to, defaults to 0", NULL}
};

void sendMessage()
{
    GDBusConnection *conn;

    GError *error = NULL;

    conn = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (error)
    {
    	g_printf ("Failed to get bus access - %i : %s\n", error->code, error->message);
		g_error_free (error); error = NULL;
        //return EXIT_FAILURE;
    }

    GDBusMessage *message;

    message = g_dbus_message_new_method_call("org.gnome.Shell",
                                             "/org/gnome/Shell",
                                             "org.gnome.Shell",
                                             "Eval");

    GString *message_body = g_string_new(NULL);
    g_string_printf(message_body, "imports.ui.status.keyboard.getInputSourceManager().inputSources[%i].activate()", layout_index);
    //g_printf("%s\n",message_body->str);

    g_dbus_message_set_body (message, g_variant_new ("(s)", message_body->str));

    g_dbus_connection_send_message (conn,
                                    message,
                                    G_DBUS_SEND_MESSAGE_FLAGS_NONE,
                                    NULL,
                                    &error);
    g_object_unref (message);
}

int main(int argc, char *argv[])
{

    GError *error = NULL;
    GOptionContext *context;

    context = g_option_context_new ("- test tree model performance");
    g_option_context_add_main_entries (context, entries, NULL);
    if (!g_option_context_parse (context, &argc, &argv, &error))
    {
        g_print ("option parsing failed: %s\n", error->message);
        exit (1);
    }

    GDBusConnection *conn;

    conn = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (error)
    {
    	g_printf ("Failed to get bus access - %i : %s\n", error->code, error->message);
		g_error_free (error); error = NULL;
        return EXIT_FAILURE;
    }

    GDBusMessage *message;

    message = g_dbus_message_new_method_call("org.gnome.Shell",
                                             "/org/gnome/Shell",
                                             "org.gnome.Shell",
                                             "Eval");

    GString *message_body = g_string_new(NULL);
    g_string_printf(message_body, "imports.ui.status.keyboard.getInputSourceManager().inputSources[%i].activate()", layout_index);
    //g_printf("%s\n",message_body->str);

    g_dbus_message_set_body (message, g_variant_new ("(s)", message_body->str));

    g_dbus_connection_send_message (conn,
                                    message,
                                    G_DBUS_SEND_MESSAGE_FLAGS_NONE,
                                    NULL,
                                    &error);
    g_object_unref (message);

}
