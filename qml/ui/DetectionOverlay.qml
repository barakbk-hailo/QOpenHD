import QtQuick 2.12
import OpenHD 1.0

/**
 * Full-screen overlay drawn on top of the primary video stream.
 *
 * Non-tracked detections render as thin white bboxes (operator can see
 * everyone the AI is detecting). The active target is drawn as a green
 * cross (+) at the bbox center, not as a bbox — visually identical to
 * what the air unit's local cairooverlay paints, so display / record /
 * OpenHD all match.
 *
 * Mode badge (top-left): LOCKED / AUTO / SEARCH / IDLE.
 *
 * "TARGET CHANGED" toast flashes near the top whenever active_id transitions.
 *
 * Coordinates are normalized [0,1] in video space; the overlay accounts
 * for aspect-ratio letterboxing so everything stays aligned with the
 * actual rendered video area.
 */
Item {
    id: root
    anchors.fill: parent
    visible: _hailoDetectionModel.receiving

    // -------------------------------------------------------------------------
    // Video-area math (handles letterboxing).
    // -------------------------------------------------------------------------
    function parseVideoSize(fmt) {
        var m = fmt.match(/(\d+)x(\d+)/)
        if (m) return { w: parseInt(m[1]), h: parseInt(m[2]) }
        return { w: 0, h: 0 }
    }
    property var vsize: parseVideoSize(_decodingStatistics.primary_stream_frame_format)
    property real renderedW: {
        if (vsize.w <= 0 || vsize.h <= 0) return width
        return vsize.w * Math.min(width / vsize.w, height / vsize.h)
    }
    property real renderedH: {
        if (vsize.w <= 0 || vsize.h <= 0) return height
        return vsize.h * Math.min(width / vsize.w, height / vsize.h)
    }
    property real offsetX: (width  - renderedW) / 2
    property real offsetY: (height - renderedH) / 2

    // -------------------------------------------------------------------------
    // Mode (0=AUTO, 1=LOCKED, 2=SEARCH, 3=IDLE)
    // -------------------------------------------------------------------------
    function modeLabel(m) {
        if (m === 1) return "LOCKED"
        if (m === 2) return "SEARCH"
        if (m === 3) return "IDLE"
        return "AUTO"
    }
    function modeColor(m) {
        if (m === 2) return "#ffc46b"   // amber for SEARCH
        return "#80f060"                // green for AUTO / LOCKED / IDLE
    }

    // -------------------------------------------------------------------------
    // Followee-change flash + cause attribution.
    //
    // When active_id transitions we briefly flash the badge and a centred toast.
    // The toast text distinguishes who caused the switch:
    //
    //   USER LOCKED ID N   ← the operator clicked a bbox in QOpenHD
    //   AUTO ID N          ← drone-follow auto-acquired (largest person, REID drift)
    //   TARGET CLEARED     ← follow_id went to 0
    //
    // Attribution: _requestedFollowId is updated on every QOpenHD bbox click;
    // when active_id later matches it, the switch was user-initiated. Anything
    // else is treated as AUTO.
    // -------------------------------------------------------------------------
    property int _lastActiveId: 0
    property int _requestedFollowId: -999     // sentinel for "no recent user click"
    property bool flashActive: false
    property string toastText: ""

    function followId(id) {
        // Single entry point used by every bbox click. Marks the request so
        // the next active_id transition is attributed to USER.
        root._requestedFollowId = id
        _ohdSystemAirSettingsModel.try_set_param_int_async("DF_FOLLOW_ID", id)
    }

    Connections {
        target: _hailoDetectionModel
        function onActive_idChanged() {
            var newId = _hailoDetectionModel.active_id
            if (newId === root._lastActiveId) return

            if (newId === 0) {
                root.toastText = "TARGET CLEARED"
            } else if (newId === root._requestedFollowId) {
                root.toastText = "USER LOCKED ID " + newId
            } else {
                root.toastText = "AUTO ID " + newId
            }
            root.flashActive = true
            flashTimer.restart()
            root._lastActiveId = newId
        }
    }
    Timer {
        id: flashTimer
        interval: 2000
        repeat: false
        onTriggered: root.flashActive = false
    }

    // -------------------------------------------------------------------------
    // Per-detection draw: bbox for non-target, cross for the active target.
    // -------------------------------------------------------------------------
    Repeater {
        model: _hailoDetectionModel.detections
        delegate: Item {
            property var det: modelData
            property real bx: root.offsetX + (det.cx - det.w / 2) * root.renderedW
            property real by: root.offsetY + (det.cy - det.h / 2) * root.renderedH
            property real bw: det.w * root.renderedW
            property real bh: det.h * root.renderedH
            property real centerX: root.offsetX + det.cx * root.renderedW
            property real centerY: root.offsetY + det.cy * root.renderedH

            // Click-to-follow: tap anywhere inside the bbox to set DF_FOLLOW_ID
            // to this detection's id. Same MAVLink path the DroneFollowWidget
            // settings panel uses. Covers both the white bbox (non-tracked) and
            // the green cross (tracked, where clicking re-confirms the lock).
            MouseArea {
                x: parent.bx; y: parent.by
                width: parent.bw; height: parent.bh
                z: 5
                acceptedButtons: Qt.LeftButton
                onClicked: root.followId(parent.det.id)
            }

            // Non-tracked detections — thin white bbox + ID label.
            Rectangle {
                visible: !det.tracked
                x: parent.bx; y: parent.by
                width: parent.bw; height: parent.bh
                color: "transparent"
                border.color: "#ffffff"
                border.width: 1
                Text {
                    anchors { bottom: parent.top; left: parent.left; bottomMargin: 2 }
                    text: "ID " + parent.parent.det.id
                    color: "#ffffff"
                    font.pixelSize: 12
                    style: Text.Outline
                    styleColor: "#000000"
                }
            }

            // Tracked detection — green cross at center, no bbox.
            Item {
                visible: det.tracked
                x: 0; y: 0
                z: 1
                property real armLen: Math.max(
                    12, Math.min(32, 0.025 * Math.min(root.renderedW, root.renderedH)))

                // Halo (black, behind the green cross — keeps it readable).
                Rectangle {
                    x: parent.parent.centerX - parent.armLen
                    y: parent.parent.centerY - 3
                    width: parent.armLen * 2
                    height: 6
                    color: "#000000"; opacity: 0.75; radius: 3
                }
                Rectangle {
                    x: parent.parent.centerX - 3
                    y: parent.parent.centerY - parent.armLen
                    width: 6
                    height: parent.armLen * 2
                    color: "#000000"; opacity: 0.75; radius: 3
                }
                // Green cross on top.
                Rectangle {
                    x: parent.parent.centerX - parent.armLen
                    y: parent.parent.centerY - 1.5
                    width: parent.armLen * 2
                    height: 3
                    color: "#80f060"; radius: 1.5
                }
                Rectangle {
                    x: parent.parent.centerX - 1.5
                    y: parent.parent.centerY - parent.armLen
                    width: 3
                    height: parent.armLen * 2
                    color: "#80f060"; radius: 1.5
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Mode badge — top-center. Always visible while receiving.
    // -------------------------------------------------------------------------
    Rectangle {
        id: badge
        anchors.horizontalCenter: parent.horizontalCenter
        y: 16
        width: badgeText.implicitWidth + 16
        height: badgeText.implicitHeight + 8
        color: root.flashActive ? "#e28b4a" : "#000000"
        opacity: root.flashActive ? 0.85 : 0.55
        radius: 4
        Text {
            id: badgeText
            anchors.centerIn: parent
            text: root.modeLabel(_hailoDetectionModel.mode)
            color: root.flashActive ? "#ffffff" : root.modeColor(_hailoDetectionModel.mode)
            font.pixelSize: Math.max(12, Math.round(root.renderedH * 0.022))
            font.bold: true
        }
    }

    // -------------------------------------------------------------------------
    // "TARGET CHANGED" toast — centered banner near top, 2 s after switch.
    // -------------------------------------------------------------------------
    Rectangle {
        visible: root.flashActive
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.offsetY + root.renderedH * 0.08
        width: toastText.implicitWidth + 28
        height: toastText.implicitHeight + 16
        color: "#e28b4a"
        opacity: 0.85
        radius: 6
        Text {
            id: toastText
            anchors.centerIn: parent
            text: root.toastText.length > 0 ? root.toastText : "TARGET CHANGED"
            color: "#ffffff"
            font.pixelSize: Math.max(16, Math.round(root.renderedH * 0.034))
            font.bold: true
        }
    }
}
