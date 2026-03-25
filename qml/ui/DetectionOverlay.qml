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

    // -------------------------------------------------------------------------
    // Draw one rectangle per detection
    // -------------------------------------------------------------------------
    Repeater {
        model: _hailoDetectionModel.detections

        delegate: Item {
            property var det: modelData
            property real bx: root.offsetX + (det.cx - det.w / 2) * root.renderedW
            property real by: root.offsetY + (det.cy - det.h / 2) * root.renderedH
            property real bw: det.w * root.renderedW
            property real bh: det.h * root.renderedH

            x: bx
            y: by
            width:  bw
            height: bh

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                border.color: det.tracked ? "#00ff00" : "#ffffff"
                border.width: det.tracked ? 3 : 2
            }
        }
    }
}
