# ===================================================================
# SKYLINK WIFI KITONGA (ABLINER) — COMPLETE SETUP SCRIPT FOR RB951
# Run this in MikroTik Winbox -> Terminal (Paste and press Enter)
# ===================================================================

/system identity set name="SKYLINK-WIFI-KITONGA"

# 1. WAN Connection on Ether 1
/interface ethernet set [find default-name=ether1] name="ether1-WAN"
:do {
    /ip dhcp-client add interface="ether1-WAN" add-default-route=yes use-peer-dns=yes disabled=no
} on-error={}

# 2. Create LAN Bridge for Ports 2-5 and Wi-Fi
:do {
    /interface bridge add name="MIKROBILL Main bridge"
} on-error={}

:do { /interface bridge port add bridge="MIKROBILL Main bridge" interface=ether2 } on-error={}
:do { /interface bridge port add bridge="MIKROBILL Main bridge" interface=ether3 } on-error={}
:do { /interface bridge port add bridge="MIKROBILL Main bridge" interface=ether4 } on-error={}
:do { /interface bridge port add bridge="MIKROBILL Main bridge" interface=ether5 } on-error={}
:do { /interface bridge port add bridge="MIKROBILL Main bridge" interface=wlan1 } on-error={}
:do { /interface wireless set [find default-name=wlan1] ssid="SKYLINK WIFI KITONGA" mode=ap-bridge default-forwarding=no disabled=no } on-error={}

# 3. IP Addressing (Hotspot Gateway 30.0.0.1 and Secondary IP 30.0.0.2)
:do { /ip address remove [find interface="MIKROBILL Main bridge"] } on-error={}
/ip address add address=30.0.0.1/24 interface="MIKROBILL Main bridge" network=30.0.0.0 comment="hotspot gateway"
/ip address add address=30.0.0.2/24 interface="MIKROBILL Main bridge" comment="Local API IP"

# 4. IP Pool & DHCP Server (Supports 30-200 concurrent users)
:do { /ip dhcp-server remove [find name="MIKROBILL Dhcp Server"] } on-error={}
:do { /ip pool remove [find name="MIKROBILL Hotspot Pool"] } on-error={}
/ip pool add name="MIKROBILL Hotspot Pool" ranges=30.0.0.10-30.0.0.200
/ip dhcp-server add name="MIKROBILL Dhcp Server" interface="MIKROBILL Main bridge" address-pool="MIKROBILL Hotspot Pool" lease-time=1h disabled=no
/ip dhcp-server network add address=30.0.0.0/24 gateway=30.0.0.1 dns-server=30.0.0.1 comment="hotspot network"

# 5. Hotspot Profile & Server
:do { /ip hotspot remove [find name="MIKROBILL Hotspot"] } on-error={}
:do { /ip hotspot profile remove [find name="MIKROBILL Hotspot Profile"] } on-error={}
/ip hotspot profile add name="MIKROBILL Hotspot Profile" hotspot-address=30.0.0.1 dns-name=mikrofig.com html-directory=hotspot login-by=http-chap,http-pap,cookie
/ip hotspot add name="MIKROBILL Hotspot" interface="MIKROBILL Main bridge" address-pool="MIKROBILL Hotspot Pool" profile="MIKROBILL Hotspot Profile" addresses-per-mac=1 disabled=no

# 5b. Auto-Expiration on First Login (Enforces Wall-Clock Validity per Package)
/ip hotspot user profile set [find default=yes] shared-users=2 on-login="{\
    :local u \$user;\
    :if ([:len [/system scheduler find name=\$u]] = 0) do={\
        :local exp [/ip hotspot user get [find name=\$u] limit-uptime];\
        :if ([:len \$exp] > 0) do={\
            /system scheduler add name=\$u start-date=[/system clock get date] start-time=[/system clock get time] interval=\$exp on-event=\"/ip hotspot active remove [find user=\\\"\$u\\\"]; /ip hotspot cookie remove [find user=\\\"\$u\\\"]; /ip hotspot user remove [find name=\\\"\$u\\\"]; /system scheduler remove [find name=\\\"\$u\\\"];\" policy=read,write,policy,test comment=\"Auto-expire for \$u\";\
            :local c [/ip hotspot user get [find name=\$u] comment];\
            /ip hotspot user set [find name=\$u] comment=\"\$c [Started: \$[/system clock get date] \$[/system clock get time]]\";\
        }\
    }\
}"

# 6. Firewall & NAT Rules
/ip firewall nat add chain=srcnat src-address=30.0.0.0/24 action=masquerade comment="Masquerade Hotspot LAN"
/ip firewall nat add chain=srcnat out-interface="ether1-WAN" action=masquerade comment="Masquerade WAN"

