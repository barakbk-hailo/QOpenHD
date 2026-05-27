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

    // Optimistic feedback: which id was just tapped, so the bbox can flash
    // yellow before the MAVLink param round-trip turns it green via
    // det.tracked. Auto-clears after pendingTimer covers a worst-case link.
    property int pendingFollowId: -1
    Timer {
        id: pendingTimer
        interval: 1500
        onTriggered: root.pendingFollowId = -1
    }

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
    // Attribution: _requestedFollowId is updated on every QOpenHD bbox tap;
    // when active_id later matches it, the switch was user-initiated. Anything
    // else is treated as AUTO.
    // -------------------------------------------------------------------------
    property int _lastActiveId: 0
    property int _requestedFollowId: -999     // sentinel for "no recent user click"
    property bool flashActive: false
    property string toastText: ""

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
    //
    // We render through a fixed-size delegate pool (Repeater over an integer
    // model). A QVariantList-bound model destroyed and recreated every
    // delegate on each 10 Hz refresh, which killed the TapHandler instance
    // mid-gesture: press fired on instance N, but the delegate was destroyed
    // before the release arrived, so the tap never completed.
    //
    // With a fixed pool, each slot's TapHandler outlives any number of model
    // refreshes. We bind det reactively to detections[index]; if the slot's
    // person changes mid-gesture we still complete the press→tap on the
    // *originally pressed* id (captured below in onPressedChanged).
    // -------------------------------------------------------------------------
    property int maxDetections: 16

    Repeater {
        model: root.maxDetections
        delegate: Item {
            id: bboxSlot
            property int slotIndex: index
            property var det: slotIndex < _hailoDetectionModel.detections.length
                            ? _hailoDetectionModel.detections[slotIndex]
                            : null
            property bool hasDet: det !== null && det.id !== undefined && det.id > 0
            property real bx: hasDet ? root.offsetX + (det.cx - det.w / 2) * root.renderedW : 0
            property real by: hasDet ? root.offsetY + (det.cy - det.h / 2) * root.renderedH : 0
            property real bw: hasDet ? det.w * root.renderedW : 0
            property real bh: hasDet ? det.h * root.renderedH : 0
            property bool pendingLock: hasDet
                                    && det.id === root.pendingFollowId
                                    && !det.tracked

            // The slot itself sits on the bbox geometry — TapHandler hit
            // area is the Item's bounds. Tracked target's green cross is
            // a child Item rendered in absolute coordinates (no parent
            // geometry needed for it).
            visible: hasDet
            x: bx
            y: by
            width:  bw
            height: bh

            // Non-tracked detections — thin white bbox + ID label.
            // Yellow flash while a tap-to-follow is in flight (pendingLock).
            Rectangle {
                visible: hasDet && !det.tracked
                anchors.fill: parent
                color: "transparent"
                border.color: pendingLock ? "#ffff00" : "#ffffff"
                border.width: pendingLock ? 3 : 1
                Text {
                    anchors { bottom: parent.top; left: parent.left; bottomMargin: 2 }
                    text: hasDet ? "ID " + bboxSlot.det.id : ""
                    color: parent.border.color
                    font.pixelSize: 12
                    style: Text.Outline
                    styleColor: "#000000"
                }
            }

            // Tap a person's bbox to lock the follow target on them.
            // Untracked detections (id ≤ 0) cannot be locked — id=0 means AUTO.
            //
            // TapHandler (not MouseArea) is required because HUDOverlayGrid has
            // a top-level TapHandler with CanTakeOverFromAnything (long-press →
            // OSD customizer). Matching CanTakeOverFromAnything on a deeper
            // handler resolves the contest in our favour for taps inside a
            // bbox; the parent still wins for long-press elsewhere on screen.
            //
            // gesturePolicy is DragThreshold (the most permissive) because
            // ReleaseWithinBounds silently drops the tap when the bbox shifts
            // out from under a held finger between press and release — easy
            // to trigger at 10 Hz when the subject is moving.
            TapHandler {
                id: bboxTap
                enabled: bboxSlot.hasDet
                gesturePolicy: TapHandler.DragThreshold
                grabPermissions: PointerHandler.CanTakeOverFromAnything

                // Capture the id at press time. The slot's `det` may switch
                // persons or vanish between press and tap (10 Hz model
                // replacement); we lock the person you saw under your finger,
                // not whoever happens to be in this slot at release time.
                property int pressedId: 0

                onPressedChanged: {
                    if (pressed && bboxSlot.hasDet) {
                        pressedId = bboxSlot.det.id
                    }
                }
                onTapped: {
                    if (pressedId > 0) {
                        // Optimistic yellow flash (v2.6.0-hailo) +
                        // USER attribution for the toast (HEAD).
                        root.pendingFollowId = pressedId
                        pendingTimer.restart()
                        root._requestedFollowId = pressedId
                        _ohdSystemAirSettingsModel.try_set_param_int_async(
                            "DF_FOLLOW_ID", pressedId)
                    }
                    pressedId = 0
                }
                onCanceled: pressedId = 0
            }

            // Tracked detection — green cross at the bbox center, no bbox.
            // Positioned relative to bboxSlot (which is itself anchored to
            // the bbox geometry), so child x/y are in slot-local coords.
            Item {
                visible: hasDet && det.tracked
                anchors.fill: parent
                z: 1
                property real armLen: Math.max(
                    12, Math.min(32, 0.025 * Math.min(root.renderedW, root.renderedH)))
                property real cx: bboxSlot.bw / 2
                property real cy: bboxSlot.bh / 2

                // Halo (black, behind the green cross — keeps it readable).
                Rectangle {
                    x: parent.cx - parent.armLen
                    y: parent.cy - 3
                    width: parent.armLen * 2
                    height: 6
                    color: "#000000"; opacity: 0.75; radius: 3
                }
                Rectangle {
                    x: parent.cx - 3
                    y: parent.cy - parent.armLen
                    width: 6
                    height: parent.armLen * 2
                    color: "#000000"; opacity: 0.75; radius: 3
                }
                // Green cross on top.
                Rectangle {
                    x: parent.cx - parent.armLen
                    y: parent.cy - 1.5
                    width: parent.armLen * 2
                    height: 3
                    color: "#80f060"; radius: 1.5
                }
                Rectangle {
                    x: parent.cx - 1.5
                    y: parent.cy - parent.armLen
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
