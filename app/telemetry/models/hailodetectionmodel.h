#ifndef HAILODETECTIONMODEL_H
#define HAILODETECTIONMODEL_H

#include <QObject>
#include <QVariantList>
#include <QTimer>
#include <atomic>
#include <memory>
#include <mutex>
#include <fstream>

#include "util/lqutils_include.h"

class UDPReceiver;

/**
 * Singleton model that receives bounding-box detection data from the air unit
 * via a dedicated wifibroadcast stream (forwarded to localhost:5520 on ground)
 * and exposes it to QML.
 *
 * Binary payload format v4 (v3 still parsed for backwards compat):
 *   Byte 0:      version (4)
 *   Byte 1-2:    active_id (uint16 LE, 0=none)
 *   Byte 3-4:    follow_id (int16 LE, -1=idle, 0=auto, N=locked)
 *   Byte 5:      mode      (uint8: 0=AUTO, 1=LOCKED, 2=SEARCH, 3=IDLE)  ◀ v4
 *   Byte 6:      count (uint8)
 *   Per bbox — 11 bytes (unchanged):
 *     [0-1]  id     uint16 LE
 *     [2-3]  cx     uint16 LE  (0=0.0, 65535=1.0, normalized)
 *     [4-5]  cy     uint16 LE
 *     [6-7]  w      uint16 LE
 *     [8-9]  h      uint16 LE
 *     [10]   flags  uint8  (bit0 = is_tracked)
 *
 * v3 senders are still accepted — mode defaults to AUTO (0) in that case.
 *
 * QML properties:
 *   _hailoDetectionModel.active_id   — currently tracked ID (0 = none)
 *   _hailoDetectionModel.follow_id   — operator's follow intent
 *   _hailoDetectionModel.mode        — Mode enum value (see below)
 *   _hailoDetectionModel.detections  — QVariantList of QVariantMap
 *       each map: { "id": int, "cx": real, "cy": real,
 *                   "w": real, "h": real, "tracked": bool }
 */
class HailoDetectionModel : public QObject {
    Q_OBJECT
public:
    // Mirrors the wire byte. Keep the integers in sync with the OpenHD
    // bridge and the drone-follow Python side — they encode/decode by the
    // same integer values.
    enum class Mode : int {
        Auto   = 0,
        Locked = 1,
        Search = 2,
        Idle   = 3,
    };
    Q_ENUM(Mode)

    explicit HailoDetectionModel(QObject* parent = nullptr);
    ~HailoDetectionModel();
    static HailoDetectionModel& instance();

    // Start listening for detection data on UDP port 5520
    void startReceiving();

    // --- Ground recording: save BB metadata to JSONL file ---
    void startRecordingMetadata(const std::string& jsonl_path);
    void stopRecordingMetadata();
    bool isRecordingMetadata() const;

    L_RO_PROP(int, active_id, set_active_id, 0)
    L_RO_PROP(int, follow_id, set_follow_id, 0)
    L_RO_PROP(int, mode, set_mode, 0)
    L_RO_PROP(QVariantList, detections, set_detections, {})
    L_RO_PROP(bool, receiving, set_receiving, false)

private:
    void on_udp_data(const uint8_t* data, size_t len);
    void update_receiving();
    std::unique_ptr<UDPReceiver> m_udp_receiver;
    std::atomic<int64_t> m_last_data_ms{-1};
    std::unique_ptr<QTimer> m_receiving_timer;
    // Metadata recording
    std::mutex m_meta_mutex;
    std::unique_ptr<std::ofstream> m_meta_file;
    std::chrono::steady_clock::time_point m_meta_start_time;
};

#endif // HAILODETECTIONMODEL_H
