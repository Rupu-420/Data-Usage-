#!/bin/sh

# ============================================================
# NETUSAGE - OpenWrt vnStat + LuCI Data Usage
# ============================================================

set -e

log() {
    echo "[NetUsage] $1"
}

ok() {
    echo "[NetUsage] OK: $1"
}

err() {
    echo "[NetUsage] ERROR: $1"
}

# ============================================================
# INSTALL VNSTAT
# ============================================================

log "Installing vnStat..."

if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1 || true
    apk add vnstat
elif command -v opkg >/dev/null 2>&1; then
    opkg update >/dev/null 2>&1 || true
    opkg install vnstat
else
    err "No apk/opkg package manager found"
    exit 1
fi

# ============================================================
# DETECT WAN INTERFACE
# ============================================================

WAN_IFACE="$(
    ubus call network.interface.wan status 2>/dev/null \
    | jsonfilter -e '@.l3_device' 2>/dev/null || true
)"

if [ -z "$WAN_IFACE" ]; then
    WAN_IFACE="$(
        ip route 2>/dev/null \
        | awk '/^default/ {print $5; exit}'
    )"
fi

[ -z "$WAN_IFACE" ] && WAN_IFACE="eth1"

log "WAN interface: $WAN_IFACE"

# ============================================================
# PERSISTENT VNSTAT DATABASE
# ============================================================

mkdir -p /etc/vnstat

# Migrate old database if it exists.
# Existing /etc/vnstat data is NEVER deleted.
if [ -d /var/lib/vnstat ]; then

    for DB in /var/lib/vnstat/*; do
        [ -e "$DB" ] || continue

        BASENAME="$(basename "$DB")"

        if [ ! -e "/etc/vnstat/$BASENAME" ]; then
            mv "$DB" "/etc/vnstat/$BASENAME" 2>/dev/null || true
        fi
    done

fi

# ============================================================
# VNSTAT CONFIG
# ============================================================

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

    cat > /etc/vnstat.conf <<'EOF'
DatabaseDir "/etc/vnstat"
EOF

fi

# ------------------------------------------------------------
# Update traffic every 20 seconds
# ------------------------------------------------------------

if grep -q '^UpdateInterval' /etc/vnstat.conf; then
    sed -i \
        's|^UpdateInterval.*|UpdateInterval 20|' \
        /etc/vnstat.conf
else
    echo 'UpdateInterval 20' \
        >> /etc/vnstat.conf
fi

# ------------------------------------------------------------
# Poll interface every 5 seconds
# ------------------------------------------------------------

if grep -q '^PollInterval' /etc/vnstat.conf; then
    sed -i \
        's|^PollInterval.*|PollInterval 5|' \
        /etc/vnstat.conf
else
    echo 'PollInterval 5' \
        >> /etc/vnstat.conf
fi

# ------------------------------------------------------------
# Save database every 1 minute
# ------------------------------------------------------------

if grep -q '^SaveInterval' /etc/vnstat.conf; then
    sed -i \
        's|^SaveInterval.*|SaveInterval 1|' \
        /etc/vnstat.conf
else
    echo 'SaveInterval 1' \
        >> /etc/vnstat.conf
fi

# ============================================================
# CREATE WAN DATABASE IF MISSING
# ============================================================

log "Checking existing vnStat database..."

if [ ! -e "/etc/vnstat/$WAN_IFACE" ]; then

    log "Creating vnStat database for $WAN_IFACE..."

    vnstat --add -i "$WAN_IFACE" \
        >/dev/null 2>&1 || true

else

    log "vnStat database already exists for $WAN_IFACE"

fi

# ============================================================
# NETUSAGE UCI CONFIG
# ============================================================

mkdir -p /etc/config

cat > /etc/config/netusage <<EOF
config netusage 'main'
    option interface '$WAN_IFACE'
EOF

# ============================================================
# RPCD BACKEND
# ============================================================

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

# ============================================================
# RPCD ACL
# ============================================================

mkdir -p /usr/share/rpcd/acl.d

cat > /usr/share/rpcd/acl.d/luci-app-netusage.json <<'EOF'
{
    "luci-app-netusage": {
        "description": "NetUsage data access",
        "read": {
            "ubus": {
                "netusage": [
                    "read"
                ]
            }
        }
    }
}
EOF

# ============================================================
# LUCI MENU
# ============================================================

mkdir -p /usr/share/luci/menu.d

cat > /usr/share/luci/menu.d/luci-app-netusage.json <<'EOF'
{
    "admin/status/netusage": {
        "title": "Data Usage",
        "order": 20,
        "action": {
            "type": "view",
            "path": "status/netusage"
        },
        "depends": {
            "acl": [
                "luci-app-netusage"
            ]
        }
    }
}
EOF

# ============================================================
# LUCI JAVASCRIPT
# ============================================================

mkdir -p /www/luci-static/resources/view/status

cat > /www/luci-static/resources/view/status/netusage.js <<'EOF'
'use strict';

'require view';
'require rpc';

/* ==========================================================
 * RPC
 * ========================================================== */

