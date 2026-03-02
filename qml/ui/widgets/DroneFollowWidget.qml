import QtQuick 2.12
import QtQuick.Controls 2.12
import Qt.labs.settings 1.0
import OpenHD 1.0
import "../elements"

// Floating widget for controlling the Hailo drone follow app from the ground.
// Short-click opens a popup listing currently tracked person IDs so the
// operator can select a target or switch back to auto (largest) mode.
// DF_FOLLOW_ID is set via the existing MAVLink parameter bridge which routes
// through wifibroadcast to the hailo_follow_bridge on the air unit.
BaseWidget {
    id: droneFollowWidget
    width: 130
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
    widgetActionHeight: 320

    // --- State read from MAVLink param cache ---
    property int followId: 0
    property var availIds: []

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
        if (_ohdSystemAirSettingsModel.param_int_exists("DF_FOLLOW_ID")) {
            followId = _ohdSystemAirSettingsModel.get_cached_int("DF_FOLLOW_ID")
        }
        if (_ohdSystemAirSettingsModel.param_string_exists("DF_AVAIL_IDS")) {
            availIds = parseAvailIds(_ohdSystemAirSettingsModel.get_cached_string("DF_AVAIL_IDS"))
        }
    }

    // Auto-refresh whenever any param in the model is updated
    Connections {
        target: _ohdSystemAirSettingsModel
        function onUpdate_countChanged() {
            droneFollowWidget.refreshState()
        }
    }

    // --- Popup (short-click) ---
    widgetActionComponent: Item {
        width: 240
        height: 320

        // Periodically refresh state while the popup is open.
        // This catches async refetch completions (try_refetch_all_parameters_async
        // replaces the full param set without firing update_countChanged) and
        // ensures DF_AVAIL_IDS and DF_FOLLOW_ID stay current.
        Timer {
            id: popupRefreshTimer
            interval: 800
            repeat: true
            running: false
            onTriggered: droneFollowWidget.refreshState()
        }

        onVisibleChanged: {
            if (visible) {
                // Trigger a fresh fetch so the ID list is up-to-date
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

            // Auto / clear button
            Button {
                width: parent.width
                height: 38
                text: followId <= 0 ? "✓  AUTO (LARGEST)" : "CLEAR — USE AUTO"
                highlighted: followId <= 0
                background: Rectangle {
                    color: followId <= 0 ? "#226644" : "#444444"
                    radius: 4
                }
                contentItem: Text {
                    text: parent.text
                    color: "white"
                    font.pixelSize: 13
                    font.bold: followId <= 0
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
        }
    }

    // --- Compact badge (closed state) ---
    Item {
        id: widgetInner
        anchors.fill: parent

        Rectangle {
            anchors.fill: parent
            color: followId > 0 ? "#992233" : "#333333"
            opacity: 0.85
            radius: 4
            border.color: followId > 0 ? "#ff4466" : "#555555"
            border.width: 1
        }

        Text {
            anchors.centerIn: parent
            text: followId > 0 ? "\u25CE  #" + followId : "\u25CE  AUTO"
            color: "white"
            font.pixelSize: 13
            font.bold: true
            style: Text.Outline
            styleColor: settings.color_glow
        }
    }
}
