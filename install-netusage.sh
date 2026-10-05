#!/bin/sh

# ============================================================
# NetUsage Installer for OpenWrt
# vnStat + LuCI NetUsage
# Persistent database + latest 3 months UI
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

# Configure persistent database directory
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
# Create database for WAN interface
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
        echo '{"read":["*"]}'
        ;;

    read)
        vnstat -i "$IFACE" --json 2>/dev/null
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
                "luci.netusage": [
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
    object: 'luci.netusage',
    method: 'read',
    expect: {}
});

function formatBytes(bytes) {
    bytes = Number(bytes || 0);

    if (bytes >= 1024 * 1024 * 1024 * 1024)
        return (bytes / (1024 * 1024 * 1024 * 1024)).toFixed(2) + ' TB';

    if (bytes >= 1024 * 1024 * 1024)
        return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';

    if (bytes >= 1024 * 1024)
        return (bytes / (1024 * 1024)).toFixed(2) + ' MB';

    if (bytes >= 1024)
        return (bytes / 1024).toFixed(2) + ' KB';

    return bytes + ' B';
}

function monthName(year, month) {
    var date = new Date(year, month - 1, 1);

    return date.toLocaleString('default', {
        month: 'long',
        year: 'numeric'
    });
}

function monthKey(year, month) {
    return year + '-' + String(month).padStart(2, '0');
}

function renderMonth(data, selectedKey) {

    var iface = data.interfaces && data.interfaces[0];

    if (!iface || !iface.traffic || !iface.traffic.month)
        return '<div class="alert-message">No usage data available.</div>';

    var months = iface.traffic.month.slice();

    months.sort(function(a, b) {
        var ka = Number(a.date || 0);
        var kb = Number(b.date || 0);

        return kb - ka;
    });

    /* Only latest 3 months */
    months = months.slice(0, 3);

    var selected = null;

    months.forEach(function(m) {

        var year = Number(m.year);
        var month = Number(m.month);

        if (monthKey(year, month) === selectedKey)
            selected = m;
    });

    if (!selected && months.length)
        selected = months[0];

    if (!selected)
        return '<div class="alert-message">No monthly usage data.</div>';

    var rx = Number(selected.rx || 0);
    var tx = Number(selected.tx || 0);

    var total = rx + tx;

    var html = '';

    html += '<div class="cbi-section">';

    html += '<h2>Monthly Data Usage</h2>';

    html += '<div style="display:flex;gap:8px;flex-wrap:wrap;margin-bottom:20px;">';

    months.forEach(function(m, index) {

        var year = Number(m.year);
        var month = Number(m.month);

        var key = monthKey(year, month);

        var active = key === selectedKey ||
            (!selectedKey && index === 0);

        html += '<button class="cbi-button' +
            (active ? ' cbi-button-positive' : '') +
            '" data-month="' + key + '">' +
            monthName(year, month) +
            ' #' + (index + 1) +
            '</button>';
    });

    html += '</div>';

    html += '<div class="table cbi-section-table">';

    html += '<div class="tr table-titles">';
    html += '<div class="th">Download</div>';
    html += '<div class="th">Upload</div>';
    html += '<div class="th">Total</div>';
    html += '</div>';

    html += '<div class="tr">';

    html += '<div class="td">';
    html += '<strong>' + formatBytes(rx) + '</strong>';
    html += '</div>';

    html += '<div class="td">';
    html += '<strong>' + formatBytes(tx) + '</strong>';
    html += '</div>';

    html += '<div class="td">';
    html += '<strong>' + formatBytes(total) + '</strong>';
    html += '</div>';

    html += '</div>';

    html += '</div>';
    html += '</div>';

    return html;
}

return view.extend({

    load: function() {
        return callNetUsage();
    },

    render: function(data) {

        var root = E('div', {
            'class': 'cbi-map'
        });

        var selectedKey = null;

        function refresh() {

            return callNetUsage().then(function(newData) {

                root.innerHTML = renderMonth(
                    newData,
                    selectedKey
                );

                root.querySelectorAll(
                    '[data-month]'
                ).forEach(function(button) {

                    button.addEventListener('click', function() {

                        selectedKey =
                            button.getAttribute('data-month');

                        refresh();
                    });
                });
            });
        }

        refresh();

        /* Refresh usage automatically */
        L.bind(
            function() {
                refresh();
            },
            this
        );

        return root;
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
                sed -i 's|^DatabaseDir.*|DatabaseDir "/etc/vnstat"|' \
                    /etc/vnstat.conf
            else
                echo 'DatabaseDir "/etc/vnstat"' >> /etc/vnstat.conf
            fi

        else
            echo 'DatabaseDir "/etc/vnstat"' > /etc/vnstat.conf
        fi

        if ! vnstat --iflist 2>/dev/null | grep -qw "$WAN_IFACE"; then
            vnstat --create -i "$WAN_IFACE" 2>/dev/null || true
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
ok "Latest 3 months enabled"
ok "Boot recovery service enabled"

exit 0