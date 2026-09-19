#!/system/bin/sh

PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

MOD_VER=$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null | head -n 1)
ui_print "*******************************"
ui_print " Xiaomi 14 MiFi Web Control v${MOD_VER:-1.5.10}"
ui_print " HyperOS 3 / Android 16"
ui_print "*******************************"
ui_print "Default hotspot: Xiaomi14-MiFi"
ui_print "Default Wi-Fi password: 87654321"
ui_print "Web port: 8080"
ui_print "Fixed Web address: 192.168.43.1:8080"
ui_print "Web login: admin / admin"
ui_print "IMPORTANT: change the Web password after first login."

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm_recursive "$MODPATH/web/cgi-bin" 0 0 0755 0755
set_perm "$MODPATH/lib/common.sh" 0 0 0755