# Allow Web, Portal, REST API, DNS & ICMP (Ping required for Windows/Android Internet detection)
/ip firewall filter add chain=input in-interface="MIKROBILL Main bridge" protocol=tcp dst-port=80,443 action=accept comment="Allow Web, Portal and REST API access from hotspot LAN"
/ip firewall filter add chain=input in-interface="MIKROBILL Main bridge" protocol=udp dst-port=53 action=accept comment="Allow DNS queries from hotspot LAN"
/ip firewall filter add chain=input in-interface="MIKROBILL Main bridge" protocol=tcp dst-port=53 action=accept comment="Allow DNS TCP queries from hotspot LAN"
/ip firewall filter add chain=input in-interface="MIKROBILL Main bridge" protocol=icmp action=accept comment="Allow ICMP ping for internet detection"
/ip firewall filter add chain=forward in-interface="MIKROBILL Main bridge" src-address=30.0.0.0/24 dst-address=30.0.0.0/24 action=drop comment="Hotspot Client Isolation"

# 7. DNS & REST API Service
/ip dns set allow-remote-requests=yes servers=8.8.8.8,1.1.1.1
:do { /ip dns static remove [find name="mikrofig.com"] } on-error={}
:do { /ip dns static remove [find name="mikrofig.login"] } on-error={}
/ip dns static add name=mikrofig.com address=30.0.0.1
/ip dns static add name=mikrofig.login address=30.0.0.1

/ip service enable www
/ip service set www address=0.0.0.0/0 port=80

# 8. Create Billing REST API User
:do { /user remove [find name="mikrobill_billing"] } on-error={}
:do { /user remove [find name="skylink_wifikitonga"] } on-error={}
:do { /user group add name=mikrobill-api policy=read,write,policy,test,api,rest-api } on-error={}
/user add name=skylink_wifikitonga password="1961" group=mikrobill-api

# 9. Walled Garden (Allows Abliner Mobile Money & CDNs before Login)
/ip hotspot walled-garden
add dst-host=*.workers.dev comment="Cloudflare Workers Relay"
add dst-host=skylink-pay.skylinkwifisystem.workers.dev comment="SKYLINK Pay Relay"
add dst-host=abliner.net comment="Abliner API"
add dst-host=*.abliner.net
add dst-host=cdn.tailwindcss.com comment="Tailwind CSS CDN"
add dst-host=*.tailwindcss.com
add dst-host=cdnjs.cloudflare.com comment="Icons and CDN"
add dst-host=fonts.googleapis.com
add dst-host=fonts.gstatic.com

/ip hotspot walled-garden ip
add dst-address=30.0.0.1 action=accept comment="Router Hotspot Portal"
add dst-address=30.0.0.2 action=accept comment="Local API access before login"
add dst-host=*.workers.dev action=accept comment="Cloudflare Workers Relay HTTPS"
add dst-host=skylink-pay.skylinkwifisystem.workers.dev action=accept comment="SKYLINK Pay Relay HTTPS"
add dst-host=abliner.net action=accept comment="Abliner HTTPS API"
add dst-host=*.abliner.net action=accept
add dst-host=cdn.tailwindcss.com action=accept comment="Tailwind CSS CDN HTTPS"
add dst-host=*.tailwindcss.com action=accept
add dst-host=cdnjs.cloudflare.com action=accept comment="Icons and CDN HTTPS"
add dst-host=fonts.googleapis.com action=accept
add dst-host=fonts.gstatic.com action=accept

# 10. Clock & NTP Time Sync (Required for accurate expiration schedulers)
/system clock set time-zone-name="Africa/Dar_es_Salaam"
:do {
    /system ntp client set enabled=yes
    /system ntp client servers add address=pool.ntp.org
} on-error={}

# 11. Automatic Payment Sync (Cloudflare Worker -> MikroTik Hotspot Users)
:do { /system script remove [find name="sync_skylink"] } on-error={}
:do { /system scheduler remove [find name="sync_skylink_sched"] } on-error={}
/system script add name="sync_skylink" source="{\
  :do {\
    :local res [/tool fetch url=\"https://skylink-pay.skylinkwifisystem.workers.dev/mikrotik/sync\" check-certificate=no output=user as-value];\
    :if ((\$res->\"status\") = \"finished\") do={\
      :local cmd (\$res->\"data\");\
      :if ([:len \$cmd] > 10) do={\
        :execute script=\$cmd;\
      }\
    }\
  } on-error={}\
}"
/system scheduler add name="sync_skylink_sched" interval=2s on-event="sync_skylink" comment="Auto-sync paid hotspot users from Cloudflare Relay every 2s"