var callNetUsage = rpc.declare({
    object: 'netusage',
    method: 'read',
    expect: {}
});

/* ==========================================================
 * FORMAT BYTES
 * ========================================================== */

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

/* ==========================================================
 * MONTH NAMES
 * ========================================================== */

function monthName(month) {

    var names = [
        '',
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December'
    ];

    return names[month] || '';
}

/* ==========================================================
 * GET CURRENT / PREVIOUS MONTH
 * ========================================================== */

function getTargetMonth(offset) {

    var d = new Date();

    d.setDate(1);
    d.setMonth(d.getMonth() - offset);

    return {
        year: d.getFullYear(),
        month: d.getMonth() + 1
    };
}

/* ==========================================================
 * CONVERT VNSTAT JSON
 *
 * vnStat 1.18 on this build reports rx/tx in KiB.
 * KiB -> Bytes = * 1024
 * ========================================================== */

function buildData(json) {

    /* Never allow undefined arrays */
    if (!json || typeof json !== 'object') {

        return {
            days: [],
            months: []
        };
    }

    if (!Array.isArray(json.interfaces)) {

        return {
            days: [],
            months: []
        };
    }

    if (json.interfaces.length === 0) {

        return {
            days: [],
            months: []
        };
    }

    var iface = json.interfaces[0];

    if (
        !iface ||
        !iface.traffic ||
        typeof iface.traffic !== 'object'
    ) {

        return {
            days: [],
            months: []
        };
    }

    var rawDays = Array.isArray(iface.traffic.days)
        ? iface.traffic.days
        : [];

    var rawMonths = Array.isArray(iface.traffic.months)
        ? iface.traffic.months
        : [];

    var SCALE = 1024;

    var days = rawDays.map(function(d) {

        var date = d.date || {};

        return {
            year: Number(date.year || 0),
            month: Number(date.month || 0),
            day: Number(date.day || 0),
            rx: Number(d.rx || 0) * SCALE,
            tx: Number(d.tx || 0) * SCALE
        };
    });

    var months = rawMonths.map(function(m) {

        var date = m.date || {};

        return {
            year: Number(date.year || 0),
            month: Number(date.month || 0),
            rx: Number(m.rx || 0) * SCALE,
            tx: Number(m.tx || 0) * SCALE
        };
    });

    return {
        days: days,
        months: months
    };
}

/* ==========================================================
 * CARD
 * ========================================================== */

function makeCard(title, value, cls, icon) {

    return E('div', {
        'class': 'netusage-card ' + cls
    }, [

        E('div', {
            'class': 'netusage-card-icon'
        }, icon),

        E('div', {
            'class': 'netusage-card-title'
        }, title),

        E('div', {
            'class': 'netusage-card-value'
        }, value)

    ]);
}

/* ==========================================================
 * VIEW
 * ========================================================== */

