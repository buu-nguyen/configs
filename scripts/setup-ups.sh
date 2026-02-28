#!/bin/sh
# ups.sh - configure a UPS machine as either a NUT netserver or netclient
# usage: ups.sh [server|client]

set -eu

echoerr() {
    printf "%s\n" "$*" >&2
}

usage() {
    echoerr "Usage: $0 server|client [--host HOST]"
    echoerr "  server mode always configures localhost (ignores --host)"
    echoerr "  client mode requires --host"
    exit 1
}

# parse arguments
MODE=""
SERVER_HOST=""
MON_ROLE=""   # master or slave

while [ $# -gt 0 ]; do
    case "$1" in
        server) MODE=netserver; shift ;; 
        client) MODE=netclient; shift ;;
        --host) SERVER_HOST="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[ -n "$MODE" ] || usage

# require necessary parameters
if [ "$MODE" = netclient ]; then
    [ -n "$SERVER_HOST" ] || { echoerr "--host is required for client mode"; exit 1; }
    MON_ROLE=slave
    UPS_USER=upsuser
    UPS_PASS=upsuser
elif [ "$MODE" = netserver ]; then
    SERVER_HOST=localhost
    MON_ROLE=master
    UPS_USER=upsadmin
    UPS_PASS=upsadmin
fi

# create a generic upsmon.conf file with parameters
write_upsmon_conf() {
    cat <<EOF > /etc/nut/upsmon.conf
RUN_AS_USER root
MONITOR ups@${SERVER_HOST} 1 ${UPS_USER} ${UPS_PASS} ${MON_ROLE}

MINSUPPLIES 1
SHUTDOWNCMD "/sbin/shutdown -h"
NOTIFYCMD /usr/sbin/upssched
POLLFREQ 2
POLLFREQALERT 1
HOSTSYNC 15
DEADTIME 15
MAXAGE 24
POWERDOWNFLAG /etc/killpower

NOTIFYMSG ONLINE "UPS %s on line power"
NOTIFYMSG ONBATT "UPS %s on battery"
NOTIFYMSG LOWBATT "UPS %s battary is low"
NOTIFYMSG FSD "UPS %s: forced shutdown in progress"
NOTIFYMSG COMMOK "Communications with UPS %s established"
NOTIFYMSG COMMBAD "Communications with UPS %s lost"
NOTIFYMSG SHUTDOWN "Auto logout and shutdown proceeding"
NOTIFYMSG REPLBATT "UPS %s battery needs to be replaced"
NOTIFYMSG NOCOMM "UPS %s is unavailable"
NOTIFYMSG NOPARENT "upsmon parent process died - shutdown impossible"

NOTIFYFLAG ONLINE   SYSLOG+WALL+EXEC
NOTIFYFLAG ONBATT   SYSLOG+WALL+EXEC
NOTIFYFLAG LOWBATT  SYSLOG+WALL+EXEC
NOTIFYFLAG FSD      SYSLOG+WALL+EXEC
NOTIFYFLAG COMMOK   SYSLOG+WALL+EXEC
NOTIFYFLAG COMMBAD  SYSLOG+WALL+EXEC
NOTIFYFLAG SHUTDOWN SYSLOG+WALL+EXEC
NOTIFYFLAG REPLBATT SYSLOG+WALL
NOTIFYFLAG NOCOMM   SYSLOG+WALL+EXEC
NOTIFYFLAG NOPARENT SYSLOG+WALL

RBWARNTIME 43200
NOCOMMWARNTIME 600

FINALDELAY 5
EOF
}

write_upssched_conf() {
    cat <<'EOFS' > /etc/nut/upssched.conf
CMDSCRIPT /etc/nut/upssched-cmd
PIPEFN /etc/nut/upssched.pipe
LOCKFN /etc/nut/upssched.lock

AT ONBATT * START-TIMER earlyshutdown 30
AT ONLINE * CANCEL-TIMER earlyshutdown online
AT LOWBATT * EXECUTE criticalshutdown
AT COMMBAD * START-TIMER upsgone 30
AT COMMOK * CANCEL-TIMER upsgone commok
AT NOCOMM * EXECUTE upsgone
AT SHUTDOWN * EXECUTE powerdown
EOFS
}

write_upssched_cmd() {
    cat <<'EOFS' > /etc/nut/upssched-cmd
#!/bin/sh
case \$1 in
      earlyshutdown)
         logger -t upssched-cmd "UPS on battery too long, early shutdown"
         /usr/sbin/upsmon -c fsd
         ;;
      criticalshutdown)
         logger -t upssched-cmd "UPS on battery critical, forced shutdown"
         /usr/sbin/upsmon -c fsd
         ;;
      upsgone)
         logger -t upssched-cmd "UPS has been gone too long, can't reach"
         ;;
      powerdown)
         logger -t upssched-cmd "Powering down"
         ;;
      *)
         logger -t upssched-cmd "Unrecognized command: \$1"
         ;;
esac
EOFS
    chmod +x /etc/nut/upssched-cmd
}

backup_files() {
    for path in "$@"; do
        [ -e "$path" ] && mv "$path" "$path.example" || true
    done
}

install_package() {
    case "$MODE" in
        netserver) apt install -y nut ;; 
        netclient) apt install -y nut-client ;; 
    esac
}

restart_services() {
    if [ "$MODE" = netserver ]; then
        service nut-server restart
        service nut-client restart
        systemctl restart nut-monitor
        upsdrvctl stop || true
        upsdrvctl start || true
    else
        service nut-client restart
        systemctl restart nut-monitor
    fi
}

# main execution

echo "setting up NUT as $MODE"
install_package

# backup common config files
if [ "$MODE" = netserver ]; then
    backup_files /etc/nut/nut.conf /etc/nut/upsd.conf /etc/nut/upsd.users \
                 /etc/nut/ups.conf /etc/nut/upsmon.conf /etc/nut/upssched.conf
elif [ "$MODE" = netclient ]; then
    backup_files /etc/nut/nut.conf /etc/nut/upsmon.conf /etc/nut/upssched.conf
fi

# write nut.conf
echo "MODE=$MODE" > /etc/nut/nut.conf

if [ "$MODE" = netserver ]; then
    # server specific
    cat <<'EOL' > /etc/nut/ups.conf
pollinterval = 15
maxretry = 3
offdelay = 180
ondelay = 300
EOL
    nut-scanner -U >> /etc/nut/ups.conf
    sed -i 's/\[.*\]/\[ups\]/g' /etc/nut/ups.conf
    upsdrvctl start

    cat <<'EOL' > /etc/nut/upsd.conf
LISTEN 0.0.0.0 3493
LISTEN :: 3493
EOL

    cat <<EOL > /etc/nut/upsd.users
[upsadmin]
# Administrative user
password = upsadmin
# Allow changing values of certain variables in the UPS.
actions = SET
# Allow setting the "Forced Shutdown" flag in the UPS.
actions = FSD
# Allow all instant commands
instcmds = ALL
upsmon $MON_ROLE

[upsuser]
# Normal user
password = upsuser
upsmon slave
EOL

else
    # client specific
    : # all client info provided via flags earlier
fi

# common pieces
write_upsmon_conf
write_upssched_conf
write_upssched_cmd

restart_services

echo "done. you can test with: upsc ups@${SERVER_HOST}"
