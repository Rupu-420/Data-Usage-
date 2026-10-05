#!/bin/sh

# ============================================================
# NetUsage Installer for OpenWrt
# vnStat + LuCI NetUsage
#
# Features:
# - Persistent vnStat database
# - WAN auto detection
# - Today usage
# - Latest 3 calendar months
# - Colourful LuCI UI
# - MB / GB / TB display
# - RPCD backend
# - Boot recovery
# ============================================================

set -e

log() {
    echo "[NetUsage] $1"
}

ok() {
    echo "[NetUsage] OK: $1"
}

err() {
    echo "[NetUsage] ERROR: $1" >&2
}

# ------------------------------------------------------------
# Package manager
# ------------------------------------------------------------

if command -v apk >/dev/null 2>&1; then
    PKG="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG="opkg"
else
    err "No supported package manager found"
    exit 1
fi

log "Installing vnStat..."

if [ "$PKG" = "apk" ]; then
    apk update >/dev/null 2>&1 || true
    apk add vnstat
else
    opkg update >/dev/null 2>&1 || true
    opkg install vnstat
fi

# ------------------------------------------------------------
# Detect WAN interface
# ------------------------------------------------------------

WAN_IFACE="$(ubus call network.interface.wan status 2>/dev/null \
    | jsonfilter -e '@.l3_device' 2>/dev/null || true)"

if [ -z "$WAN_IFACE" ]; then
    WAN_IFACE="$(ip route 2>/dev/null \
        | awk '/default/ {print $5; exit}')"
fi

if [ -z "$WAN_IFACE" ]; then
    WAN_IFACE="eth1"
fi

log "WAN interface: $WAN_IFACE"

# ------------------------------------------------------------
# Persistent vnStat database
# ------------------------------------------------------------

mkdir -p /etc/vnstat

if [ -f /etc/vnstat.conf ]; then

    if grep -q '^DatabaseDir' /etc/vnstat.conf; then
        sed -i 's|^DatabaseDir.*|DatabaseDir "/etc/vnstat"|' \
            /etc/vnstat.conf
    else
        echo 'DatabaseDir "/etc/vnstat"' >> /etc/vnstat.conf
    fi

else

    cat > /etc/vnstat.conf <<'EOF'
DatabaseDir "/etc/vnstat"
EOF

fi

# ------------------------------------------------------------
# Migrate old temporary database if present
# ------------------------------------------------------------

if [ -d /var/lib/vnstat ]; then

    log "Checking existing vnStat database..."

    for DB in /var/lib/vnstat/*; do
        [ -f "$DB" ] || continue

        cp -f "$DB" /etc/vnstat/ 2>/dev/null || true
    done

fi

# ------------------------------------------------------------
# Create vnStat database
# ------------------------------------------------------------

if ! vnstat --iflist 2>/dev/null | grep -qw "$WAN_IFACE"; then

    log "Creating vnStat database for $WAN_IFACE..."

    vnstat --create -i "$WAN_IFACE" 2>/dev/null || true

else

    log "vnStat database already exists for $WAN_IFACE"

fi

# ------------------------------------------------------------
# Enable vnStat
# ------------------------------------------------------------

/etc/init.d/vnstat enable
/etc/init.d/vnstat restart

sleep 2

# ------------------------------------------------------------
# NetUsage configuration
# ------------------------------------------------------------

mkdir -p /etc/config

cat > /etc/config/netusage <<EOF
config netusage 'main'
    option interface '$WAN_IFACE'
EOF

# ------------------------------------------------------------
# RPCD backend
# ------------------------------------------------------------

mkdir -p /usr/libexec/rpcd

cat > /usr/libexec/rpcd/netusage <<'EOF'
#!/bin/sh

IFACE="$(uci -q get netusage.main.interface)"

[ -z "$IFACE" ] && IFACE="eth1"

case "$1" in

    list)

        echo '{"read":{}}'

        ;;

    call)

        case "$2" in

            read)

                vnstat -i "$IFACE" --json 2>/dev/null

                ;;

            *)

                exit 1

                ;;

        esac

        ;;

    *)

        exit 1

        ;;

esac
EOF

chmod +x /usr/libexec/rpcd/netusage

# ------------------------------------------------------------
# RPCD ACL
# ------------------------------------------------------------

mkdir -p /usr/share/rpcd/acl.d

cat > /usr/share/rpcd/acl.d/luci-app-netusage.json <<'EOF'
{
    "luci-app-netusage": {
        "description": "NetUsage",
        "read": {
            "ubus": {
                "netusage": [
                    "read"
                ]
            },
            "uci": [
                "netusage"
            ]
        }
    }
}
EOF

# ------------------------------------------------------------
# LuCI menu
# ------------------------------------------------------------

mkdir -p /usr/share/luci/menu.d

cat > /usr/share/luci/menu.d/luci-app-netusage.json <<'EOF'
{
    "admin/status/netusage": {
        "title": "Data Usage",
        "order": 35,
        "action": {
            "type": "view",
            "path": "netusage"
        },
        "depends": {
            "acl": [
                "luci-app-netusage"
            ]
        }
    }
}
EOF

# ------------------------------------------------------------
# LuCI view
# ------------------------------------------------------------

mkdir -p /www/luci-static/resources/view

cat > /www/luci-static/resources/view/netusage.js <<'EOF'
'use strict';

'require view';
'require rpc';
'require ui';

var callNetUsage = rpc.declare({
    object: 'netusage',
    method: 'read',
    expect: {}
});

/*
 * vnStat 1.18 JSON reports traffic values in KiB.
 * Convert them to bytes before formatting.
 */
