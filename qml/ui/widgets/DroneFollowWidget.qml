import QtQuick 2.12
import QtQuick.Controls 2.12
import Qt.labs.settings 1.0
import OpenHD 1.0
import "../elements"

// Drone follow status overlay — centered on the HUD crosshairs.
// A colour-coded ring wraps the horizon center indicator; the status text
// appears just below it. Tap anywhere on the widget to open the popup.
//
// Ring / label states (DF_FOLLOW_ID / DF_ACTIVE_ID):
//   followId < 0  → IDLE   (amber)  — drone holds position, ignores detections
//   followId = 0, activeId = 0  → AUTO  (grey dim) — no one in view
//   followId = 0, activeId > 0  → AUTO · #N (teal)  — system auto-picked N
//   followId > 0  → #N    (red)   — operator locked to person N
BaseWidget {
    id: droneFollowWidget
    width: 140
    height: 80

    visible: settings.show_widgets

    // New identifier forces a fresh default position (clears old saved bottom-left coords)
    widgetIdentifier: "drone_follow_overlay"
    bw_verbose_name: "DRONE FOLLOW"

    // Centered on the HUD, overlapping the horizon crosshairs
    defaultHCenter: true
    defaultVCenter: true

    hasWidgetDetail: false
    hasWidgetAction: true
    widgetActionWidth: 240
    widgetActionHeight: 360

    // DF_FOLLOW_ID from MAVLink param cache (operator intent: -1=idle, 0=auto, N=locked)
    property int followId: 0

    // Live data from HailoDetectionModel — updated reactively via TUNNEL messages
    property int activeId: _hailoDetectionModel.active_id

    property var availIds: {
        var det = _hailoDetectionModel.detections
        var ids = []
        for (var i = 0; i < det.length; i++) ids.push(det[i].id)
        ids.sort(function(a, b) { return a - b })
        return ids
    }

    function refreshFollowId() {
        if (_ohdSystemAirSettingsModel.param_int_exists("DF_FOLLOW_ID"))
            followId = _ohdSystemAirSettingsModel.get_cached_int("DF_FOLLOW_ID")
    }

    Connections {
        target: _ohdSystemAirSettingsModel
        // Fires after individual param writes (operator button taps)
        function onUpdate_countChanged() {
            droneFollowWidget.refreshFollowId()
        }
    }

    // --- Popup (short-click) ---
    widgetActionComponent: Item {
        width: 240
        height: 360

        // Keep followId fresh while popup is open
        Timer {
            id: popupRefreshTimer
            interval: 800
            repeat: true
            running: false
            onTriggered: droneFollowWidget.refreshFollowId()
        }

        onVisibleChanged: {
            if (visible) {
                droneFollowWidget.refreshFollowId()
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
                        droneFollowWidget.bw_manually_close_action_popup()
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
                highlighted: followId === 0
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
                    droneFollowWidget.bw_manually_close_action_popup()
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
                    droneFollowWidget.bw_manually_close_action_popup()
                }
            }
        }
    }

    // --- Crosshair overlay (closed state) ---
    // Transparent top portion sits over the horizon center indicator — the whole
    // widget is the tap target. Ring at widget center = screen center. Text below.
    Item {
        id: widgetInner
        anchors.fill: parent

        // Colored ring wrapping the horizon's center indicator
        Rectangle {
            id: stateRing
            width: 36
            height: 36
            radius: 18
            color: "transparent"
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            border.width: 2
            border.color: followId > 0  ? "#ff4466"
                        : followId < 0  ? "#ffaa00"
                        : activeId > 0  ? "#33bbbb"
                        : "#555555"
            opacity: (followId !== 0 || activeId > 0) ? 0.9 : 0.5
        }

        // Status text pill — just below the ring
        Rectangle {
            id: statusLabel
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: stateRing.bottom
            anchors.topMargin: 6
            width: labelText.contentWidth + 14
            height: 20
            radius: 4
            color: followId > 0  ? "#992233"
                 : followId < 0  ? "#7a5000"
                 : activeId > 0  ? "#1a5f5f"
                 : "#333333"
            opacity: 0.80

            Text {
                id: labelText
                anchors.centerIn: parent
                text: followId > 0   ? "\u25CE  #" + followId
                    : followId < 0   ? "\u25CE  IDLE"
                    : activeId > 0   ? "\u25CE  AUTO \u00B7 #" + activeId
                    : "\u25CE  AUTO"
                color: "white"
                font.pixelSize: 11
                font.bold: true
                style: Text.Outline
                styleColor: settings.color_glow
            }
        }
    }
}