# 12. Real-Time Telemetry Push (MikroTik RouterOS v7 -> Cloudflare Relay)
:do { /system script remove [find name="push_telemetry"] } on-error={}
:do { /system scheduler remove [find name="push_telemetry_sched"] } on-error={}
/system script add name="push_telemetry" source="{\
  :do {\
    :local cpu [/system resource get cpu-load];\
    :local freeMem [/system resource get free-memory];\
    :local totMem [/system resource get total-memory];\
    :local up [/system resource get uptime];\
    :local ver [/system resource get version];\
    :local bName [/system resource get board-name];\
    :local rName [/system identity get name];\
    :local actCount [:len [/ip hotspot active find]];\
    :local usrCount [:len [/ip hotspot user find]];\
    :local actList \"\";\
    :local first true;\
    :foreach i in=[/ip hotspot active find] do={\
      :local u [/ip hotspot active get \$i user];\
      :local a [/ip hotspot active get \$i address];\
      :local m [/ip hotspot active get \$i mac-address];\
      :local ut [/ip hotspot active get \$i uptime];\
      :local bi [/ip hotspot active get \$i bytes-in];\
      :local bo [/ip hotspot active get \$i bytes-out];\
      :if (!\$first) do={ :set actList (\$actList . \",\"); };\
      :set first false;\
      :set actList (\$actList . \"{\\\"user\\\":\\\"\" . \$u . \"\\\",\\\"address\\\":\\\"\" . \$a . \"\\\",\\\"mac\\\":\\\"\" . \$m . \"\\\",\\\"uptime\\\":\\\"\" . \$ut . \"\\\",\\\"bytes_in\\\":\" . \$bi . \",\\\"bytes_out\\\":\" . \$bo . \"}\");\
    };\
    :local usrList \"\";\
    :local uFirst true;\
    :foreach i in=[/ip hotspot user find] do={\
      :local un [/ip hotspot user get \$i name];\
      :local lu [/ip hotspot user get \$i limit-uptime];\
      :local uut [/ip hotspot user get \$i uptime];\
      :local c [/ip hotspot user get \$i comment];\
      :local p [/ip hotspot user get \$i profile];\
      :if (!\$uFirst) do={ :set usrList (\$usrList . \",\"); };\
      :set uFirst false;\
      :set usrList (\$usrList . \"{\\\"name\\\":\\\"\" . \$un . \"\\\",\\\"limit_uptime\\\":\\\"\" . \$lu . \"\\\",\\\"uptime\\\":\\\"\" . \$uut . \"\\\",\\\"profile\\\":\\\"\" . \$p . \"\\\",\\\"comment\\\":\\\"\" . \$c . \"\\\"}\");\
    };\
    :local rxBytes 0;\
    :local txBytes 0;\
    :do { :set rxBytes [/interface get [find name=\"MIKROBILL Main bridge\"] rx-byte] } on-error={};\
    :do { :set txBytes [/interface get [find name=\"MIKROBILL Main bridge\"] tx-byte] } on-error={};\
    :local payload (\"{\\\"identity\\\":\\\"\" . \$rName . \"\\\",\\\"cpu\\\":\" . \$cpu . \",\\\"free_memory\\\":\" . \$freeMem . \",\\\"total_memory\\\":\" . \$totMem . \",\\\"uptime\\\":\\\"\" . \$up . \"\\\",\\\"version\\\":\\\"\" . \$ver . \"\\\",\\\"board\\\":\\\"\" . \$bName . \"\\\",\\\"active_users\\\":\" . \$actCount . \",\\\"total_users\\\":\" . \$usrCount . \",\\\"rx_bytes\\\":\" . \$rxBytes . \",\\\"tx_bytes\\\":\" . \$txBytes . \",\\\"active_list\\\":[\" . \$actList . \"],\\\"users_list\\\":[\" . \$usrList . \"]}\");\
    /tool fetch url=\"https://skylink-pay.skylinkwifisystem.workers.dev/telemetry\" http-method=post http-data=\$payload http-header-field=\"Content-Type: application/json\" check-certificate=no keep-result=no;\
  } on-error={}\
}"
/system scheduler add name="push_telemetry_sched" interval=15s on-event="push_telemetry" comment="Push live router telemetry to Cloudflare Relay every 15s"



:put "=========================================================="
:put "✓ SKYLINK WIFI KITONGA RB951 SETUP COMPLETED SUCCESSFULLY!"
:put "✓ Hotspot Gateway: 30.0.0.1 (mikrofig.com)"
:put "✓ Real-Time Telemetry Push: Active (Syncs every 15s to Cloudflare)"
:put "✓ Auto-Expiration Scheduler Enabled (Wall-clock validity)"
:put "✓ Auto-Payment Sync Active (Fetches paid users every 20s)"
:put "✓ SKYLINK Local REST API User: skylink_wifikitonga (Active)"
:put "✓ Upload the contents of 'router-files/hotspot/' into router Files"
:put "=========================================================="