var VNSTAT_UNIT = 1024;

/* ============================================================
   FORMAT MB / GB / TB ONLY
   ============================================================ */

function formatBytes(bytes) {

    bytes = Number(bytes || 0);

    var MB = 1024 * 1024;
    var GB = 1024 * 1024 * 1024;
    var TB = 1024 * 1024 * 1024 * 1024;

    if (bytes >= TB)
        return (bytes / TB).toFixed(2) + ' TB';

    if (bytes >= GB)
        return (bytes / GB).toFixed(2) + ' GB';

    return (bytes / MB).toFixed(2) + ' MB';
}

/* ============================================================
   MONTH NAME
   ============================================================ */

function monthName(year, month) {

    var date = new Date(year, month - 1, 1);

    return date.toLocaleString('default', {
        month: 'long',
        year: 'numeric'
    });
}

/* ============================================================
   MONTH KEY
   ============================================================ */

function monthKey(year, month) {

    return year + '-' +
        String(month).padStart(2, '0');
}

/* ============================================================
   PREVIOUS MONTH
   ============================================================ */

function previousMonth(year, month, offset) {

    var date =
        new Date(
            year,
            month - 1 - offset,
            1
        );

    return {
        year: date.getFullYear(),
        month: date.getMonth() + 1
    };
}

/* ============================================================
   TODAY DATA
   ============================================================ */

function getTodayData(iface) {

    var rx = 0;
    var tx = 0;

    /*
     * vnStat days[0] = current calendar day.
     * This gives the complete usage recorded today.
     */

    if (
        iface &&
        iface.traffic &&
        Array.isArray(iface.traffic.days) &&
        iface.traffic.days.length > 0
    ) {

        var today =
            iface.traffic.days[0];

        rx =
            Number(today.rx || 0) *
            VNSTAT_UNIT;

        tx =
            Number(today.tx || 0) *
            VNSTAT_UNIT;

    }

    return {
        rx: rx,
        tx: tx
    };
}

/* ============================================================
   MONTHLY DATA
   ============================================================ */

function getMonthlyData(
    iface,
    currentYear,
    currentMonth
) {

    var vnstatMonths = [];

    if (
        iface &&
        iface.traffic &&
        Array.isArray(iface.traffic.month)
    ) {

        vnstatMonths =
            iface.traffic.month.map(function(m) {

                return {
                    year:
                        Number(
                            m.date.year
                        ),

                    month:
                        Number(
                            m.date.month
                        ),

                    rx:
                        Number(m.rx || 0) *
                        VNSTAT_UNIT,

                    tx:
                        Number(m.tx || 0) *
                        VNSTAT_UNIT
                };

            });

    }

    var months = [];

    /*
     * Exactly:
     * 1 = current month
     * 2 = previous month
     * 3 = previous previous month
     */

    for (var i = 0; i < 3; i++) {

        var target =
            previousMonth(
                currentYear,
                currentMonth,
                i
            );

        var found = null;

        vnstatMonths.forEach(
            function(m) {

                if (
                    m.year === target.year &&
                    m.month === target.month
                ) {

                    found = m;

                }

            }
        );

        /*
         * If the month has no data yet,
         * create it with zero usage.
         */

        if (!found) {

            found = {
                year: target.year,
                month: target.month,
                rx: 0,
                tx: 0
            };

        }

        months.push(found);

    }

    return months;
}

/* ============================================================
   TAB STYLE
   ============================================================ */

function tabStyle(
    color,
    background,
    active
) {

    return [
        'border:2px solid ' + color,
        'border-radius:10px',
        'padding:9px 16px',
        'cursor:pointer',
        'font-weight:600',
        'font-size:14px',
        'color:' +
            (active ? '#ffffff' : color),
        'background:' +
            (active ? color : background),
        'transition:all .2s ease'
    ].join(';');
}

/* ============================================================
   COLOURFUL USAGE CARDS
   ============================================================ */

