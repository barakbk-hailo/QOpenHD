#ifndef HAILODETECTIONMODEL_H
#define HAILODETECTIONMODEL_H

#include <QObject>
#include <QVariantList>
#include <memory>

#include "util/lqutils_include.h"

class UDPReceiver;

/**
 * Singleton model that receives bounding-box detection data from the air unit
 * via a dedicated wifibroadcast stream (forwarded to localhost:5520 on ground)
 * and exposes it to QML.
 *
 * Binary payload format v2:
 *   Byte 0:      version = 2
 *   Byte 1-2:    active_id (uint16 LE, 0=none)
 *   Byte 3:      count (uint8)
 *   Per bbox — 11 bytes:
 *     [0-1]  id     uint16 LE
 *     [2-3]  cx     uint16 LE  (0=0.0, 65535=1.0, normalized)
 *     [4-5]  cy     uint16 LE
 *     [6-7]  w      uint16 LE
 *     [8-9]  h      uint16 LE
 *     [10]   flags  uint8  (bit0 = is_tracked)
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
    ~HailoDetectionModel();
    static HailoDetectionModel& instance();

    // Start listening for detection data on UDP port 5520
    void startReceiving();

    L_RO_PROP(int, active_id, set_active_id, 0)
    L_RO_PROP(QVariantList, detections, set_detections, {})

private:
    void on_udp_data(const uint8_t* data, size_t len);
    std::unique_ptr<UDPReceiver> m_udp_receiver;
};

#endif // HAILODETECTIONMODEL_H
