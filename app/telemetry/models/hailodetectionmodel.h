#ifndef HAILODETECTIONMODEL_H
#define HAILODETECTIONMODEL_H

#include <QObject>
#include <QVariantList>

#include "../tutil/mavlink_include.h"
#include "util/lqutils_include.h"

/**
 * Singleton model that receives bounding-box detection data from the air unit
 * via MAVLink TUNNEL messages (payload_type = 0x8001) and exposes it to QML.
 *
 * Binary payload format (max 128 bytes):
 *   Byte 0:    version = 1
 *   Byte 1:    active_id (uint8, 0 = none being tracked)
 *   Byte 2:    count     (uint8, number of bboxes)
 *   Per bbox — 10 bytes:
 *     [0]    id     uint8
 *     [1-2]  cx     uint16 LE  (0=0.0, 65535=1.0, normalized)
 *     [3-4]  cy     uint16 LE
 *     [5-6]  w      uint16 LE
 *     [7-8]  h      uint16 LE
 *     [9]    flags  uint8  (bit0 = is_tracked)
 *
 * QML properties:
 *   _hailoDetectionModel.active_id   — currently tracked ID (0 = none)
 *   _hailoDetectionModel.detections  — QVariantList of QVariantMap
 *       each map: { "id": int, "cx": real, "cy": real,
 *                   "w": real, "h": real, "tracked": bool }
 */
class HailoDetectionModel : public QObject {
    Q_OBJECT
public:
    explicit HailoDetectionModel(QObject* parent = nullptr);
    static HailoDetectionModel& instance();

    // Returns true if the message was consumed (TUNNEL with our payload_type)
    bool process_message(const mavlink_message_t& msg);

    L_RO_PROP(int, active_id, set_active_id, 0)
    L_RO_PROP(QVariantList, detections, set_detections, {})
};

#endif // HAILODETECTIONMODEL_H