return view.extend({

    load: function() {

        return callNetUsage();
    },

    render: function(initialJson) {

        var self = this;

        /*
         * IMPORTANT:
         * Convert initial RPC response FIRST.
         * This fixes the original forEach/undefined crash.
         */
        var data = buildData(initialJson);

        var selectedTab = 'today';

        var root = E('div', {
            'class': 'netusage-wrapper'
        });

        var tabs = E('div', {
            'class': 'netusage-tabs'
        });

        var content = E('div', {
            'class': 'netusage-content'
        });

        /* ==================================================
         * CSS
         * ================================================== */

        var style = E('style', {}, `

            .netusage-wrapper {
                width: 100%;
            }

            .netusage-tabs {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
                margin-bottom: 18px;
            }

            .netusage-tab {
                border: 1px solid #ccc;
                border-radius: 10px;
                padding: 9px 14px;
                cursor: pointer;
                font-weight: 600;
                background: #f5f5f5;
                transition: 0.2s;
            }

            .netusage-tab:hover {
                transform: translateY(-1px);
            }

            .netusage-tab.active {
                box-shadow: 0 2px 8px rgba(0,0,0,0.15);
            }

            .tab-today {
                border-color: #8e44ad;
                background: #f5e9fb;
                color: #6c3483;
            }

            .tab-month-1 {
                border-color: #3498db;
                background: #eaf5fd;
                color: #21618c;
            }

            .tab-month-2 {
                border-color: #27ae60;
                background: #eafaf1;
                color: #1e8449;
            }

            .tab-month-3 {
                border-color: #e67e22;
                background: #fdf2e9;
                color: #a04000;
            }

            .netusage-cards {
                display: grid;
                grid-template-columns: repeat(3, 1fr);
                gap: 14px;
            }

            .netusage-card {
                border-radius: 14px;
                padding: 18px;
                border: 2px solid;
                min-height: 125px;
                box-sizing: border-box;
            }

            .netusage-card-icon {
                font-size: 28px;
                margin-bottom: 8px;
            }

            .netusage-card-title {
                font-size: 15px;
                font-weight: 600;
                margin-bottom: 7px;
            }

            .netusage-card-value {
                font-size: 22px;
                font-weight: 700;
            }

            .download-card {
                border-color: #3498db;
                background: #eaf5fd;
                color: #21618c;
            }

            .upload-card {
                border-color: #27ae60;
                background: #eafaf1;
                color: #1e8449;
            }

            .total-card {
                border-color: #e67e22;
                background: #fdf2e9;
                color: #a04000;
            }

            .netusage-heading {
                font-size: 20px;
                font-weight: 700;
                margin-bottom: 15px;
            }

            .netusage-updated {
                margin-top: 15px;
                font-size: 12px;
                opacity: 0.65;
            }

            @media (max-width: 700px) {

                .netusage-cards {
                    grid-template-columns: 1fr;
                }

            }

        `);

        root.appendChild(style);
        root.appendChild(tabs);
        root.appendChild(content);

        /* ==================================================
         * TODAY
         * ================================================== */

        function getToday() {

            var now = new Date();

            var year = now.getFullYear();
            var month = now.getMonth() + 1;
            var day = now.getDate();

            var rx = 0;
            var tx = 0;

            data.days.forEach(function(d) {

                if (
                    d.year === year &&
                    d.month === month &&
                    d.day === day
                ) {

                    rx += Number(d.rx || 0);
                    tx += Number(d.tx || 0);

                }

            });

            return {
                rx: rx,
                tx: tx,
                total: rx + tx
            };
        }

        /* ==================================================
         * MONTH
         * ================================================== */

        function getMonthData(target) {

            var rx = 0;
            var tx = 0;

            data.months.forEach(function(m) {

                if (
                    m.year === target.year &&
                    m.month === target.month
                ) {

                    rx += Number(m.rx || 0);
                    tx += Number(m.tx || 0);

                }

            });

            return {
                rx: rx,
                tx: tx,
                total: rx + tx
            };
        }

        /* ==================================================
         * TABS
         * ================================================== */

        function renderTabs() {

            while (tabs.firstChild) {
                tabs.removeChild(tabs.firstChild);
            }

            /* TODAY */

            tabs.appendChild(
                E('button', {

                    'class':
                        'netusage-tab tab-today' +
                        (
                            selectedTab === 'today'
                                ? ' active'
                                : ''
                        ),

                    'click': function() {

                        selectedTab = 'today';

                        renderCurrent();
                    }

                }, '📅 Today')
            );

            /* 3 MONTHS */

            for (var i = 0; i < 3; i++) {

                var target = getTargetMonth(i);

                var number = i + 1;

                tabs.appendChild(

                    E('button', {

                        'class':
                            'netusage-tab tab-month-' +
                            number +
                            (
                                selectedTab ===
                                'month' + number
                                    ? ' active'
                                    : ''
                            ),

                        'click': (function(index) {

                            return function() {

                                selectedTab =
                                    'month' +
                                    (index + 1);

                                renderCurrent();
                            };

                        })(i)

                    }, [

                        '📊 ',

                        monthName(target.month),

                        ' #',

                        String(number)

                    ])
                );
            }
        }

        /* ==================================================
         * RENDER CONTENT
         * ================================================== */

        function renderCurrent() {

            /*
             * Extra protection against malformed data.
             */
            if (!data || typeof data !== 'object') {

                data = {
                    days: [],
                    months: []
                };
            }

            if (!Array.isArray(data.days)) {
                data.days = [];
            }

            if (!Array.isArray(data.months)) {
                data.months = [];
            }

            renderTabs();

            while (content.firstChild) {
                content.removeChild(content.firstChild);
            }

            var rx = 0;
            var tx = 0;
            var total = 0;
            var heading = '';

            /* =================================================
             * TODAY
             * ================================================= */

            if (selectedTab === 'today') {

                var today = getToday();

                rx = today.rx;
                tx = today.tx;
                total = today.total;

                heading = 'Today';

            }

            /* =================================================
             * MONTH
             * ================================================= */

            else {

                var index =
                    Number(
                        selectedTab.replace(
                            'month',
                            ''
                        )
                    ) - 1;

                var target =
                    getTargetMonth(index);

                var month =
                    getMonthData(target);

                rx = month.rx;
                tx = month.tx;
                total = month.total;

                heading =
                    monthName(target.month) +
                    ' ' +
                    target.year;
            }

            /* =================================================
             * HEADING
             * ================================================= */

            content.appendChild(

                E('div', {
                    'class': 'netusage-heading'
                }, heading)

            );

            /* =================================================
             * CARDS
             * ================================================= */

            content.appendChild(

                E('div', {
                    'class': 'netusage-cards'
                }, [

                    makeCard(
                        'Download',
                        formatBytes(rx),
                        'download-card',
                        '📥'
                    ),

                    makeCard(
                        'Upload',
                        formatBytes(tx),
                        'upload-card',
                        '📤'
                    ),

                    makeCard(
                        'Total',
                        formatBytes(total),
                        'total-card',
                        '📊'
                    )

                ])

            );

            content.appendChild(

                E('div', {
                    'class': 'netusage-updated'
                }, 'Auto refresh: every 20 seconds')

            );
        }

        /* ==================================================
         * REFRESH
         * ================================================== */

        function refresh() {

            callNetUsage()

                .then(function(json) {

                    /*
                     * Always rebuild data from fresh RPC JSON.
                     */
                    data = buildData(json);

                    renderCurrent();

                })

                .catch(function(err) {

                    /*
                     * Do NOT destroy the current UI
                     * if one RPC request fails.
                     */
                    console.error(
                        'NetUsage refresh failed:',
                        err
                    );

                });
        }

        /* ==================================================
         * INITIAL RENDER
         * ================================================== */

        renderCurrent();

        /* ==================================================
         * 20 SECOND REFRESH
         * ================================================== */

        this.refreshTimer = setInterval(
            refresh,
            20000
        );

        return root;
    },

    /* ======================================================
     * CLEAN TIMER WHEN LEAVING PAGE
     * ====================================================== */

    destroy: function() {

        if (this.refreshTimer) {

            clearInterval(this.refreshTimer);

            this.refreshTimer = null;
        }

        return view.prototype.destroy.apply(
            this,
            arguments
        );
    }

});
EOF

