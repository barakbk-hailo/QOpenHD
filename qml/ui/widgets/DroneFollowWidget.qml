import QtQuick 2.12
import QtQuick.Controls 2.12
import Qt.labs.settings 1.0
import OpenHD 1.0
import "../elements"

// Floating widget for controlling the Hailo drone follow app from the ground.
// Short-click opens a popup letting the operator pick a tracked person, pause
// the drone (IDLE), or return to auto mode.
//
// Badge states (DF_FOLLOW_ID / DF_ACTIVE_ID):
//   followId < 0  → IDLE (amber)  — drone holds position, ignores detections
//   followId = 0, activeId = 0  → AUTO (grey)  — no one in view
//   followId = 0, activeId > 0  → AUTO · #N (teal) — system auto-picked N
//   followId > 0  → #N (red)  — operator locked to person N
BaseWidget {
    id: droneFollowWidget
    width: 140
    height: 36

    visible: settings.show_widgets

    widgetIdentifier: "drone_follow_widget"
    bw_verbose_name: "DRONE FOLLOW"

    // Bottom-left area, offset inward from the corner
    defaultAlignment: 3
    defaultXOffset: 60
    defaultYOffset: 60
    defaultHCenter: false
    defaultVCenter: false

    hasWidgetDetail: false
    hasWidgetAction: true
    widgetActionWidth: 240
    widgetActionHeight: 360

    // --- State read from MAVLink param cache ---
    property int followId: 0    // DF_FOLLOW_ID: operator intent (-1=idle, 0=auto, N=locked)
    property int activeId: 0    // DF_ACTIVE_ID: currently tracked ID (auto or locked), 0=none
    property var availIds: []   // DF_AVAIL_IDS: IDs visible in frame

    function parseAvailIds(str) {
        if (!str || str.trim() === "") return []
        var parts = str.split(",")
        var result = []
        for (var i = 0; i < parts.length; i++) {
            var n = parseInt(parts[i].trim())
            if (!isNaN(n) && n > 0) result.push(n)
        }
        return result
    }

    function refreshState() {
        if (_ohdSystemAirSettingsModel.param_int_exists("DF_FOLLOW_ID"))
            followId = _ohdSystemAirSettingsModel.get_cached_int("DF_FOLLOW_ID")
        if (_ohdSystemAirSettingsModel.param_int_exists("DF_ACTIVE_ID"))
            activeId = _ohdSystemAirSettingsModel.get_cached_int("DF_ACTIVE_ID")
        if (_ohdSystemAirSettingsModel.param_string_exists("DF_AVAIL_IDS"))
            availIds = parseAvailIds(_ohdSystemAirSettingsModel.get_cached_string("DF_AVAIL_IDS"))
    }

    // Periodic refetch: keeps DF_ACTIVE_ID and DF_AVAIL_IDS fresh in the cache.
    // try_refetch_all_parameters_async replaces the full param cache but does NOT
    // fire update_countChanged, so we also listen to curr_get_all_progress_perc
    // reaching 100 to trigger refreshState() after each completed refetch.
    Timer {
        id: outerRefetchTimer
        interval: 3000
        repeat: true
        running: droneFollowWidget.visible
        onTriggered: {
            if (!_ohdSystemAirSettingsModel.ui_is_busy)
                _ohdSystemAirSettingsModel.try_refetch_all_parameters_async(false)
        }
    }

    Connections {
        target: _ohdSystemAirSettingsModel
        // Fires after each completed full refetch (progress reaches 100)
        function onCurr_get_all_progress_percChanged() {
            if (_ohdSystemAirSettingsModel.curr_get_all_progress_perc >= 100)
                droneFollowWidget.refreshState()
        }
        // Fires after individual param writes (operator button taps)
        function onUpdate_countChanged() {
            droneFollowWidget.refreshState()
        }
    }

    // --- Popup (short-click) ---
    widgetActionComponent: Item {
        width: 240
        height: 360

        // Read cached values at 800ms while popup is open — fast feedback
        // after button taps and after refetches triggered by outerRefetchTimer.
        Timer {
            id: popupRefreshTimer
            interval: 800
            repeat: true
            running: false
            onTriggered: droneFollowWidget.refreshState()
        }

        onVisibleChanged: {
            if (visible) {
                // Immediate refetch on open (don't wait for outerRefetchTimer)
                if (!_ohdSystemAirSettingsModel.ui_is_busy)
                    _ohdSystemAirSettingsModel.try_refetch_all_parameters_async(false)
                droneFollowWidget.refreshState()
                popupRefreshTimer.start()
            } else {
                popupRefreshTimer.stop()
            }
        }

        Column {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 8

            Text {
                width: parent.width
                text: "DRONE FOLLOW"
                color: "white"
                font.pixelSize: 14
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                style: Text.Outline
                styleColor: settings.color_glow
            }

            Rectangle {
                width: parent.width
                height: 1
                color: "#666666"
            }

            Text {
                width: parent.width
                text: availIds.length > 0
                      ? "PERSONS IN VIEW (" + availIds.length + ")"
                      : "NO PERSONS TRACKED"
                color: availIds.length > 0 ? "#aaaaaa" : "#666666"
                font.pixelSize: 11
                horizontalAlignment: Text.AlignHCenter
            }

            // One button per tracked person
            Repeater {
                model: availIds
                Button {
                    width: parent.width
                    height: 38
                    text: "PERSON  #" + modelData
                    highlighted: modelData === followId
                    background: Rectangle {
                        color: modelData === followId ? "#bb2244" : "#444444"
                        radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: "white"
                        font.pixelSize: 13
                        font.bold: modelData === followId
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        style: Text.Outline
                        styleColor: "#000000"
                    }
                    onClicked: {
                        _ohdSystemAirSettingsModel.try_set_param_int_async("DF_FOLLOW_ID", modelData)
                        followId = modelData
                    }
                }
            }

            // AUTO / CLEAR button
            Button {
                width: parent.width
                height: 38
                text: followId <= 0
                      ? (activeId > 0 ? "\u2713  AUTO (tracking #" + activeId + ")" : "\u2713  AUTO (LARGEST)")
                      : "CLEAR \u2014 USE AUTO"
                highlighted: followId <= 0 && followId >= 0  // true when followId == 0
                background: Rectangle {
                    color: (followId === 0) ? "#226644" : "#444444"
                    radius: 4
                }
                contentItem: Text {
                    text: parent.text
                    color: "white"
                    font.pixelSize: 13
                    font.bold: followId === 0
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    style: Text.Outline
                    styleColor: "#000000"
                }
                onClicked: {
                    _ohdSystemAirSettingsModel.try_set_param_int_async("DF_FOLLOW_ID", 0)
                    followId = 0
                }
            }

            // IDLE / PAUSE button
            Button {
                width: parent.width
                height: 38
                text: followId < 0 ? "\u25CE  IDLE (holding position)" : "PAUSE \u2014 HOLD POSITION"
                highlighted: followId < 0
                background: Rectangle {
                    color: followId < 0 ? "#7a5000" : "#444444"
                    radius: 4
                }
                contentItem: Text {
                    text: parent.text
                    color: "white"
                    font.pixelSize: 13
                    font.bold: followId < 0
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    style: Text.Outline
                    styleColor: "#000000"
                }
                onClicked: {
                    _ohdSystemAirSettingsModel.try_set_param_int_async("DF_FOLLOW_ID", -1)
                    followId = -1
                }
            }
        }
    }

    // --- Compact badge (closed state) ---
    Item {
        id: widgetInner
        anchors.fill: parent

        Rectangle {
            anchors.fill: parent
            color: followId > 0  ? "#992233"   // red — operator locked
                 : followId < 0  ? "#7a5000"   // amber — IDLE
                 : activeId > 0  ? "#1a5f5f"   // teal — auto-tracking someone
                 : "#333333"                    // grey — no one in view
            opacity: 0.85
            radius: 4
            border.color: followId > 0  ? "#ff4466"
                        : followId < 0  ? "#ffaa00"
                        : activeId > 0  ? "#33bbbb"
                        : "#555555"
            border.width: 1
        }

        Text {
            anchors.centerIn: parent
            text: followId > 0   ? "\u25CE  #" + followId
                : followId < 0   ? "\u25CE  IDLE"
                : activeId > 0   ? "\u25CE  AUTO \u00B7 #" + activeId
                : "\u25CE  AUTO"
            color: "white"
            font.pixelSize: 13
            font.bold: true
            style: Text.Outline
            styleColor: settings.color_glow
        }
    }
}
