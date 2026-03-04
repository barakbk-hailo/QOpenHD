#ifndef HAILODETECTIONMODEL_H
#define HAILODETECTIONMODEL_H

#include <QObject>
#include <QVariantList>
#include <QTimer>
#include <atomic>
#include <memory>

#include "util/lqutils_include.h"

class UDPReceiver;

/**
 * Singleton model that receives bounding-box detection data from the air unit
 * via a dedicated wifibroadcast stream (forwarded to localhost:5520 on ground)
 * and exposes it to QML.
 *
 * Binary payload format v3:
 *   Byte 0:      version = 3
 *   Byte 1-2:    active_id (uint16 LE, 0=none)
 *   Byte 3-4:    follow_id (int16 LE, -1=idle, 0=auto, N=locked)
 *   Byte 5:      count (uint8)
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
    L_RO_PROP(int, follow_id, set_follow_id, 0)
    L_RO_PROP(QVariantList, detections, set_detections, {})
    L_RO_PROP(bool, receiving, set_receiving, false)

private:
    void on_udp_data(const uint8_t* data, size_t len);
    void update_receiving();
    std::unique_ptr<UDPReceiver> m_udp_receiver;
    std::atomic<int64_t> m_last_data_ms{-1};
    std::unique_ptr<QTimer> m_receiving_timer;
};

#endif // HAILODETECTIONMODEL_H