# ============================================================
# BOOT RECOVERY SERVICE
# ============================================================

mkdir -p /etc/init.d

cat > /etc/init.d/vnstat-netusage <<'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10

start() {

    (
        sleep 15

        WAN_IFACE="$(
            ubus call network.interface.wan status 2>/dev/null \
            | jsonfilter -e '@.l3_device' 2>/dev/null || true
        )"

        if [ -z "$WAN_IFACE" ]; then

            WAN_IFACE="$(
                ip route 2>/dev/null \
                | awk '/^default/ {print $5; exit}'
            )"

        fi

        [ -z "$WAN_IFACE" ] && WAN_IFACE="eth1"

        mkdir -p /etc/vnstat

        # ----------------------------------------------------
        # Persistent database
        # ----------------------------------------------------

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

            cat > /etc/vnstat.conf <<'CFG'
DatabaseDir "/etc/vnstat"
CFG

        fi

        # ----------------------------------------------------
        # 20 second update
        # ----------------------------------------------------

        if grep -q '^UpdateInterval' /etc/vnstat.conf; then

            sed -i \
                's|^UpdateInterval.*|UpdateInterval 20|' \
                /etc/vnstat.conf

        else

            echo 'UpdateInterval 20' \
                >> /etc/vnstat.conf

        fi

        # ----------------------------------------------------
        # 5 second polling
        # ----------------------------------------------------

        if grep -q '^PollInterval' /etc/vnstat.conf; then

            sed -i \
                's|^PollInterval.*|PollInterval 5|' \
                /etc/vnstat.conf

        else

            echo 'PollInterval 5' \
                >> /etc/vnstat.conf

        fi

        # ----------------------------------------------------
        # 1 minute save
        # ----------------------------------------------------

        if grep -q '^SaveInterval' /etc/vnstat.conf; then

            sed -i \
                's|^SaveInterval.*|SaveInterval 1|' \
                /etc/vnstat.conf

        else

            echo 'SaveInterval 1' \
                >> /etc/vnstat.conf

        fi

        # ----------------------------------------------------
        # Create database if missing
        # ----------------------------------------------------

        if [ ! -e "/etc/vnstat/$WAN_IFACE" ]; then

            vnstat --add -i "$WAN_IFACE" \
                >/dev/null 2>&1 || true

        fi

        # ----------------------------------------------------
        # Keep UCI interface correct
        # ----------------------------------------------------

        uci set netusage.main.interface="$WAN_IFACE"
        uci commit netusage

        # ----------------------------------------------------
        # Restart vnStat
        # ----------------------------------------------------

        /etc/init.d/vnstat restart \
            >/dev/null 2>&1 || true

    ) &

}

