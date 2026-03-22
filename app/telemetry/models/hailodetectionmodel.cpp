#include "hailodetectionmodel.h"

#include <QDebug>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>

#include "../../videostreaming/vscommon/udp/UDPReceiver.h"
#include "tutil/qopenhdmavlinkhelper.hpp"

static uint16_t read_u16_le(const uint8_t* p) {
    return static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
}

HailoDetectionModel::HailoDetectionModel(QObject* parent)
    : QObject(parent)
{
    m_receiving_timer = std::make_unique<QTimer>(this);
    QObject::connect(m_receiving_timer.get(), &QTimer::timeout,
                     this, &HailoDetectionModel::update_receiving);
    m_receiving_timer->start(1000);
}

HailoDetectionModel::~HailoDetectionModel()
{
    if (m_udp_receiver) {
        m_udp_receiver->stopReceiving();
    }
}

HailoDetectionModel& HailoDetectionModel::instance()
{
    static HailoDetectionModel inst{};
    return inst;
}

void HailoDetectionModel::startReceiving()
{
    UDPReceiver::Configuration config;
    config.udp_ip_address = "127.0.0.1";
    config.udp_port = 5520;
    m_udp_receiver = std::make_unique<UDPReceiver>(
        "hailo_det", config,
        [this](const uint8_t data[], size_t len) {
            on_udp_data(data, len);
        });
    m_udp_receiver->startReceiving();
    qDebug() << "HailoDetectionModel: listening on UDP 5520";
}

void HailoDetectionModel::on_udp_data(const uint8_t* data, size_t len)
{
    // v3 header: version(1) + active_id(2) + follow_id(2) + count(1) = 6 bytes
    // Per bbox: id(2) + cx(2) + cy(2) + w(2) + h(2) + flags(1) = 11 bytes
    if (len < 6) return;

    const uint8_t version = data[0];
    if (version < 3) return;  // only v3+ supported

    m_last_data_ms = QOpenHDMavlinkHelper::getTimeMilliseconds();

    const uint16_t active = read_u16_le(data + 1);
    const int16_t  follow = static_cast<int16_t>(read_u16_le(data + 3));
    const uint8_t  count  = data[5];

    if (len < 6u + count * 11u) return;  // truncated

    QVariantList list;
    list.reserve(count);
    for (uint8_t i = 0; i < count; ++i) {
        const uint8_t* b = data + 6 + i * 11;
        QVariantMap det;
        det["id"]      = static_cast<int>(read_u16_le(b));
        det["cx"]      = read_u16_le(b + 2) / 65535.0;
        det["cy"]      = read_u16_le(b + 4) / 65535.0;
        det["w"]       = read_u16_le(b + 6) / 65535.0;
        det["h"]       = read_u16_le(b + 8) / 65535.0;
        det["tracked"] = (b[10] & 0x01) != 0;
        list.append(det);
    }

    set_active_id(static_cast<int>(active));
    set_follow_id(static_cast<int>(follow));
    set_detections(list);

    // Write metadata to JSONL file if recording
    {
        std::lock_guard<std::mutex> lock(m_meta_mutex);
        if(m_meta_file){
            const auto elapsed_us = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - m_meta_start_time).count();
            QJsonObject obj;
            obj["ts_us"] = static_cast<qint64>(elapsed_us);
            obj["active_id"] = static_cast<int>(active);
            obj["follow_id"] = static_cast<int>(follow);
            QJsonArray arr;
            for(const auto& v : list){
                QJsonObject d;
                auto m = v.toMap();
                d["id"] = m["id"].toInt();
                d["cx"] = m["cx"].toDouble();
                d["cy"] = m["cy"].toDouble();
                d["w"]  = m["w"].toDouble();
                d["h"]  = m["h"].toDouble();
                d["tracked"] = m["tracked"].toBool();
                arr.append(d);
            }
            obj["dets"] = arr;
            QJsonDocument doc(obj);
            auto line = doc.toJson(QJsonDocument::Compact);
            m_meta_file->write(line.constData(), line.size());
            m_meta_file->write("\n", 1);
        }
    }
}

void HailoDetectionModel::update_receiving()
{
    const int64_t last = m_last_data_ms.load();
    if (last <= -1) {
        set_receiving(false);
        return;
    }
    const auto elapsed_ms = QOpenHDMavlinkHelper::getTimeMilliseconds() - last;
    set_receiving(elapsed_ms < 2000);
}

// --- Ground recording: save BB metadata to JSONL file ---

void HailoDetectionModel::startRecordingMetadata(const std::string& jsonl_path)
{
    std::lock_guard<std::mutex> lock(m_meta_mutex);
    if(m_meta_file) return;
    m_meta_file = std::make_unique<std::ofstream>(jsonl_path);
    m_meta_start_time = std::chrono::steady_clock::now();
    qDebug() << "HailoDetectionModel: started recording metadata to" << jsonl_path.c_str();
}

void HailoDetectionModel::stopRecordingMetadata()
{
    std::lock_guard<std::mutex> lock(m_meta_mutex);
    if(!m_meta_file) return;
    m_meta_file->flush();
    m_meta_file.reset();
    qDebug() << "HailoDetectionModel: stopped recording metadata";
}

bool HailoDetectionModel::isRecordingMetadata() const
{
    return m_meta_file != nullptr;
}