function renderCards(rx, tx) {

    var total =
        Number(rx || 0) +
        Number(tx || 0);

    var html = '';

    html +=
        '<div style="' +
        'display:grid;' +
        'grid-template-columns:' +
        'repeat(3,minmax(0,1fr));' +
        'gap:14px;' +
        'margin-top:10px;' +
        '">';

    /* --------------------------------------------------------
       DOWNLOAD
       -------------------------------------------------------- */

    html +=
        '<div style="' +
        'border:2px solid #2196f3;' +
        'border-radius:12px;' +
        'padding:16px;' +
        'text-align:center;' +
        'background:rgba(33,150,243,0.15);' +
        '">';

    html +=
        '<div style="font-size:28px;">📥</div>';

    html +=
        '<div style="' +
        'font-weight:600;' +
        'margin:6px 0;' +
        'color:#42a5f5;' +
        '">Download</div>';

    html +=
        '<strong style="font-size:20px;">' +
        formatBytes(rx) +
        '</strong>';

    html += '</div>';

    /* --------------------------------------------------------
       UPLOAD
       -------------------------------------------------------- */

    html +=
        '<div style="' +
        'border:2px solid #4caf50;' +
        'border-radius:12px;' +
        'padding:16px;' +
        'text-align:center;' +
        'background:rgba(76,175,80,0.15);' +
        '">';

    html +=
        '<div style="font-size:28px;">📤</div>';

    html +=
        '<div style="' +
        'font-weight:600;' +
        'margin:6px 0;' +
        'color:#66bb6a;' +
        '">Upload</div>';

    html +=
        '<strong style="font-size:20px;">' +
        formatBytes(tx) +
        '</strong>';

    html += '</div>';

    /* --------------------------------------------------------
       TOTAL
       -------------------------------------------------------- */

    html +=
        '<div style="' +
        'border:2px solid #ff9800;' +
        'border-radius:12px;' +
        'padding:16px;' +
        'text-align:center;' +
        'background:rgba(255,152,0,0.15);' +
        '">';

    html +=
        '<div style="font-size:28px;">📊</div>';

    html +=
        '<div style="' +
        'font-weight:600;' +
        'margin:6px 0;' +
        'color:#ffa726;' +
        '">Total</div>';

    html +=
        '<strong style="font-size:20px;">' +
        formatBytes(total) +
        '</strong>';

    html += '</div>';

    html += '</div>';

    return html;
}

/* ============================================================
   MAIN RENDER
   ============================================================ */

function renderUsage(
    data,
    selectedKey
) {

    var now = new Date();

    var currentYear =
        now.getFullYear();

    var currentMonth =
        now.getMonth() + 1;

    var iface =
        data &&
        data.interfaces &&
        data.interfaces[0];

    var months =
        getMonthlyData(
            iface,
            currentYear,
            currentMonth
        );

    var today =
        getTodayData(iface);

    var html = '';

    html +=
        '<div class="cbi-section">';

    html +=
        '<h2>Data Usage</h2>';

    /* ========================================================
       TABS
       ======================================================== */

    html +=
        '<div style="' +
        'display:flex;' +
        'gap:8px;' +
        'flex-wrap:wrap;' +
        'margin-bottom:20px;' +
        '">';

    /*
     * TODAY TAB
     */

    var todayActive =
        selectedKey === 'today';

    html +=
        '<button ' +
        'data-month="today" ' +
        'style="' +
        tabStyle(
            '#ab47bc',
            'rgba(171,71,188,0.12)',
            todayActive
        ) +
        '">';

    html += '🕐 Today';

    html += '</button>';

    /*
     * MONTH TAB COLOURS
     */

    var tabColors = [

        {
            color: '#2196f3',
            bg: 'rgba(33,150,243,0.12)'
        },

        {
            color: '#4caf50',
            bg: 'rgba(76,175,80,0.12)'
        },

        {
            color: '#ff9800',
            bg: 'rgba(255,152,0,0.12)'
        }

    ];

    /*
     * MONTH TABS
     */

    months.forEach(
        function(m, index) {

            var year =
                Number(m.year);

            var month =
                Number(m.month);

            var key =
                monthKey(
                    year,
                    month
                );

            var active =
                key === selectedKey;

            html +=
                '<button ' +
                'data-month="' +
                key +
                '" ' +
                'style="' +
                tabStyle(
                    tabColors[index].color,
                    tabColors[index].bg,
                    active
                ) +
                '">';

            html +=
                monthName(
                    year,
                    month
                ) +
                ' #' +
                (index + 1);

            html += '</button>';

        }
    );

    html += '</div>';

    /* ========================================================
       TODAY VIEW
       ======================================================== */

    if (selectedKey === 'today') {

        html +=
            '<div style="' +
            'margin-bottom:12px;' +
            'font-size:16px;' +
            'font-weight:600;' +
            '">';

        html +=
            '🕐 Today — 24 Hour Usage';

        html += '</div>';

        html +=
            renderCards(
                today.rx,
                today.tx
            );

    }

    /* ========================================================
       MONTH VIEW
       ======================================================== */

    else {

        var selected = null;

        months.forEach(
            function(m) {

                var key =
                    monthKey(
                        Number(m.year),
                        Number(m.month)
                    );

                if (
                    key === selectedKey
                ) {

                    selected = m;

                }

            }
        );

        if (!selected)
            selected = months[0];

        html +=
            '<div style="' +
            'margin-bottom:12px;' +
            'font-size:16px;' +
            'font-weight:600;' +
            '">';

        html +=
            '📅 ' +
            monthName(
                Number(selected.year),
                Number(selected.month)
            );

        html += '</div>';

        html +=
            renderCards(
                Number(selected.rx || 0),
                Number(selected.tx || 0)
            );

    }

    html += '</div>';

    return html;
}