stop() {
    :
}
EOF

chmod +x /etc/init.d/vnstat-netusage

# ============================================================
# ENABLE SERVICES
# ============================================================

/etc/init.d/vnstat enable \
    >/dev/null 2>&1 || true

/etc/init.d/vnstat restart \
    >/dev/null 2>&1 || true

/etc/init.d/vnstat-netusage enable \
    >/dev/null 2>&1 || true

# ============================================================
# RESTART RPCD / UHTTPD
# ============================================================

/etc/init.d/rpcd restart \
    >/dev/null 2>&1 || true

/etc/init.d/uhttpd restart \
    >/dev/null 2>&1 || true

# ============================================================
# CLEAR LUCI CACHE
# ============================================================

rm -rf /tmp/luci-* 2>/dev/null || true

# ============================================================
# FINAL STATUS
# ============================================================

ok "NetUsage installed"
ok "vnStat database: /etc/vnstat"
ok "WAN interface: $WAN_IFACE"
ok "Update interval: 20 seconds"
ok "Poll interval: 5 seconds"
ok "Save interval: 1 minute"
ok "UI refresh: 20 seconds"
ok "Today tab enabled"
ok "Latest 3 calendar months enabled"
ok "Current month auto-created when empty"
ok "Midnight daily/monthly rollover handled by vnStat"
ok "Boot recovery service enabled"

exit 0
