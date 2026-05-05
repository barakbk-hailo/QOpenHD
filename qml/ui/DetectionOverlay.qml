import QtQuick 2.12
import OpenHD 1.0

/**
 * Full-screen overlay that draws bounding-box rectangles from
 * _hailoDetectionModel.detections on top of the primary video stream.
 *
 * Detections are delivered as a QVariantList of maps:
 *   { "id": int, "cx": real, "cy": real, "w": real, "h": real, "tracked": bool }
 * Coordinates are normalized [0,1] relative to the video frame.
 *
 * The overlay accounts for aspect-ratio letterboxing so boxes stay aligned
 * with the actual rendered video area.
 */
Item {
    id: root
    anchors.fill: parent
    visible: _hailoDetectionModel.receiving

    // -------------------------------------------------------------------------
    // Parse native video resolution from _decodingStatistics.primary_stream_frame_format
    // Format: "<pixfmt> <width>x<height>"  e.g. "yuv420p 1920x1080"
    // -------------------------------------------------------------------------
    function parseVideoSize(fmt) {
        var m = fmt.match(/(\d+)x(\d+)/)
        if (m) return { w: parseInt(m[1]), h: parseInt(m[2]) }
        return { w: 0, h: 0 }
    }

    property var vsize: parseVideoSize(_decodingStatistics.primary_stream_frame_format)

    // Rendered video area (letterboxed to fit screen while preserving aspect ratio)
    property real renderedW: {
        if (vsize.w <= 0 || vsize.h <= 0) return width
        var scaleW = width  / vsize.w
        var scaleH = height / vsize.h
        var scale  = Math.min(scaleW, scaleH)
        return vsize.w * scale
    }
    property real renderedH: {
        if (vsize.w <= 0 || vsize.h <= 0) return height
        var scaleW = width  / vsize.w
        var scaleH = height / vsize.h
        var scale  = Math.min(scaleW, scaleH)
        return vsize.h * scale
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
    // Draw one rectangle per detection
    //
    // We render through a fixed-size delegate pool (Repeater over an integer
    // model). The previous QVariantList model destroyed and recreated every
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

            visible: hasDet
            x: bx
            y: by
            width:  bw
            height: bh

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.color: hasDet && det.tracked ? "#00ff00"
                            : pendingLock           ? "#ffff00"
                            :                         "#ffffff"
                border.width: hasDet && (det.tracked || pendingLock) ? 3 : 2
            }

            // Tap a tracked person's bbox to lock the follow target on them.
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
                        root.pendingFollowId = pressedId
                        pendingTimer.restart()
                        _ohdSystemAirSettingsModel.try_set_param_int_async(
                            "DF_FOLLOW_ID", pressedId)
                    }
                    pressedId = 0
                }
                onCanceled: pressedId = 0
            }
        }
    }
}