/* ============================================================
   LUCI VIEW
   ============================================================ */

return view.extend({

    load: function() {

        return callNetUsage();

    },

    render: function() {

        var root =
            E('div', {
                'class': 'cbi-map'
            });

        /*
         * Default tab = Today
         */

        var selectedKey =
            'today';

        function bindButtons() {

            root.querySelectorAll(
                '[data-month]'
            ).forEach(
                function(button) {

                    button.addEventListener(
                        'click',
                        function() {

                            selectedKey =
                                button.getAttribute(
                                    'data-month'
                                );

                            refresh();

                        }
                    );

                }
            );

        }

        function refresh() {

            return callNetUsage()

                .then(
                    function(data) {

                        root.innerHTML =
                            renderUsage(
                                data,
                                selectedKey
                            );

                        bindButtons();

                    }
                )

                .catch(
                    function(error) {

                        root.innerHTML =
                            '<div class="alert-message">' +
                            'Unable to load data usage.' +
                            '</div>';

                        console.error(
                            'NetUsage RPC error:',
                            error
                        );

                    }
                );

        }

        refresh();

        /*
         * Auto refresh every 10 seconds
         */

        this.refreshTimer =
            setInterval(
                refresh,
                10000
            );

        return root;

    },

    /*
     * Properly stop refresh timer
     * when LuCI view is removed.
     */

    remove: function() {

        if (this.refreshTimer) {

            clearInterval(
                this.refreshTimer
            );

            this.refreshTimer = null;

        }

    },

    handleSaveApply: null,
    handleSave: null,
    handleReset: null

});
EOF

# ------------------------------------------------------------
# Boot recovery service
# ------------------------------------------------------------

cat > /etc/init.d/vnstat-netusage <<'EOF'
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=0

start() {

    (
        sleep 15

        WAN_IFACE="$(ubus call network.interface.wan status 2>/dev/null \
            | jsonfilter -e '@.l3_device' 2>/dev/null || true)"

        if [ -z "$WAN_IFACE" ]; then
            WAN_IFACE="$(ip route 2>/dev/null \
                | awk '/default/ {print $5; exit}')"
        fi

        [ -z "$WAN_IFACE" ] && WAN_IFACE="eth1"

        mkdir -p /etc/vnstat

        if [ -f /etc/vnstat.conf ]; then

            if grep -q '^DatabaseDir' /etc/vnstat.conf; then

                sed -i \
                    's|^DatabaseDir.*|DatabaseDir "/etc/vnstat"|' \
                    /etc/vnstat.conf

            else

                echo 'DatabaseDir "/etc/vnstat"' \
                    >> /etc/vnstat.conf

            fi

        else

            echo 'DatabaseDir "/etc/vnstat"' \
                > /etc/vnstat.conf

        fi

        if ! vnstat --iflist 2>/dev/null \
            | grep -qw "$WAN_IFACE"; then

            vnstat --create \
                -i "$WAN_IFACE" \
                2>/dev/null || true

        fi

        uci set netusage.main.interface="$WAN_IFACE"
        uci commit netusage

        /etc/init.d/vnstat restart

    ) &

}

stop() {
    return 0
}
EOF

chmod +x /etc/init.d/vnstat-netusage

/etc/init.d/vnstat-netusage enable

# ------------------------------------------------------------
# Restart LuCI services
# ------------------------------------------------------------

/etc/init.d/rpcd restart 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true

rm -rf /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache* 2>/dev/null || true

# ------------------------------------------------------------
# Final
# ------------------------------------------------------------

ok "NetUsage installed"
ok "vnStat database: /etc/vnstat"
ok "WAN interface: $WAN_IFACE"
ok "Today usage enabled"
ok "Latest 3 calendar months enabled"
ok "Current month auto-created when empty"
ok "MB / GB / TB display enabled"
ok "Colourful UI enabled"
ok "Boot recovery service enabled"

exit 0
